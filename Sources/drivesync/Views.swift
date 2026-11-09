import SwiftUI
import AppKit

// MARK: - Aplikacja

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // bez ikony w Docku
        Signals.install(daemon: { AppModel.shared.daemon }, quit: { NSApp.terminate(nil) })
        AppModel.shared.boot()
        if let n = ProcessInfo.processInfo.environment["DRIVESYNC_TEST_BOOTS"].flatMap(Int.init) {
            for _ in 0..<n { AppModel.shared.boot() }  // test odporności na wielokrotny start
        }
        // do testów: DRIVESYNC_OPEN=settings|offloaded
        switch ProcessInfo.processInfo.environment["DRIVESYNC_OPEN"] {
        case "settings": AppModel.shared.openSettings(tab: 0)
        case "offloaded": AppModel.shared.openSettings(tab: 1)
        default: break
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
        PidFile.release()
        Log.info("koniec")
        Log.flush()
    }
}

struct DriveSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.iconName)
                if let t = model.menuBarText { Text(t).monospacedDigit() }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu na pasku

private struct MenuRow: View {
    let icon: String
    let title: String
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    init(icon: String, title: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(hover && !disabled ? Color.primary.opacity(0.09) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover = $0 }
    }
}

/// Co robi synchronizacja teraz, ile już wysłano i ile zostało do końca.
struct ProgressBlock: View {
    let p: SyncProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if p.bytesTotal > 0 {
                ProgressView(value: p.fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(p.bytesTotal > 0 ? "\(Int(p.fraction * 100))% · \(p.sizeText)" : p.phaseText)
                Spacer()
                Text(p.speedText).foregroundStyle(.secondary)
            }
            .font(.callout)
            Text(p.etaText).font(.callout).bold()
            if p.bytesTotal > 0 {
                Text(p.phaseText).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Text("Zadanie \(p.jobIndex) z \(p.jobCount): \(p.folder)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

struct MenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: model.iconName).font(.system(size: 26)).foregroundStyle(model.iconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.headline).font(.headline)
                    if !model.subline.isEmpty {
                        Text(model.subline).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }

            if let p = model.progress, model.issue == nil, !model.needsAccount {
                ProgressBlock(p: p)
            }

            if let issue = model.issue {
                Text(issue).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if model.needsAccount {
                Text("Połącz konto Google, żeby zacząć kopiować pliki i podłączyć Dysk.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Połącz z Google Drive…") { model.openSettings(tab: 0) }.buttonStyle(.borderedProminent)
            } else if let s = model.status {
                if s.syncState == "error", let e = s.lastError {
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
                HStack {
                    Text("Dysk Google").foregroundStyle(.secondary)
                    Spacer()
                    Text(model.mountText)
                }.font(.callout)
            }

            Divider()

            if !model.needsAccount && model.issue == nil {
                MenuRow(icon: "arrow.clockwise", title: "Synchronizuj teraz") { model.syncNow() }
                MenuRow(icon: "externaldrive", title: "Otwórz Dysk Google", disabled: !model.isMounted) { model.openDrive() }
                MenuRow(icon: model.mountDisabledByUser ? "eject.circle" : "eject",
                        title: model.mountDisabledByUser ? "Zamontuj Dysk" : "Odmontuj Dysk") { model.toggleMount() }
                Divider()
                MenuRow(icon: "arrow.down.to.line", title: "Odciąż katalog…") { model.chooseAndOffload() }
                MenuRow(icon: "tray.full", title: "Odciążone katalogi (\(model.offloaded.count))") { model.openSettings(tab: 1) }
                if model.job != nil { MenuRow(icon: "hourglass", title: "Pokaż postęp") { model.showJob() } }
                Divider()
            }
            MenuRow(icon: "gearshape", title: "Ustawienia…") { model.openSettings(tab: 0) }
            MenuRow(icon: "doc.text", title: "Pokaż logi") { model.openLogs() }
            MenuRow(icon: "power", title: "Zakończ") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 320)
    }
}

// MARK: - Ustawienia

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var cfg: Config
    @State private var clientID = ""
    @State private var secret = ""

    init(model: AppModel) {
        self.model = model
        _cfg = State(initialValue: model.config)
    }

    var body: some View {
        TabView(selection: $model.settingsTab) {
            general.tabItem { Label("Ustawienia", systemImage: "gearshape") }.tag(0)
            OffloadedView(model: model).tabItem { Label("Odciążone", systemImage: "tray.full") }.tag(1)
        }
        .padding(12)
    }

    private var overlap: Bool {
        for a in cfg.folders { for b in cfg.folders where a.local != b.local {
            if Paths.expand(a.local).hasPrefix(Paths.expand(b.local) + "/") { return true }
        } }
        return false
    }

    private var general: some View {
        VStack(spacing: 0) {
            Form {
                Section("Konto Google") {
                    HStack {
                        Image(systemName: model.needsAccount ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(model.needsAccount ? .orange : .green)
                        Text(model.needsAccount ? "Nie połączono" : "Połączono")
                        Spacer()
                        if model.accountBusy {
                            ProgressView().controlSize(.small)
                            Button("Anuluj") { model.cancelAccount() }
                        } else {
                            Button(model.needsAccount ? "Połącz z Google Drive…" : "Zaloguj ponownie…") {
                                model.connectAccount(clientID: clientID, secret: secret)
                            }
                        }
                    }
                    if let m = model.accountMessage {
                        Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if model.needsAccount {
                        DisclosureGroup("Własny klucz OAuth (zalecane, szybszy transfer)") {
                            TextField("client_id", text: $clientID)
                            SecureField("client_secret", text: $secret)
                            Text("Utwórz w Google Cloud Console: Drive API → OAuth client ID (Desktop app). Bez tego użyty zostanie współdzielony klucz rclone, który Google ogranicza.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Foldery kopiowane na Dysk") {
                    ForEach(cfg.folders.indices, id: \.self) { i in
                        HStack {
                            Text(cfg.folders[i].local).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("", text: $cfg.folders[i].remote, prompt: Text("nazwa na Dysku")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 150)
                            Button { cfg.folders.remove(at: i) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Dodaj folder…") { addFolder() }
                    Text("Kopiowanie jest jednokierunkowe i nigdy nie kasuje niczego na Dysku. Pliki lądują w „Mój dysk/\(cfg.remoteRoot)/…”.")
                        .font(.caption).foregroundStyle(.secondary)
                    if overlap {
                        Text("Uwaga: jeden z folderów leży wewnątrz innego, więc jego pliki trafią na Dysk dwa razy.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                Section("Dysk Google w Finderze") {
                    Toggle("Montuj Dysk w \(cfg.mount.path)", isOn: $cfg.mount.enabled)
                    Toggle("Tylko do odczytu (bezpieczniej)", isOn: $cfg.mount.readOnly).disabled(!cfg.mount.enabled)
                    Picker("Maks. cache na dysku", selection: $cfg.mount.cacheMaxSize) {
                        ForEach(cacheChoices, id: \.self) { Text($0.replacingOccurrences(of: "G", with: " GB")).tag($0) }
                    }.disabled(!cfg.mount.enabled)
                }

                Section("System") {
                    Toggle("Uruchamiaj przy logowaniu", isOn: Binding(
                        get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Przywróć") { cfg = model.config }
                Button("Zapisz i zastosuj") { model.apply(cfg) }
                    .buttonStyle(.borderedProminent)
                    .disabled(cfg.folders.isEmpty)
            }
            .padding(.top, 8)
        }
        .onChange(of: model.config.remote) { _ in cfg = model.config }
    }

    private var cacheChoices: [String] {
        var c = ["2G", "4G", "8G", "16G"]
        if !c.contains(cfg.mount.cacheMaxSize) { c.append(cfg.mount.cacheMaxSize) }
        return c
    }

    private func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.directoryURL = URL(fileURLWithPath: Paths.home)
        p.prompt = "Dodaj"
        guard p.runModal() == .OK else { return }
        for url in p.urls {
            var local = url.path
            if local.hasPrefix(Paths.home + "/") { local = "~" + local.dropFirst(Paths.home.count) }
            guard !cfg.folders.contains(where: { $0.local == local }) else { continue }
            cfg.folders.append(FolderMap(local: local, remote: url.lastPathComponent))
        }
    }
}

// MARK: - Odciążone katalogi

struct OffloadedView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Odciążone katalogi są wyłącznie na Dysku Google. W ich miejscu na komputerze jest dowiązanie, które działa, gdy Dysk jest zamontowany (potrzebny internet).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if model.offloaded.isEmpty {
                Spacer()
                Text("Nic jeszcze nie odciążono.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(model.offloaded) { item in
                    HStack {
                        Image(systemName: "folder.badge.minus")
                        VStack(alignment: .leading, spacing: 2) {
                            Text((item.path as NSString).lastPathComponent).font(.body)
                            Text(item.path.replacingOccurrences(of: Paths.home, with: "~"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(formatBytes(item.bytes)).foregroundStyle(.secondary)
                        Button("Przywróć") { model.restore(item) }
                    }
                }
            }
            HStack {
                Button("Odciąż katalog…") { model.chooseAndOffload() }
                    .disabled(model.daemon == nil)
                Spacer()
            }
        }
        .padding(8)
        .onAppear { model.refreshOffloaded() }
    }
}

// MARK: - Okno postępu

struct JobView: View {
    @ObservedObject var model: AppModel

    /// „1.2 GiB / 5.0 GiB, 24%, 38 MiB/s…” → 24
    static func percent(_ line: String) -> Double? {
        guard let r = line.range(of: #"(\d{1,3})%"#, options: .regularExpression) else { return nil }
        return Double(line[r].dropLast())
    }

    var body: some View {
        let job = model.job ?? JobState(title: "")
        VStack(alignment: .leading, spacing: 12) {
            Text(job.title).font(.headline)
            if job.phase == .running {
                if let pct = JobView.percent(job.line) { ProgressView(value: pct, total: 100) } else { ProgressView().progressViewStyle(.linear) }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: job.phase == .done ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(job.phase == .done ? .green : .red)
                    Text(job.step)
                }
            }
            if job.phase == .running { Text(job.step) }
            if !job.line.isEmpty {
                Text(job.line).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            }
            if !job.message.isEmpty {
                Text(job.message).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack {
                Spacer()
                if job.phase == .running {
                    Button("Anuluj") { model.cancelJob() }.disabled(job.step.hasPrefix("4/4"))
                } else {
                    Button("Zamknij") { model.closeJob() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460, height: 230)
    }
}

// MARK: - Podgląd bez ekranu (do testów): renderuje widoki do PNG

enum Snapshots {
    static func run(outDir: String) -> Never {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel.shared
        model.boot()
        RunLoop.main.run(until: Date().addingTimeInterval(14))  // czas na start silnika i pierwszą synchronizację
        model.refresh()
        model.refreshOffloaded()

        func shot<V: View>(_ name: String, _ view: V, size: NSSize) {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
            w.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            w.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: outDir + "/" + name + ".png"))
            }
            w.close()
        }

        shot("menu", MenuView(model: model), size: NSSize(width: 320, height: 420))
        if let st = model.status {
            var fake = st
            fake.syncState = "syncing"
            fake.progress = SyncProgress(folder: "~/Documents", jobIndex: 2, jobCount: 6, phase: "uploading",
                                         currentFiles: ["Skany/seria1/IMG_0042.dcm", "Skany/seria1/IMG_0043.dcm"],
                                         bytesDone: 3_400_000_000, bytesTotal: 11_800_000_000, speed: 38_000_000,
                                         etaSeconds: 4_100, approx: true, filesDone: 120, filesTotal: 900)
            model.status = fake
            shot("menu-syncing", MenuView(model: model), size: NSSize(width: 320, height: 520))
            model.status = st
        }
        model.settingsTab = 0
        shot("settings", SettingsView(model: model), size: NSSize(width: 560, height: 640))
        model.settingsTab = 1
        shot("offloaded", SettingsView(model: model), size: NSSize(width: 560, height: 360))
        model.job = JobState(title: "Odciążanie: Skany", step: "1/4 Wysyłanie na Dysk…",
                             line: "1.2 GiB / 5.0 GiB, 24%, 38 MiB/s, ETA 1m36s")
        shot("job-running", JobView(model: model), size: NSSize(width: 460, height: 230))
        model.job = JobState(title: "Odciążanie: Skany", step: "Gotowe", phase: .done,
                             message: "Zwolniono 5,0 GB. Pliki są na Dysku Google i dostępne przez dowiązanie w tym samym miejscu.")
        shot("job-done", JobView(model: model), size: NSSize(width: 460, height: 230))
        model.shutdown()
        exit(0)
    }
}
