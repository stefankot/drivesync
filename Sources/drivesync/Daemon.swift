import Foundation
import Darwin

struct DaemonError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Silnik synchronizacji + pilnowanie montowania. Używany i przez tryb bez okien (`run`), i przez GUI.
final class Daemon {
    let cfg: Config
    let rclone: String
    let mount: MountSupervisor
    let engine: SyncEngine

    init(cfg: Config) throws {
        guard let bin = Rclone.binary(cfg) else { throw DaemonError("Nie znaleziono rclone (brew install rclone).") }
        guard let e = SyncEngine(cfg: cfg, rclone: bin) else { throw DaemonError("Żaden z folderów z ustawień nie istnieje.") }
        self.cfg = cfg
        rclone = bin
        engine = e
        mount = MountSupervisor(cfg: cfg, rclone: bin)
        let m = mount
        e.mountSnapshot = { m.snapshot }
    }

    func start() {
        Log.info("start, rclone: \(rclone)")
        engine.start()
        mount.reconcile()
    }

    func stop() {
        engine.stop()
        mount.shutdown()
    }
}

// MARK: - Plik PID (CLI wie, czy demon działa i gdzie wysłać sygnał)

enum PidFile {
    static func running() -> Int32? {
        guard let s = try? String(contentsOfFile: Paths.pidFile, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0 else { return nil }
        return pid
    }

    /// false, jeśli inna instancja już działa.
    static func acquire() -> Bool {
        if let pid = running(), pid != getpid() { return false }
        try? FileManager.default.createDirectory(atPath: Paths.support, withIntermediateDirectories: true)
        try? "\(getpid())".write(toFile: Paths.pidFile, atomically: true, encoding: .utf8)
        return true
    }

    static func release() { try? FileManager.default.removeItem(atPath: Paths.pidFile) }
}

// MARK: - Sygnały (CLI: `drivesync sync` / `mount` / `unmount`)

enum Signals {
    private static var sources: [DispatchSourceSignal] = []

    static func install(daemon: @escaping () -> Daemon?, quit: @escaping () -> Void) {
        func on(_ sig: Int32, _ f: @escaping () -> Void) {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler(handler: f)
            s.resume()
            sources.append(s)
        }
        on(SIGUSR1) { daemon()?.engine.syncNow() }
        on(SIGUSR2) { daemon()?.mount.reconcile() }
        on(SIGTERM, quit)
        on(SIGINT, quit)
    }
}

// MARK: - Autostart przy logowaniu (agent launchd uruchamiający aplikację)

enum LoginItem {
    static var plistPath: String { Paths.home + "/Library/LaunchAgents/pl.drivesync.app.plist" }
    static var enabled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    static func set(_ on: Bool) {
        if !on { try? FileManager.default.removeItem(atPath: plistPath); return }
        guard let exe = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": "pl.drivesync.app",
            "ProgramArguments": [exe, "gui"],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        try? FileManager.default.createDirectory(
            atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        (plist as NSDictionary).write(toFile: plistPath, atomically: true)
    }
}

func ago(_ d: Date?) -> String {
    guard let d = d else { return "nigdy" }
    let s = Int(Date().timeIntervalSince(d))
    if s < 90 { return "\(max(s, 0)) s temu" }
    if s < 5400 { return "\(s / 60) min temu" }
    if s < 172_800 { return "\(s / 3600) h temu" }
    return "\(s / 86400) dni temu"
}
