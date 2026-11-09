import Foundation

enum Rclone {
    static func binary(_ cfg: Config) -> String? {
        let candidates = [
            cfg.rclonePath.map(Paths.expand),
            "/opt/homebrew/bin/rclone",
            "/usr/local/bin/rclone",
            Paths.home + "/.local/bin/rclone",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Flagi wspólne dla każdego kopiowania.
    ///
    /// Zasady bezpieczeństwa (celowo nie do wyłączenia z configu):
    /// - używamy wyłącznie `rclone copy`, nigdy `sync`/`move` → nic na Dysku nie jest kasowane,
    ///   więc pliki, których nie masz lokalnie (np. duże archiwa), są nietykalne;
    /// - `--max-delete 0` jako druga linia obrony.
    /// `withExcludes: false` dla `--files-from-raw` (rclone nie pozwala łączyć go z filtrami;
    /// wtedy wykluczenia stosuje już Swift przy zbieraniu zdarzeń, patrz `Ignore`).
    static func copyFlags(_ cfg: Config, withExcludes: Bool = true) -> [String] {
        var a = [
            "--skip-links",
            "--transfers", String(cfg.transfers),
            "--checkers", String(cfg.checkers),
            "--retries", "3",
            "--low-level-retries", "10",
            "--max-delete", "0",
            "--drive-chunk-size", "64M",
            "--drive-stop-on-upload-limit",
            // statystyki co 2 s jako JSON na stderr: stąd czytamy postęp (log zapisuje RcloneLog)
            "--use-json-log", "--log-level", "INFO",
            "--stats", "2s", "--stats-log-level", "NOTICE",
        ]
        if cfg.skipIfNewerOnDrive { a.append("--update") }
        if let bw = cfg.bwlimit, !bw.isEmpty { a += ["--bwlimit", bw] }
        if withExcludes { for e in cfg.excludes { a += ["--exclude", e] } }
        return a
    }

    /// Uruchamia rclone i czeka na koniec. `started` dostaje proces (żeby dało się go przerwać).
    static func run(_ bin: String, _ args: [String], started: (Process) -> Void)
        -> (code: Int32, stderr: String)
    {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.environment = Proc.env
        p.qualityOfService = .utility
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe

        let lock = NSLock()
        var buf = Data()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            lock.lock()
            buf.append(d)
            if buf.count > 16_384 { buf = Data(buf.suffix(8192)) }
            lock.unlock()
        }

        do { try p.run() } catch { return (-1, "\(error)") }
        started(p)
        p.waitUntilExit()
        errPipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        return (p.terminationStatus, String(decoding: buf, as: UTF8.self))
    }
}

/// Prefiltr po stronie Swifta: nie budzimy rclone z powodu `.DS_Store` itp.
/// Autorytatywny filtr i tak robi rclone (te same wzorce idą w `--exclude`).
enum Ignore {
    static func matches(_ rel: String, patterns: [String]) -> Bool {
        let comps = rel.split(separator: "/").map(String.init)
        guard !comps.isEmpty else { return false }
        for var pat in patterns {
            if pat.hasPrefix("**/") { pat.removeFirst(3) }
            if pat.hasSuffix("/**") { pat.removeLast(3) }
            if pat.contains("/") { continue }  // złożone wzorce zostawiamy rclone'owi
            for c in comps where fnmatch(pat, c, 0) == 0 { return true }
        }
        return false
    }
}

// MARK: - Zadania użytkownika (offload / fetch / logowanie): z postępem i anulowaniem

final class JobControl {
    private let lock = NSLock()
    private var _cancelled = false
    private var proc: Process?

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    func cancel() {
        lock.lock(); _cancelled = true; let p = proc; lock.unlock()
        p?.terminate()
    }

    fileprivate func attach(_ p: Process?) {
        lock.lock(); proc = p; let c = _cancelled; lock.unlock()
        if c { p?.terminate() }
    }
}

extension Rclone {
    /// `interactive`: rclone dziedziczy terminal (CLI, pasek postępu). Inaczej stderr jest czytany
    /// linia po linii i przekazywany do `onLine` (GUI).
    static func runJob(_ bin: String, _ args: [String], ctl: JobControl, interactive: Bool,
                       onLine: ((String) -> Void)? = nil) -> (code: Int32, tail: String)
    {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.environment = Proc.env
        p.qualityOfService = .userInitiated

        var tail: [String] = []
        let lock = NSLock()
        let pipe = Pipe()
        if !interactive {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = pipe
            var partial = ""
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; return }
                lock.lock()
                partial += String(decoding: d, as: UTF8.self)
                let parts = partial.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
                partial = String(parts.last ?? "")
                let lines = parts.dropLast().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                tail.append(contentsOf: lines)
                if tail.count > 6 { tail.removeFirst(tail.count - 6) }
                lock.unlock()
                for l in lines { onLine?(l) }
            }
        }

        do { try p.run() } catch { return (-1, "\(error)") }
        ctl.attach(p)
        p.waitUntilExit()
        ctl.attach(nil)
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        return (p.terminationStatus, tail.suffix(3).joined(separator: " | "))
    }
}
