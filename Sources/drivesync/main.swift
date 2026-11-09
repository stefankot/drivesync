import Foundation
import Darwin

let usage = """
drivesync: jednokierunkowa kopia Mac → Dysk Google + montowanie Dysku

  drivesync gui        uruchom aplikację z paskiem menu (zwykle: DriveSync.app)
  drivesync run        demon bez okien
  drivesync init       utwórz domyślny config i pokaż ścieżkę
  drivesync doctor     sprawdź rclone, remote, foldery
  drivesync status     pokaż stan demona
  drivesync sync       wymuś pełny przegląd teraz
  drivesync offload [--yes] <katalog>   wyślij na Dysk, zweryfikuj MD5, skasuj lokalnie,
                                        zostaw dowiązanie do zamontowanego Dysku (bez --yes: na sucho)
  drivesync fetch <katalog>             ściągnij odciążony katalog z powrotem
  drivesync mount      zamontuj Dysk (usuwa blokadę)
  drivesync unmount    odmontuj Dysk (do ponownego `mount`)

Config: \(Paths.configFile)
Logi:   \(Paths.logs)
"""

func daemonPid() -> Int32? { PidFile.running() }

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

// MARK: - komendy

func cmdInit() {
    if FileManager.default.fileExists(atPath: Paths.configFile) {
        print("Config już istnieje: \(Paths.configFile)")
    } else {
        do { try Config().write(); print("Utworzono: \(Paths.configFile)") } catch { fail("błąd: \(error)") }
    }
}

func cmdDoctor() {
    let cfg: Config
    do { cfg = try Config.load() } catch { fail("Config jest uszkodzony (\(Paths.configFile)): \(error)") }
    var problems = 0
    func ok(_ s: String) { print("  ✓ \(s)") }
    func bad(_ s: String) { print("  ✗ \(s)"); problems += 1 }

    print("rclone")
    guard let bin = Rclone.binary(cfg) else {
        bad("nie znaleziono rclone: `brew install rclone`")
        exit(1)
    }
    ok(bin)

    print("remote „\(cfg.remote)”")
    let remotes = Proc.run(bin, ["listremotes"]).out
    if remotes.split(separator: "\n").contains(where: { $0 == "\(cfg.remote):" }) {
        ok("skonfigurowany")
        let r = Proc.run(bin, ["lsd", "\(cfg.remote):", "--max-depth", "1"], timeout: 45)
        if r.code == 0 {
            ok("połączenie z Dyskiem działa (foldery główne: \(r.out.split(separator: "\n").count))")
        } else {
            bad("brak połączenia: \(r.out.split(separator: "\n").last.map(String.init) ?? "?")")
        }
    } else {
        bad("brak remote'a. Uruchom: rclone config  (typ: drive, nazwa: \(cfg.remote))")
    }

    print("foldery")
    for f in cfg.folders {
        let p = Paths.expand(f.local)
        FileManager.default.fileExists(atPath: p)
            ? ok("\(f.local) → \(cfg.remoteSpec(for: f))")
            : bad("\(f.local) nie istnieje")
    }

    print("montowanie")
    if cfg.mount.enabled {
        ok("\(cfg.mount.path), \(cfg.mount.readOnly ? "tylko do odczytu" : "odczyt i zapis"), cache ≤ \(cfg.mount.cacheMaxSize)")
    } else {
        ok("wyłączone w configu")
    }
    print(problems == 0 ? "\nWszystko gotowe." : "\nDo poprawy: \(problems)")
    exit(problems == 0 ? 0 : 1)
}

func cmdStatus() {
    guard let st = JSON.read(Status.self, from: Paths.statusFile) else {
        print("Brak statusu. Demon nigdy nie wystartował? (`drivesync run`)")
        exit(1)
    }
    let alive = daemonPid() != nil
    print("Demon:        \(alive ? "działa (pid \(st.pid))" : "ZATRZYMANY")")
    print("Synchronizacja: \(st.syncState)" + (st.current.map { " — \($0)" } ?? ""))
    if let p = st.progress, alive {
        print("Postęp:       \(p.phaseText)  [zadanie \(p.jobIndex)/\(p.jobCount), \(p.folder)]")
        if p.bytesTotal > 0 {
            print("              \(Int(p.fraction * 100))%  \(p.sizeText)  \(p.speedText)")
        }
        print("              \(p.etaText)")
    }
    print("Kolejka:      \(st.pendingFiles) plików, \(st.pendingDirs) katalogów")
    print("Ostatni sukces: \(ago(st.lastSuccess))")
    if let e = st.lastError { print("Ostatni błąd: \(e) (porażek z rzędu: \(st.consecutiveFailures))") }
    print("Montowanie:   \(st.mountState)" + (st.mountPath.map { " → \($0)" } ?? ""))
    print("Stan zapisany: \(ago(st.updatedAt))")
}

func cmdSignal(_ sig: Int32, what: String) {
    guard let pid = daemonPid() else { fail("Demon nie działa.") }
    kill(pid, sig)
    print(what)
}

// MARK: - demon bez okien

func cmdRun() -> Never {
    Log.setup()
    let cfg: Config
    do { cfg = try Config.load() } catch { Log.error("config: \(error)"); Log.flush(); fail("Config jest uszkodzony: \(error)") }
    guard PidFile.acquire() else { fail("Aplikacja już działa (pid \(PidFile.running() ?? 0)).") }
    let daemon: Daemon
    do { daemon = try Daemon(cfg: cfg) } catch { Log.error("\(error.localizedDescription)"); Log.flush(); fail(error.localizedDescription) }
    daemon.start()

    Signals.install(daemon: { daemon }, quit: {
        Log.info("zatrzymuję…")
        daemon.stop()
        PidFile.release()
        Log.info("koniec")
        Log.flush()
        exit(0)
    })
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + 5, repeating: 10)
    t.setEventHandler { daemon.engine.writeStatus() }
    t.resume()
    dispatchMain()
}

// MARK: - aplikacja z oknami (pasek menu)

func cmdGUI() -> Never {
    Log.setup()
    guard PidFile.acquire() else { fail("Aplikacja już działa (pid \(PidFile.running() ?? 0)).") }
    DriveSyncApp.main()
    exit(0)
}

// MARK: - dispatch

let args = CommandLine.arguments.dropFirst()
// uruchomienie z Findera / launchd (bez argumentów, z wnętrza .app) → okno/pasek menu
let inBundle = Bundle.main.bundlePath.hasSuffix(".app")
switch args.first ?? (inBundle ? "gui" : "help") {
case "run": cmdRun()
case "gui": cmdGUI()
case "snapshot": Log.setup(); Snapshots.run(outDir: args.dropFirst().first ?? "snapshots")
case "init": cmdInit()
case "doctor": cmdDoctor()
case "status": cmdStatus()
case "sync": cmdSignal(SIGUSR1, what: "Zlecono pełny przegląd.")
case "mount":
    try? FileManager.default.removeItem(atPath: Paths.mountDisabledFlag)
    if daemonPid() != nil { cmdSignal(SIGUSR2, what: "Montuję…") } else { print("Zamontuje się po starcie demona.") }
case "offload": Offload.cliOffload(Array(args.dropFirst()))
case "fetch": Offload.cliFetch(Array(args.dropFirst()))
case "unmount":
    try? FileManager.default.createDirectory(atPath: Paths.support, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: Paths.mountDisabledFlag, contents: nil)
    if daemonPid() != nil { cmdSignal(SIGUSR2, what: "Odmontowuję…") } else { print("Zapisano blokadę.") }
default: print(usage)
}
