import SwiftUI
import AppKit

struct JobState {
    enum Phase { case running, done, failed }
    var title: String
    var step: String = ""
    var line: String = ""
    var phase: Phase = .running
    var message: String = ""
}

/// Stan aplikacji dla widoków. Wszystkie zmiany @Published odbywają się na głównym wątku.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var status: Status?
    @Published var issue: String?
    @Published var needsAccount = false
    @Published var accountBusy = false
    @Published var accountMessage: String?
    @Published var offloaded: [OffloadedItem] = []
    @Published var job: JobState?
    @Published var config = Config()
    @Published var launchAtLogin = LoginItem.enabled
    @Published var settingsTab = 0
    @Published var mountDisabledByUser = FileManager.default.fileExists(atPath: Paths.mountDisabledFlag)

    private(set) var daemon: Daemon?
    private var timer: Timer?
    private var accountCtl: JobControl?
    private var jobCtl: JobControl?
    private var bootGen = 0

    // MARK: start / stop

    func boot() {
        config = (try? Config.load()) ?? Config()
        issue = nil
        needsAccount = false
        startTimer()
        guard let bin = Rclone.binary(config) else {
            issue = "Nie znaleziono rclone. Zainstaluj go poleceniem: brew install rclone"
            return
        }
        let cfg = config
        bootGen += 1
        let gen = bootGen
        DispatchQueue.global().async {
            let remotes = Proc.run(bin, ["listremotes"]).out
            let has = remotes.split(separator: "\n").contains { $0 == "\(cfg.remote):" }
            DispatchQueue.main.async {
                guard gen == self.bootGen else { return }  // nowszy boot przejął sprawę
                if has { self.startDaemon(cfg) } else { self.needsAccount = true; self.refresh() }
            }
        }
    }

    private func startDaemon(_ cfg: Config) {
        guard daemon == nil else { refresh(); return }  // nigdy dwa silniki naraz
        do {
            let d = try Daemon(cfg: cfg)
            d.start()
            daemon = d
        } catch { issue = error.localizedDescription }
        refreshOffloaded()
        refresh()
    }

    func shutdown() {
        timer?.invalidate()
        daemon?.stop()
        daemon = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        status = daemon?.engine.statusSnapshot()
        mountDisabledByUser = FileManager.default.fileExists(atPath: Paths.mountDisabledFlag)
    }

    func refreshOffloaded() {
        offloaded = Registry.list().filter {
            var st = stat()
            return lstat($0.path, &st) == 0 && UInt32(st.st_mode) & 0o170000 == 0o120000
        }
    }

    // MARK: wygląd

    var iconName: String {
        if issue != nil || needsAccount { return "icloud.slash" }
        switch status?.syncState {
        case "syncing": return "arrow.triangle.2.circlepath.icloud"
        case "error": return "exclamationmark.icloud"
        default: return "checkmark.icloud"
        }
    }

    var iconColor: Color {
        if issue != nil { return .red }
        if needsAccount { return .orange }
        switch status?.syncState {
        case "syncing": return .blue
        case "error": return .red
        case "waiting": return .orange
        default: return .green
        }
    }

    var headline: String {
        if issue != nil { return "Wymaga uwagi" }
        if needsAccount { return "Nie połączono z Google Drive" }
        switch status?.syncState {
        case "syncing": return "Synchronizuję…"
        case "waiting": return "Zmiany czekają na wysłanie"
        case "error": return "Błąd synchronizacji"
        case "idle": return "Wszystko zsynchronizowane"
        default: return "Uruchamianie…"
        }
    }

    var subline: String {
        guard let s = status else { return "" }
        switch s.syncState {
        case "syncing": return s.progress == nil ? (s.current ?? "") : ""  // szczegóły w bloku postępu
        case "error": return s.lastError ?? ""
        case "waiting": return "Pliki: \(s.pendingFiles), katalogi: \(s.pendingDirs)"
        default: return "Ostatnio: \(ago(s.lastSuccess))"
        }
    }

    var mountText: String {
        switch status?.mountState {
        case "mounted": return "zamontowany"
        case "starting": return "montuje się…"
        case "error": return "błąd, ponawiam"
        case "disabled": return "odmontowany"
        default: return "—"
        }
    }

    var isMounted: Bool { status?.mountState == "mounted" }

    var progress: SyncProgress? { status?.syncState == "syncing" ? status?.progress : nil }

    /// Tekst obok ikony na pasku menu, np. „42%”, gdy trwa wysyłanie.
    var menuBarText: String? {
        guard let p = progress, p.phase == "uploading", p.bytesTotal > 0 else { return nil }
        return "\(Int(p.fraction * 100))%"
    }

    // MARK: akcje

    func syncNow() { daemon?.engine.syncNow() }

    func toggleMount() {
        if FileManager.default.fileExists(atPath: Paths.mountDisabledFlag) {
            try? FileManager.default.removeItem(atPath: Paths.mountDisabledFlag)
        } else {
            FileManager.default.createFile(atPath: Paths.mountDisabledFlag, contents: nil)
        }
        daemon?.mount.reconcile()
        refresh()
    }

    func openDrive() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.expand(config.mount.path)))
    }

    func openLogs() { NSWorkspace.shared.open(URL(fileURLWithPath: Paths.logs)) }

    func openSettings(tab: Int = 0) {
        settingsTab = tab
        WindowManager.shared.show("settings", title: "DriveSync", size: NSSize(width: 580, height: 760)) {
            SettingsView(model: self)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        LoginItem.set(on)
        launchAtLogin = LoginItem.enabled
    }

    func apply(_ new: Config) {
        do { try new.write() } catch {
            alert("Nie udało się zapisać ustawień", error.localizedDescription)
            return
        }
        let d = daemon
        daemon = nil
        status = nil
        DispatchQueue.global().async {
            d?.stop()
            DispatchQueue.main.async { self.boot() }
        }
    }

    // MARK: konto

    func connectAccount(clientID: String, secret: String) {
        guard let bin = Rclone.binary(config) else { return }
        accountBusy = true
        accountMessage = "Otworzyła się przeglądarka. Zaloguj się do Google i zatwierdź dostęp…"
        let ctl = JobControl()
        accountCtl = ctl
        let remote = config.remote
        var args: [String]
        if needsAccount {
            args = ["config", "create", remote, "drive", "scope=drive"]
            if !clientID.isEmpty { args.append("client_id=\(clientID)") }
            if !secret.isEmpty { args.append("client_secret=\(secret)") }
        } else {
            args = ["config", "reconnect", "\(remote):", "--auto-confirm"]
        }
        DispatchQueue.global().async {
            let r = Rclone.runJob(bin, args, ctl: ctl, interactive: false)
            DispatchQueue.main.async {
                self.accountBusy = false
                if ctl.cancelled { self.accountMessage = "Anulowano."; return }
                if r.code == 0 {
                    self.accountMessage = nil
                    if self.daemon == nil { self.boot() }
                } else {
                    self.accountMessage = "Logowanie nie powiodło się. \(r.tail)"
                }
            }
        }
    }

    func cancelAccount() { accountCtl?.cancel() }

    // MARK: odciążanie / przywracanie

    func chooseAndOffload() {
        guard daemon != nil else { alert("Najpierw połącz konto", "Odciążanie wymaga połączenia z Google Drive."); return }
        if job?.phase == .running { showJob(); return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: Paths.home)
        panel.message = "Wybierz katalog, który ma zostać wyłącznie na Dysku Google"
        panel.prompt = "Wybierz"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startOffload(path: url.path)
    }

    private func startOffload(path: String) {
        guard let d = daemon else { return }
        let cfg = d.cfg, bin = d.rclone
        DispatchQueue.global().async {
            do {
                let plan = try Offload.plan(path, cfg: cfg)
                DispatchQueue.main.async { self.confirmOffload(plan, cfg: cfg, bin: bin) }
            } catch {
                DispatchQueue.main.async { self.alert("Nie można odciążyć tego katalogu", error.localizedDescription) }
            }
        }
    }

    private func confirmOffload(_ plan: OffloadPlan, cfg: Config, bin: String) {
        let name = (plan.abs as NSString).lastPathComponent
        let a = NSAlert()
        a.messageText = "Odciążyć „\(name)”?"
        a.informativeText = """
            \(plan.snapshot.files.count) plików, \(formatBytes(plan.snapshot.bytes)).

            Katalog zostanie wysłany na Dysk Google, a każdy plik zweryfikowany sumą kontrolną. Dopiero potem zostanie skasowany z tego komputera. W jego miejscu pojawi się dowiązanie do zamontowanego Dysku, więc do plików dostaniesz się przez internet.

            Do przywrócenia użyj „Odciążone katalogi”.
            """
        a.alertStyle = .warning
        a.addButton(withTitle: "Odciąż")
        a.addButton(withTitle: "Anuluj")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let ctl = JobControl()
        jobCtl = ctl
        job = JobState(title: "Odciążanie: \(name)")
        showJob()
        DispatchQueue.global().async {
            do {
                try Offload.execute(plan, cfg: cfg, rclone: bin, link: cfg.mount.enabled, ctl: ctl, interactive: false,
                                    step: { s in DispatchQueue.main.async { self.job?.step = s; self.job?.line = "" } },
                                    line: { l in if l.contains("%") || l.contains("ERROR") { DispatchQueue.main.async { self.job?.line = l } } })
                DispatchQueue.main.async {
                    self.job?.phase = .done
                    self.job?.step = "Gotowe"
                    self.job?.line = ""
                    self.job?.message = "Zwolniono \(formatBytes(plan.snapshot.bytes)). Pliki są na Dysku Google i dostępne przez dowiązanie w tym samym miejscu."
                    self.refreshOffloaded()
                }
            } catch {
                DispatchQueue.main.async {
                    self.job?.phase = .failed
                    self.job?.step = "Nie udało się"
                    self.job?.message = error.localizedDescription
                }
            }
        }
    }

    func restore(_ item: OffloadedItem) {
        guard let d = daemon else { return }
        if job?.phase == .running { showJob(); return }
        let name = (item.path as NSString).lastPathComponent
        let a = NSAlert()
        a.messageText = "Przywrócić „\(name)” na ten komputer?"
        a.informativeText = "Pobranie zajmie około \(formatBytes(item.bytes)) miejsca na dysku."
        a.addButton(withTitle: "Przywróć")
        a.addButton(withTitle: "Anuluj")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let cfg = d.cfg, bin = d.rclone
        let ctl = JobControl()
        jobCtl = ctl
        job = JobState(title: "Przywracanie: \(name)")
        showJob()
        DispatchQueue.global().async {
            do {
                try Offload.restore(item.path, cfg: cfg, rclone: bin, ctl: ctl, interactive: false,
                                    step: { s in DispatchQueue.main.async { self.job?.step = s; self.job?.line = "" } },
                                    line: { l in if l.contains("%") || l.contains("ERROR") { DispatchQueue.main.async { self.job?.line = l } } })
                DispatchQueue.main.async {
                    self.job?.phase = .done
                    self.job?.step = "Gotowe"
                    self.job?.line = ""
                    self.job?.message = "Katalog jest znów na tym komputerze."
                    self.refreshOffloaded()
                }
            } catch {
                DispatchQueue.main.async {
                    self.job?.phase = .failed
                    self.job?.step = "Nie udało się"
                    self.job?.message = error.localizedDescription
                }
            }
        }
    }

    func showJob() {
        WindowManager.shared.show("job", title: "Postęp", size: NSSize(width: 460, height: 230)) { JobView(model: self) }
    }

    func cancelJob() { jobCtl?.cancel() }

    func closeJob() {
        job = nil
        WindowManager.shared.close("job")
    }

    // MARK: pomocnicze

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

// MARK: - Okna (hostowane ręcznie, żeby w aplikacji paska menu nic nie otwierało się samo)

final class WindowManager {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]

    func show<V: View>(_ id: String, title: String, size: NSSize, @ViewBuilder content: () -> V) {
        if let w = windows[id], w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: content()))
        w.title = title
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(size)
        w.isReleasedWhenClosed = false
        w.center()
        windows[id] = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(_ id: String) {
        windows[id]?.close()
        windows[id] = nil
    }
}
