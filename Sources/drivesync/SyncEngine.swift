import Foundation
import CoreServices

/// Jednokierunkowa synchronizacja Mac → Dysk Google.
///
/// - zmiany plików przychodzą z FSEvents, są łączone (debounce) i wysyłane jednym
///   `rclone copy --files-from-raw --no-traverse` (bez listowania całego Dysku);
/// - po restarcie odtwarzamy zdarzenia od ostatniego checkpointu zamiast skanować foldery;
/// - co `fullScanHours` robimy pełny przegląd jako siatkę bezpieczeństwa;
/// - kasowanie lokalne NIE jest propagowane na Dysk.
final class SyncEngine {
    private enum JobKind { case files([String]), dir(String) }
    private struct Job {
        let folder: Int
        let kind: JobKind
        var isFull: Bool { if case .dir(let d) = kind { return d.isEmpty } else { return false } }
        var label: String {
            switch kind {
            case .files(let l): return "\(l.count) plik(ów)"
            case .dir(let d): return d.isEmpty ? "pełny przegląd" : "katalog \(d)"
            }
        }
    }

    private let cfg: Config
    private let rclone: String
    private let folders: [FolderMap]
    private let roots: [String]          // rozwiązane ścieżki lokalne (FSEvents podaje realne ścieżki)
    private let q = DispatchQueue(label: "drivesync.engine")
    private let worker = DispatchQueue(label: "drivesync.worker", qos: .utility)

    private var pendingFiles: [Set<String>]
    private var pendingDirs: [Set<String>]
    private var firstAt: Date?
    private var lastAt: Date?
    private var forceNow = false
    private var notBefore = Date.distantPast
    private var running = false
    private var stopping = false
    private var failures = 0
    private var lastError: String?
    private var lastSuccess: Date?
    private var current: String?
    private var latestSeenId: UInt64 = 0
    private var state: PersistedState
    private var watcher: FSWatcher?
    private var ticker: DispatchSourceTimer?
    private let startedAt = Date()

    private let procLock = NSLock()
    private var currentProcess: Process?
    private var currentCtl: JobControl?
    private var progress: SyncProgress?

    /// Stan jednego przebiegu (kilka zadań): szacunki rozmiarów i to, co już zrobione.
    private final class RunProgress {
        var estimates: [Int64]
        var index = 0
        var doneBytes: Int64 = 0   // zakończone wcześniej zadania
        var curDone: Int64 = 0     // bieżące zadanie
        var speed: Double = 0      // ostatnia znana prędkość (do ETA między zadaniami)
        init(estimates: [Int64]) { self.estimates = estimates }
    }
    private let tracker: MoveTracker?
    private let debugEvents = ProcessInfo.processInfo.environment["DRIVESYNC_DEBUG"] != nil

    /// Podpinane przez main: stan montowania do pliku statusu.
    var mountSnapshot: () -> (state: String, path: String?) = { ("disabled", nil) }

    init?(cfg: Config, rclone: String) {
        self.cfg = cfg
        self.rclone = rclone
        var fs: [FolderMap] = []
        var rs: [String] = []
        for f in cfg.folders {
            let p = Paths.expand(f.local)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else {
                Log.error("pomijam \(f.local): katalog nie istnieje")
                continue
            }
            fs.append(f)
            rs.append(Paths.real(p))
        }
        if fs.isEmpty { return nil }
        folders = fs
        roots = rs
        pendingFiles = Array(repeating: [], count: fs.count)
        pendingDirs = Array(repeating: [], count: fs.count)
        state = JSON.read(PersistedState.self, from: Paths.stateFile) ?? PersistedState()
        if let idx = Index(path: Paths.indexFile) {
            tracker = MoveTracker(index: idx, cfg: cfg, rclone: rclone, folders: fs, roots: rs)
        } else {
            Log.error("nie mogę otworzyć indeksu: przenosiny plików będą wysyłane jako nowe kopie")
            tracker = nil
        }
    }

    deinit {
        ticker?.cancel()
        watcher?.stop()
    }

    // MARK: lifecycle

    func start() {
        q.async {
            try? FileManager.default.createDirectory(atPath: Paths.cacheDir, withIntermediateDirectories: true)
            // sprzątanie list plików po poprzednim, przerwanym uruchomieniu
            if let old = try? FileManager.default.contentsOfDirectory(atPath: Paths.cacheDir) {
                for f in old where f.hasPrefix("files-") { try? FileManager.default.removeItem(atPath: Paths.cacheDir + "/" + f) }
            }

            let now = FSWatcher.currentEventId
            var since: UInt64? = nil
            if let cp = self.state.checkpointId, cp <= now {
                since = cp
                Log.info("odtwarzam zdarzenia FSEvents od checkpointu \(cp) (teraz: \(now))")
            } else {
                Log.info("brak ważnego checkpointu: pełny przegląd przy starcie")
                for i in self.folders.indices { self.state.lastFullPass[self.folders[i].local] = nil }
            }
            self.latestSeenId = since ?? now

            let w = FSWatcher(queue: self.q) { [weak self] path, flags, id in self?.ingest(path, flags, id) }
            if !w.start(paths: self.roots, since: since) {
                Log.error("nie udało się uruchomić FSEvents")
            }
            self.watcher = w

            let t = DispatchSource.makeTimerSource(queue: self.q)
            t.schedule(deadline: .now() + 5, repeating: 10)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.ticker = t
            Log.info("start: \(self.folders.count) folderów, debounce \(self.cfg.debounceSeconds)s")
        }
    }

    func stop() {
        q.sync {
            stopping = true
            ticker?.cancel()
            watcher?.stop()
            procLock.lock(); currentProcess?.terminate(); currentCtl?.cancel(); procLock.unlock()
            JSON.write(state, to: Paths.stateFile)
            writeStatusLocked()
        }
    }

    /// SIGUSR1: pełny przegląd wszystkich folderów teraz.
    func syncNow() {
        q.async {
            Log.info("ręczne żądanie synchronizacji")
            for i in self.folders.indices { self.pendingDirs[i].insert("") }
            self.touch()
            self.forceNow = true
            self.notBefore = .distantPast
            self.tick()
        }
    }

    // MARK: zdarzenia

    private func folderIndex(for path: String) -> Int? {
        for (i, r) in roots.enumerated() where path == r || path.hasPrefix(r + "/") { return i }
        return nil
    }

    private func touch() {
        let n = Date()
        if firstAt == nil { firstAt = n }
        lastAt = n
    }

    private func ingest(_ path: String, _ flags: UInt32, _ id: UInt64) {
        latestSeenId = max(latestSeenId, id)
        if debugEvents { Log.info("fsevent id=\(id) flags=0x\(String(flags, radix: 16)) path=\(path)") }
        guard !path.isEmpty, let idx = folderIndex(for: path) else { return }
        let rel = path == roots[idx] ? "" : String(path.dropFirst(roots[idx].count + 1))
        if !rel.isEmpty && Ignore.matches(rel, patterns: cfg.excludes) { return }

        func has(_ f: Int) -> Bool { flags & UInt32(f) != 0 }
        let mustScan = has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagUserDropped)
            || has(kFSEventStreamEventFlagKernelDropped) || has(kFSEventStreamEventFlagEventIdsWrapped)
            || has(kFSEventStreamEventFlagRootChanged)
        if mustScan {
            pendingDirs[idx].insert(rel)
            touch()
            return
        }

        let isFile = has(kFSEventStreamEventFlagItemIsFile) || has(kFSEventStreamEventFlagItemIsSymlink)
        let isDir = has(kFSEventStreamEventFlagItemIsDir)
        let changed = has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemModified)
            || has(kFSEventStreamEventFlagItemRenamed) || has(kFSEventStreamEventFlagItemInodeMetaMod)

        if isFile && changed {
            pendingFiles[idx].insert(rel)
            if pendingFiles[idx].count > 20_000 {  // burza zmian: taniej przejrzeć cały folder
                pendingFiles[idx].removeAll()
                pendingDirs[idx].insert("")
            }
            touch()
        } else if isDir && (has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRenamed)) {
            // przeniesiony/skopiowany katalog nie zawsze generuje zdarzenia dla plików w środku
            pendingDirs[idx].insert(rel)
            touch()
        }
        // usunięcia ignorujemy: kasowanie lokalne nie jest propagowane
    }

    // MARK: harmonogram

    private var hasPending: Bool {
        zip(pendingFiles, pendingDirs).contains { !$0.isEmpty || !$1.isEmpty }
    }

    private func queueDueFullPasses() {
        let limit = Double(cfg.fullScanHours) * 3600
        for i in folders.indices {
            let key = folders[i].local
            let due = state.lastFullPass[key].map { Date().timeIntervalSince($0) > limit } ?? true
            if due && !pendingDirs[i].contains("") {
                pendingDirs[i].insert("")
                touch()
                forceNow = true
            }
        }
    }

    private func tick() {
        guard !stopping else { return }
        queueDueFullPasses()
        defer { writeStatusLocked() }
        guard !running, hasPending, Date() >= notBefore else { return }
        let now = Date()
        let quiet = now.timeIntervalSince(lastAt ?? now) >= Double(cfg.debounceSeconds)
        let overdue = now.timeIntervalSince(firstAt ?? now) >= Double(cfg.maxWaitSeconds)
        guard quiet || overdue || forceNow else { return }
        flush()
    }

    private func exists(_ root: String, _ rel: String, wantDir: Bool) -> Bool {
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: root + "/" + rel, isDirectory: &isDir)
        // dowiązania symboliczne (też zerwane) przepuszczamy: rclone je pominie (--skip-links)
        return ok && isDir.boolValue == wantDir
    }

    private func flush() {
        forceNow = false
        var jobs: [Job] = []
        for i in folders.indices {
            var dirs = pendingDirs[i]
            var files = pendingFiles[i]
            pendingDirs[i] = []
            pendingFiles[i] = []

            if dirs.contains("") {
                dirs = [""]
            } else {
                dirs = dirs.filter { exists(roots[i], $0, wantDir: true) }
                var kept: [String] = []
                for d in dirs.sorted(by: { $0.count < $1.count }) where !kept.contains(where: { d.hasPrefix($0 + "/") }) {
                    kept.append(d)
                }
                dirs = Set(kept)
            }
            files = files.filter { f in
                !dirs.contains(where: { $0.isEmpty || f.hasPrefix($0 + "/") }) && exists(roots[i], f, wantDir: false)
            }
            for d in dirs.sorted() { jobs.append(Job(folder: i, kind: .dir(d))) }
            if !files.isEmpty { jobs.append(Job(folder: i, kind: .files(files.sorted()))) }
        }
        firstAt = nil
        lastAt = nil
        guard !jobs.isEmpty else { return }

        running = true
        let idAtStart = latestSeenId
        progress = SyncProgress(folder: folders[jobs[0].folder].local, jobIndex: 1, jobCount: jobs.count, phase: "estimating",
                                currentFiles: [], bytesDone: 0, bytesTotal: 0, speed: 0, etaSeconds: nil, approx: true,
                                filesDone: 0, filesTotal: 0)
        worker.async {
            var failed: [(Job, String)] = []
            var interrupted = false

            // ile jest do wysłania (na podstawie indeksu: nowe i zmienione pliki)
            let estimates: [Int64] = jobs.map { job in
                guard let t = self.tracker else { return 0 }
                switch job.kind {
                case .files(let l): return t.pendingBytes(folder: job.folder, files: l)
                case .dir(let d): return t.pendingBytes(folder: job.folder, rel: d)
                }
            }
            let run = RunProgress(estimates: estimates)

            for (i, job) in jobs.enumerated() {
                if self.q.sync(execute: { self.stopping }) { interrupted = true; break }
                self.q.async {
                    run.index = i
                    run.curDone = 0
                    self.current = "\(self.folders[job.folder].local): \(job.label)"
                    self.progress = self.makeProgress(job: job, run: run, phase: "preparing", bytes: 0, totalBytes: 0,
                                                      speed: 0, files: [], filesDone: 0, filesTotal: 0)
                    self.writeStatusLocked()
                }
                let r = self.execute(job, run: run)
                if r.ok { self.q.async { self.markDone(job) } } else { failed.append((job, r.message)) }
                self.q.async { run.doneBytes += max(run.curDone, run.estimates[run.index]); run.curDone = 0 }
            }
            self.q.async { self.finish(jobs: jobs, failed: failed, interrupted: interrupted, idAtStart: idAtStart) }
        }
    }

    private func markDone(_ job: Job) {
        if job.isFull { state.lastFullPass[folders[job.folder].local] = Date() }
    }

    private func finish(jobs: [Job], failed: [(Job, String)], interrupted: Bool, idAtStart: UInt64) {
        running = false
        current = nil
        progress = nil
        if interrupted || stopping { JSON.write(state, to: Paths.stateFile); writeStatusLocked(); return }

        if failed.isEmpty {
            failures = 0
            lastError = nil
            lastSuccess = Date()
            state.checkpointId = idAtStart
            Log.info("OK: \(jobs.count) zadań, checkpoint \(idAtStart)")
        } else {
            failures += 1
            lastError = failed.last?.1
            let delay = min(30.0 * pow(2.0, Double(failures - 1)), 3600)
            notBefore = Date().addingTimeInterval(delay)
            for (job, msg) in failed {
                Log.error("\(folders[job.folder].local) [\(job.label)]: \(msg) → ponowię za \(Int(delay))s")
                switch job.kind {
                case .files(let l): pendingFiles[job.folder].formUnion(l)
                case .dir(let d): pendingDirs[job.folder].insert(d)
                }
            }
            touch()
            forceNow = true
        }
        JSON.write(state, to: Paths.stateFile)
        writeStatusLocked()
    }

    // MARK: rclone

    private func execute(_ job: Job, run: RunProgress) -> (ok: Bool, message: String) {
        let f = folders[job.folder]
        var src = roots[job.folder]
        var dst = cfg.remoteSpec(for: f)
        var extra: [String] = []
        var listPath: String?

        let track: (Process) -> Void = { p in
            self.procLock.lock(); self.currentProcess = p; self.procLock.unlock()
        }

        // 1) przenosiny: najpierw przenieś na Dysku to, co lokalnie zmieniło tylko adres
        if let t = tracker {
            switch job.kind {
            case .files(let list):
                t.apply(folder: job.folder, rels: list.sorted { $0.split(separator: "/").count < $1.split(separator: "/").count }, track: track)
            case .dir(let rel):
                if t.hasHistory(folder: job.folder) {
                    var rels: [String] = []
                    walkTree(root: roots[job.folder], rel: rel, excludes: cfg.excludes) { r, _ in rels.append(r) }
                    t.apply(folder: job.folder, rels: rels, track: track)
                }
            }
        }

        switch job.kind {
        case .dir(let rel):
            if !rel.isEmpty { src += "/" + rel; dst += "/" + rel }
            extra = ["--fast-list", "--create-empty-src-dirs"]
        case .files(let list):
            let p = Paths.cacheDir + "/files-\(UUID().uuidString).txt"
            try? list.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8)
            listPath = p
            extra = ["--files-from-raw", p, "--no-traverse"]
        }
        defer { if let p = listPath { try? FileManager.default.removeItem(atPath: p) } }

        Log.info("rclone copy \(f.local) → \(dst) [\(job.label)]")
        let args = ["copy", src, dst] + Rclone.copyFlags(cfg, withExcludes: listPath == nil) + extra
        let ctl = JobControl()
        procLock.lock(); currentCtl = ctl; procLock.unlock()
        let r = Rclone.runJob(rclone, args, ctl: ctl, interactive: false) { line in self.handleRcloneLine(line, job: job, run: run) }
        procLock.lock(); currentCtl = nil; currentProcess = nil; procLock.unlock()
        if ctl.cancelled { return (false, "przerwano") }

        if r.code == 0 {
            // 2) zapamiętaj, co wysłane (i-węzeł → ścieżka), żeby wykryć przyszłe przenosiny
            switch job.kind {
            case .files(let list): tracker?.record(folder: job.folder, files: list)
            case .dir(let rel): tracker?.recordTree(folder: job.folder, rel: rel)
            }
            return (true, "")
        }
        return (false, "rclone kod \(r.code)" + (r.tail.isEmpty ? "" : ": " + r.tail))
    }

    // MARK: postęp

    private func handleRcloneLine(_ line: String, job: Job, run: RunProgress) {
        guard let data = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { RcloneLog.append(line); return }
        if let st = o["stats"] as? [String: Any] {
            q.async { self.applyStats(st, job: job, run: run) }
        } else {
            RcloneLog.append(o)
        }
    }

    private func applyStats(_ s: [String: Any], job: Job, run: RunProgress) {
        guard running, !stopping else { return }
        func num(_ k: String) -> Double { (s[k] as? NSNumber)?.doubleValue ?? 0 }
        let names = (s["transferring"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let bytes = Int64(num("bytes"))
        run.curDone = bytes
        progress = makeProgress(job: job, run: run, phase: (!names.isEmpty || bytes > 0) ? "uploading" : "scanning",
                                bytes: bytes, totalBytes: Int64(num("totalBytes")), speed: num("speed"), files: names,
                                filesDone: Int(num("transfers")), filesTotal: Int(num("totalTransfers")))
    }

    /// Łączy dane rclone z szacunkiem całego przebiegu (kolejne zadania jeszcze nieznane rclone'owi).
    private func makeProgress(job: Job, run: RunProgress, phase: String, bytes: Int64, totalBytes: Int64,
                              speed: Double, files: [String], filesDone: Int, filesTotal: Int) -> SyncProgress {
        if speed > 2048 { run.speed = speed }
        let speed = speed > 2048 ? speed : run.speed
        let est = run.estimates[run.index]
        let curTotal = max(totalBytes, est)
        let others = run.estimates.dropFirst(run.index + 1).reduce(Int64(0), +)
        let total = run.doneBytes + curTotal + others
        let done = run.doneBytes + min(bytes, curTotal)
        let remaining = max(total - done, 0)
        var eta: Int? = nil
        if remaining == 0 && phase == "uploading" { eta = 0 } else if speed > 2048 { eta = Int(Double(remaining) / speed) }
        let approx = phase != "uploading" || others > 0 || Double(est) > Double(totalBytes) * 1.05
        return SyncProgress(folder: folders[job.folder].local, jobIndex: run.index + 1, jobCount: run.estimates.count,
                            phase: phase, currentFiles: files, bytesDone: done, bytesTotal: total, speed: speed,
                            etaSeconds: eta, approx: approx, filesDone: filesDone, filesTotal: filesTotal)
    }

    // MARK: status

    /// Bezpieczne do wywołania z dowolnego wątku (zapis na kolejce silnika).
    func writeStatus() { q.async { self.writeStatusLocked() } }

    /// Aktualny stan dla GUI (nie wywoływać z kolejki silnika).
    func statusSnapshot() -> Status { q.sync { makeStatus() } }

    private func writeStatusLocked() { JSON.write(makeStatus(), to: Paths.statusFile) }

    private func makeStatus() -> Status {
        let m = mountSnapshot()
        return Status(
            pid: getpid(), startedAt: startedAt, updatedAt: Date(),
            syncState: running ? "syncing" : (failures > 0 ? "error" : (hasPending ? "waiting" : "idle")),
            current: current,
            pendingFiles: pendingFiles.reduce(0) { $0 + $1.count },
            pendingDirs: pendingDirs.reduce(0) { $0 + $1.count },
            lastSuccess: lastSuccess, lastError: lastError, consecutiveFailures: failures,
            mountState: m.state, mountPath: m.path, progress: running ? progress : nil)
    }
}
