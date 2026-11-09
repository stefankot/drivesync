import Foundation

// MARK: - Rejestr odciążonych katalogów (żeby GUI mogło je pokazać i przywrócić)

struct OffloadedItem: Codable, Identifiable {
    var id: String { path }
    let path: String
    let bytes: Int64
    let date: Date
}

enum Registry {
    static func list() -> [OffloadedItem] {
        (JSON.read([OffloadedItem].self, from: Paths.offloadedFile) ?? []).sorted { $0.date > $1.date }
    }
    static func add(_ i: OffloadedItem) {
        var l = list().filter { $0.path != i.path }
        l.append(i)
        JSON.write(l, to: Paths.offloadedFile)
    }
    static func remove(_ path: String) {
        JSON.write(list().filter { $0.path != path }, to: Paths.offloadedFile)
    }
}

struct OffloadError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct Snapshot {
    var files: [String: [Int64]] = [:]  // rel → [rozmiar, mtime]
    var bytes: Int64 = 0
    var dirs = 0
    var odd: [String] = []  // dowiązania, sockety itd.: nie da się ich bezpiecznie skasować
}

struct OffloadPlan {
    let abs: String
    let rel: String
    let folder: FolderMap
    let sub: String       // ścieżka wewnątrz Dysku
    let remote: String    // "gdrive:Mac/Dokumenty/…"
    let snapshot: Snapshot
}

func formatBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false  // „0 KB” zamiast „Zero KB”
    return f.string(fromByteCount: b)
}

/// `offload`: przenosi katalog z Maca wyłącznie na Dysk (zwalnia miejsce), a w jego miejscu zostawia
/// dowiązanie do zamontowanego Dysku, więc ścieżka nadal działa. `restore`: odwrotność.
///
/// Nic nie jest kasowane, dopóki: (1) rclone nie potwierdzi sum MD5 każdego pliku na Dysku,
/// (2) pliki lokalne nie zmieniły się od momentu skanu.
enum Offload {
    // MARK: ścieżki i skan

    static func target(_ raw: String, cfg: Config) throws -> (folder: FolderMap, rel: String, abs: String) {
        // realpath katalogu nadrzędnego + nazwa (bez podążania za końcowym dowiązaniem)
        var p = Paths.expand(raw)
        if !p.hasPrefix("/") { p = FileManager.default.currentDirectoryPath + "/" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        let ns = p as NSString
        let abs = Paths.real(ns.deletingLastPathComponent) + "/" + ns.lastPathComponent
        for f in cfg.folders {
            let root = Paths.real(Paths.expand(f.local))
            if abs.hasPrefix(root + "/") { return (f, String(abs.dropFirst(root.count + 1)), abs) }
        }
        throw OffloadError("Ten katalog nie leży w żadnym synchronizowanym folderze (\(cfg.folders.map { $0.local }.joined(separator: ", "))).")
    }

    static func scan(_ root: String) -> Snapshot {
        var s = Snapshot()
        guard let en = FileManager.default.enumerator(atPath: root) else { return s }
        while let sub = en.nextObject() as? String {
            var st = stat()
            guard lstat(root + "/" + sub, &st) == 0 else { continue }
            switch UInt32(st.st_mode) & 0o170000 {
            case 0o100000:
                s.files[sub] = [Int64(st.st_size), Int64(st.st_mtimespec.tv_sec)]
                s.bytes += Int64(st.st_size)
            case 0o040000: s.dirs += 1
            default: s.odd.append(sub)
            }
        }
        return s
    }

    static func plan(_ raw: String, cfg: Config) throws -> OffloadPlan {
        let t = try target(raw, cfg: cfg)
        var st = stat()
        guard lstat(t.abs, &st) == 0 else { throw OffloadError("\(t.abs) nie istnieje.") }
        let type = UInt32(st.st_mode) & 0o170000
        if type == 0o120000 { throw OffloadError("To już jest odciążony katalog (dowiązanie do Dysku).") }
        guard type == 0o040000 else { throw OffloadError("Można odciążać katalogi, nie pojedyncze pliki.") }
        let snap = scan(t.abs)
        if !snap.odd.isEmpty {
            throw OffloadError("Katalog zawiera dowiązania symboliczne lub pliki specjalne (np. \(snap.odd.prefix(3).joined(separator: ", "))). Skasowanie ich byłoby nieodwracalne. Usuń je lub spakuj katalog.")
        }
        let sub = cfg.remoteSub(for: t.folder) + "/" + t.rel
        return OffloadPlan(abs: t.abs, rel: t.rel, folder: t.folder, sub: sub, remote: "\(cfg.remote):" + sub, snapshot: snap)
    }

    // MARK: wykonanie

    typealias Step = (String) -> Void

    static func execute(_ plan: OffloadPlan, cfg: Config, rclone bin: String, link: Bool, ctl: JobControl,
                        interactive: Bool, step: Step, line: ((String) -> Void)?) throws
    {
        var common = ["--transfers", String(cfg.transfers), "--checkers", String(cfg.checkers),
                      "--drive-chunk-size", "64M", "--drive-stop-on-upload-limit"]
        if interactive {
            common += ["--log-file", Paths.rcloneLog, "--log-level", "INFO", "--progress"]
        } else {
            common += ["--stats", "2s", "--stats-one-line"]
        }
        if let bw = cfg.bwlimit, !bw.isEmpty { common += ["--bwlimit", bw] }
        let cancelMsg = "Anulowano. Lokalnie nic nie zostało skasowane."

        // 1) wyślij WSZYSTKO (bez wykluczeń: to, co skasujemy, musi być na Dysku)
        step("1/4 Wysyłanie na Dysk…")
        var r = Rclone.runJob(bin, ["copy", plan.abs, plan.remote, "--update", "--create-empty-src-dirs"] + common,
                              ctl: ctl, interactive: interactive, onLine: line)
        if ctl.cancelled { throw OffloadError(cancelMsg) }
        if r.code != 0 { throw OffloadError("Wysyłanie nie powiodło się (kod \(r.code)). \(r.tail) Lokalnie nic nie zostało skasowane.") }

        // 2) weryfikacja sum kontrolnych (Dysk podaje MD5)
        step("2/4 Weryfikacja sum kontrolnych…")
        r = Rclone.runJob(bin, ["check", plan.abs, plan.remote, "--one-way", "--checkers", String(cfg.checkers)],
                          ctl: ctl, interactive: interactive, onLine: line)
        if ctl.cancelled { throw OffloadError(cancelMsg) }
        if r.code != 0 {
            throw OffloadError("Weryfikacja wykryła różnice (kod \(r.code)): kopia na Dysku jest nowsza, inna lub uszkodzona. Lokalnie nic nie zostało skasowane.")
        }

        // 3) czy ktoś nie zmienił plików w trakcie?
        step("3/4 Kontrola zmian w trakcie…")
        let after = scan(plan.abs)
        let before = plan.snapshot
        let changed = after.files.count != before.files.count || !after.odd.isEmpty
            || after.files.contains { k, v in before.files[k].map { $0 != v } ?? true }
        if changed { throw OffloadError("Pliki zmieniły się w trakcie wysyłania. Nic nie skasowano; spróbuj ponownie.") }
        if ctl.cancelled { throw OffloadError(cancelMsg) }

        // 4) skasuj lokalnie i zostaw dowiązanie do zamontowanego Dysku (od tej chwili bez anulowania)
        step("4/4 Zwalnianie miejsca…")
        do { try FileManager.default.removeItem(atPath: plan.abs) } catch {
            throw OffloadError("Nie udało się skasować lokalnej kopii: \(error.localizedDescription)")
        }
        if link {
            let dest = Paths.expand(cfg.mount.path) + "/" + plan.sub
            try? FileManager.default.createSymbolicLink(atPath: plan.abs, withDestinationPath: dest)
        }
        Registry.add(OffloadedItem(path: plan.abs, bytes: before.bytes, date: Date()))
    }

    static func restore(_ raw: String, cfg: Config, rclone bin: String, ctl: JobControl, interactive: Bool,
                        step: Step, line: ((String) -> Void)?) throws
    {
        let t = try target(raw, cfg: cfg)
        var st = stat()
        guard lstat(t.abs, &st) == 0, UInt32(st.st_mode) & 0o170000 == 0o120000 else {
            throw OffloadError("To nie jest odciążony katalog (dowiązanie do Dysku).")
        }
        let remote = "\(cfg.remote):" + cfg.remoteSub(for: t.folder) + "/" + t.rel

        step("Sprawdzam rozmiar…")
        let sz = Proc.run(bin, ["size", remote, "--json"], timeout: 120)
        if sz.code == 0, let d = sz.out.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let bytes = (o["bytes"] as? NSNumber)?.int64Value
        {
            let free = (try? URL(fileURLWithPath: Paths.home).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? 0
            if free < bytes + 2_000_000_000 {
                throw OffloadError("Za mało miejsca na dysku: potrzeba \(formatBytes(bytes)) + 2 GB zapasu, wolne \(formatBytes(free)).")
            }
        }

        step("Pobieranie z Dysku…")
        let tmp = t.abs + ".fetching"
        try? FileManager.default.removeItem(atPath: tmp)
        var args = ["copy", remote, tmp, "--create-empty-src-dirs", "--transfers", String(cfg.transfers)]
        args += interactive ? ["--progress", "--log-file", Paths.rcloneLog, "--log-level", "INFO"] : ["--stats", "2s", "--stats-one-line"]
        let r = Rclone.runJob(bin, args, ctl: ctl, interactive: interactive, onLine: line)
        if ctl.cancelled {
            try? FileManager.default.removeItem(atPath: tmp)
            throw OffloadError("Anulowano. Dowiązanie do Dysku zostało bez zmian.")
        }
        if r.code != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
            throw OffloadError("Pobieranie nie powiodło się (kod \(r.code)). \(r.tail) Dowiązanie do Dysku zostało bez zmian.")
        }
        do {
            try FileManager.default.removeItem(atPath: t.abs)  // tylko dowiązanie
            try FileManager.default.moveItem(atPath: tmp, toPath: t.abs)
        } catch { throw OffloadError("Nie udało się podmienić dowiązania: \(error.localizedDescription)") }
        Registry.remove(t.abs)
    }

    // MARK: CLI

    private static func die(_ msg: String) -> Never {
        FileHandle.standardError.write(Data(("✗ " + msg + "\n").utf8))
        exit(1)
    }

    static func cliOffload(_ args: [String]) -> Never {
        let yes = args.contains("--yes")
        let link = !args.contains("--no-link")
        let quiet = args.contains("--quiet")  // ta sama ścieżka co w GUI (postęp z potoku, bez terminala)
        let paths = args.filter { !$0.hasPrefix("--") }
        if paths.isEmpty { die("użycie: drivesync offload [--yes] [--no-link] <katalog>...") }
        let cfg: Config
        do { cfg = try Config.load() } catch { die("config: \(error)") }
        guard let bin = Rclone.binary(cfg) else { die("brak rclone") }
        for raw in paths {
            do {
                let p = try plan(raw, cfg: cfg)
                print("\n▸ \(p.abs)\n  \(p.snapshot.files.count) plików, \(formatBytes(p.snapshot.bytes))\n  Dysk: \(p.remote)")
                if !yes { print("  (próba na sucho: nic nie zrobiono; dodaj --yes)"); continue }
                try execute(p, cfg: cfg, rclone: bin, link: link, ctl: JobControl(), interactive: !quiet,
                            step: { print("  " + $0) }, line: quiet ? { if $0.contains("%") || $0.contains("ERROR") { print("      · " + $0) } } : nil)
                print("  ✓ zwolniono \(formatBytes(p.snapshot.bytes))")
            } catch { die(error.localizedDescription) }
        }
        exit(0)
    }

    static func cliFetch(_ args: [String]) -> Never {
        guard let raw = args.first(where: { !$0.hasPrefix("--") }) else { die("użycie: drivesync fetch <katalog>") }
        let cfg: Config
        do { cfg = try Config.load() } catch { die("config: \(error)") }
        guard let bin = Rclone.binary(cfg) else { die("brak rclone") }
        do {
            let quiet = args.contains("--quiet")
            try restore(raw, cfg: cfg, rclone: bin, ctl: JobControl(), interactive: !quiet, step: { print("  " + $0) },
                        line: quiet ? { if $0.contains("%") || $0.contains("ERROR") { print("      · " + $0) } } : nil)
            print("✓ \(raw) jest znów lokalnie")
            exit(0)
        } catch { die(error.localizedDescription) }
    }
}
