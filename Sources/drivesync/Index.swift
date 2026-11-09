import Foundation
import SQLite3

// MARK: - lstat / przechodzenie po drzewie

struct FInfo {
    var ino: UInt64
    var size: Int64
    var mtime: Int64
    var isDir: Bool
}

/// Zwykły plik lub katalog (bez podążania za dowiązaniami). Reszta → nil.
func finfo(_ path: String) -> FInfo? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    let type = UInt32(st.st_mode) & 0o170000
    guard type == 0o100000 || type == 0o040000 else { return nil }
    return FInfo(ino: UInt64(st.st_ino), size: Int64(st.st_size),
                 mtime: Int64(st.st_mtimespec.tv_sec), isDir: type == 0o040000)
}

/// Przechodzi po drzewie (rodzic przed dziećmi), pomijając wykluczenia. Dla `rel` niepustego
/// zgłasza też sam katalog `rel`.
func walkTree(root: String, rel: String, excludes: [String], _ body: (String, FInfo) -> Void) {
    let base = rel.isEmpty ? root : root + "/" + rel
    if !rel.isEmpty, let i = finfo(base) { body(rel, i) }
    guard let en = FileManager.default.enumerator(atPath: base) else { return }
    while let sub = en.nextObject() as? String {
        let r = rel.isEmpty ? sub : rel + "/" + sub
        if Ignore.matches(r, patterns: excludes) { en.skipDescendants(); continue }
        if let i = finfo(root + "/" + r) { body(r, i) }
    }
}

// MARK: - Indeks: co wysłaliśmy i pod jakim i-węzłem

/// Pozwala rozpoznać, że plik/katalog został PRZENIESIONY lokalnie (ten sam inode, inna ścieżka),
/// więc na Dysku wystarczy przenieść go po stronie serwera zamiast wysyłać ponownie.
final class Index {
    struct Row {
        let path: String
        let size: Int64
        let mtime: Int64
        let isDir: Bool
    }

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private enum Bind { case text(String), int(Int64) }

    init?(path: String) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard sqlite3_open(path, &db) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 5000)
        exec("PRAGMA journal_mode=WAL", [])
        exec("PRAGMA synchronous=NORMAL", [])
        exec("""
            CREATE TABLE IF NOT EXISTS entries(
              folder TEXT NOT NULL, ino INTEGER NOT NULL, path TEXT NOT NULL,
              size INTEGER NOT NULL, mtime INTEGER NOT NULL, isdir INTEGER NOT NULL,
              PRIMARY KEY(folder, ino))
            """, [])
        exec("CREATE INDEX IF NOT EXISTS entries_path ON entries(folder, path)", [])
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    private func step(_ sql: String, _ binds: [Bind]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.error("sqlite: \(String(cString: sqlite3_errmsg(db))) w: \(sql.prefix(60))")
            return nil
        }
        for (i, b) in binds.enumerated() {
            switch b {
            case .text(let s): sqlite3_bind_text(stmt, Int32(i + 1), s, -1, Index.transient)
            case .int(let n): sqlite3_bind_int64(stmt, Int32(i + 1), n)
            }
        }
        return stmt
    }

    private func exec(_ sql: String, _ binds: [Bind]) {
        guard let s = step(sql, binds) else { return }
        sqlite3_step(s)
        sqlite3_finalize(s)
    }

    func transaction(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        exec("BEGIN", [])
        body()
        exec("COMMIT", [])
    }

    func count(folder: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let s = step("SELECT COUNT(*) FROM entries WHERE folder=?1", [.text(folder)]) else { return 0 }
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int64(s, 0)) : 0
    }

    func lookup(folder: String, ino: UInt64) -> Row? {
        lock.lock(); defer { lock.unlock() }
        guard let s = step("SELECT path,size,mtime,isdir FROM entries WHERE folder=?1 AND ino=?2",
                           [.text(folder), .int(Int64(bitPattern: ino))]) else { return nil }
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW, let c = sqlite3_column_text(s, 0) else { return nil }
        return Row(path: String(cString: c), size: sqlite3_column_int64(s, 1),
                   mtime: sqlite3_column_int64(s, 2), isDir: sqlite3_column_int(s, 3) != 0)
    }

    func upsert(folder: String, path: String, _ f: FInfo) {
        lock.lock(); defer { lock.unlock() }
        let ino = Int64(bitPattern: f.ino)
        exec("DELETE FROM entries WHERE folder=?1 AND path=?2 AND ino<>?3", [.text(folder), .text(path), .int(ino)])
        exec("INSERT OR REPLACE INTO entries(folder,ino,path,size,mtime,isdir) VALUES(?1,?2,?3,?4,?5,?6)",
             [.text(folder), .int(ino), .text(path), .int(f.size), .int(f.mtime), .int(f.isDir ? 1 : 0)])
    }

    /// Po przeniesieniu katalogu: podmienia prefiks ścieżek wszystkich wpisów w środku.
    func rename(folder: String, from: String, to: String) {
        lock.lock(); defer { lock.unlock() }
        let esc = from.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        exec("""
            UPDATE entries SET path = ?3 || substr(path, length(?2)+1)
            WHERE folder=?1 AND (path=?2 OR path LIKE ?4 ESCAPE '\\')
            """, [.text(folder), .text(from), .text(to), .text(esc + "/%")])
    }
}

// MARK: - Wykrywanie i wykonywanie przenosin na Dysku

final class MoveTracker {
    private let index: Index
    private let cfg: Config
    private let rclone: String
    private let folders: [FolderMap]
    private let roots: [String]

    init(index: Index, cfg: Config, rclone: String, folders: [FolderMap], roots: [String]) {
        self.index = index
        self.cfg = cfg
        self.rclone = rclone
        self.folders = folders
        self.roots = roots
    }

    func hasHistory(folder i: Int) -> Bool { index.count(folder: folders[i].local) > 0 }

    /// `rels` w kolejności „rodzic przed dziećmi”. Dla każdej ścieżki, która jest znanym wcześniej
    /// i-węzłem pod inną ścieżką (a stara ścieżka zniknęła), przenosi odpowiednik na Dysku.
    func apply(folder i: Int, rels: [String], track: (Process) -> Void) {
        let key = folders[i].local
        let spec = cfg.remoteSpec(for: folders[i])
        for rel in rels where !rel.isEmpty {
            guard let cur = finfo(roots[i] + "/" + rel),
                  let row = index.lookup(folder: key, ino: cur.ino),
                  row.path != rel, row.isDir == cur.isDir else { continue }
            // zmiana nazwy zachowuje rozmiar i mtime pliku; chroni przed ponownym użyciem numeru inode
            if !cur.isDir && (row.size != cur.size || row.mtime != cur.mtime) { continue }
            // stary adres wciąż zajęty tym samym i-węzłem (twarde dowiązanie) → to nie przenosiny
            if let old = finfo(roots[i] + "/" + row.path), old.ino == cur.ino { continue }

            let r = Rclone.run(rclone, [
                "moveto", spec + "/" + row.path, spec + "/" + rel,
                "--immutable", "--log-file", Paths.rcloneLog, "--log-level", "INFO",
            ], started: track)
            if r.code == 0 {
                index.rename(folder: key, from: row.path, to: rel)
                Log.info("przeniesiono na Dysku: \(row.path) → \(rel)")
            } else {
                Log.info("przenosiny na Dysku niemożliwe (\(row.path) → \(rel), kod \(r.code)): kopiuję normalnie")
            }
        }
    }

    /// Ile bajtów prawdopodobnie trzeba wysłać: pliki, których nie ma w indeksie albo które się zmieniły.
    /// (Pliki już wysłane wcześniej mają w indeksie ten sam rozmiar i mtime.)
    func pendingBytes(folder i: Int, rel: String) -> Int64 {
        let key = folders[i].local
        var total: Int64 = 0
        walkTree(root: roots[i], rel: rel, excludes: cfg.excludes) { r, f in
            if f.isDir { return }
            if let row = index.lookup(folder: key, ino: f.ino), row.path == r, row.size == f.size, row.mtime == f.mtime { return }
            total += f.size
        }
        return total
    }

    func pendingBytes(folder i: Int, files: [String]) -> Int64 {
        files.reduce(Int64(0)) { acc, r in acc + (finfo(roots[i] + "/" + r)?.size ?? 0) }
    }

    func record(folder i: Int, files: [String]) {
        let key = folders[i].local
        index.transaction {
            for rel in files {
                if let f = finfo(roots[i] + "/" + rel) { index.upsert(folder: key, path: rel, f) }
            }
        }
    }

    func recordTree(folder i: Int, rel: String) {
        let key = folders[i].local
        index.transaction {
            walkTree(root: roots[i], rel: rel, excludes: cfg.excludes) { r, f in
                index.upsert(folder: key, path: r, f)
            }
        }
    }
}
