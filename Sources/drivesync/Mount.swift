import Foundation

/// Pilnuje `rclone nfsmount`: uruchamia, restartuje po awarii (z narastającą przerwą),
/// sprząta martwe montowania. NFS-owy mount nie wymaga macFUSE ani rozszerzeń jądra.
final class MountSupervisor {
    private let cfg: Config
    private let rclone: String
    private let q = DispatchQueue(label: "drivesync.mount")
    private let lock = NSLock()
    private var _state = "stopped"
    private var proc: Process?
    private var shuttingDown = false
    private var backoff = 5.0
    private var mountedSince: Date?
    private var poll: DispatchSourceTimer?
    private var retry: DispatchWorkItem?

    private var mountPath: String { Paths.expand(cfg.mount.path) }

    init(cfg: Config, rclone: String) {
        self.cfg = cfg
        self.rclone = rclone
    }

    var snapshot: (state: String, path: String?) {
        lock.lock(); defer { lock.unlock() }
        return (_state, cfg.mount.enabled ? mountPath : nil)
    }

    private func setState(_ s: String) { lock.lock(); _state = s; lock.unlock() }

    private var desired: Bool {
        cfg.mount.enabled && !FileManager.default.fileExists(atPath: Paths.mountDisabledFlag)
    }

    /// Wywołuj po starcie i po SIGUSR2 (zmiana flagi mount.disabled).
    func reconcile() {
        q.async {
            if self.shuttingDown { return }
            if !self.desired {
                self.stopLocked()
                self.setState("disabled")
            } else if self.proc == nil {
                self.launch()
            }
        }
    }

    func shutdown() {
        q.sync {
            shuttingDown = true
            stopLocked()
            setState("stopped")
        }
    }

    // MARK: -

    private func args() -> [String] {
        let m = cfg.mount
        var a = [
            "nfsmount", "\(cfg.remote):", mountPath,
            "--volname", m.volumeName,
            "--vfs-cache-mode", "full",
            "--cache-dir", Paths.cacheDir + "/vfs",
            "--vfs-cache-max-size", m.cacheMaxSize,
            "--vfs-cache-min-free-space", m.cacheMinFreeSpace,
            "--vfs-cache-max-age", m.cacheMaxAge,
            "--dir-cache-time", m.dirCacheTime,
            "--poll-interval", "1m",
            "--vfs-read-ahead", m.readAhead,
            "--vfs-read-chunk-size", "64M",
            "--vfs-read-chunk-size-limit", "1G",
            "--buffer-size", "32M",
            "--noapplexattr",
            "--log-file", Paths.rcloneLog,
            "--log-level", "INFO",
        ]
        if m.readOnly { a.append("--read-only") }
        return a
    }

    private func launch() {
        let path = mountPath
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: Paths.cacheDir + "/vfs", withIntermediateDirectories: true)
        if Mounts.isMounted(path) {
            Log.info("mount: czyszczę stare montowanie \(path)")
            Mounts.forceUnmount(path)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: rclone)
        p.arguments = args()
        p.environment = Proc.env
        p.qualityOfService = .utility
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { Log.error("mount/rclone: \(s.prefix(500))") }
        }
        p.terminationHandler = { [weak self] term in self?.q.async { self?.exited(term) } }

        do {
            try p.run()
        } catch {
            Log.error("mount: nie mogę uruchomić rclone: \(error)")
            setState("error")
            scheduleRetry()
            return
        }
        proc = p
        mountedSince = nil
        setState("starting")
        Log.info("mount: start → \(path)")

        poll?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 2, repeating: 3)
        t.setEventHandler { [weak self] in self?.checkMounted() }
        t.resume()
        poll = t
    }

    private func checkMounted() {
        guard proc != nil else { return }
        if Mounts.isMounted(mountPath) {
            if mountedSince == nil { mountedSince = Date(); Log.info("mount: podłączony (\(mountPath))") }
            setState("mounted")
            if let s = mountedSince, Date().timeIntervalSince(s) > 60 { backoff = 5 }
        }
    }

    private func exited(_ p: Process) {
        guard p === proc else { return }
        proc = nil
        poll?.cancel(); poll = nil
        if Mounts.isMounted(mountPath) { Mounts.forceUnmount(mountPath) }
        if shuttingDown { return }
        if !desired { setState("disabled"); return }
        Log.error("mount: rclone zakończył się (kod \(p.terminationStatus)), restart za \(Int(backoff))s")
        setState("error")
        scheduleRetry()
    }

    private func scheduleRetry() {
        retry?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, !self.shuttingDown, self.desired, self.proc == nil else { return }
            self.launch()
        }
        retry = w
        q.asyncAfter(deadline: .now() + backoff, execute: w)
        backoff = min(backoff * 2, 300)
    }

    private func stopLocked() {
        retry?.cancel(); retry = nil
        poll?.cancel(); poll = nil
        if let p = proc {
            p.terminationHandler = nil
            p.terminate()  // rclone przy SIGTERM sam odmontowuje
            let deadline = Date().addingTimeInterval(10)
            while p.isRunning && Date() < deadline { usleep(100_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            proc = nil
        }
        if Mounts.isMounted(mountPath) { Mounts.forceUnmount(mountPath) }
    }
}
