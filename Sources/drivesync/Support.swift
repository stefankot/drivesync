import Foundation
import Darwin

// MARK: - Log

enum Log {
    private static let q = DispatchQueue(label: "drivesync.log")
    private static var handle: FileHandle?
    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func setup() {
        try? FileManager.default.createDirectory(atPath: Paths.logs, withIntermediateDirectories: true)
        rotate(Paths.mainLog)
        rotate(Paths.rcloneLog)
        if !FileManager.default.fileExists(atPath: Paths.mainLog) {
            FileManager.default.createFile(atPath: Paths.mainLog, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: Paths.mainLog)
        _ = try? handle?.seekToEnd()
    }

    private static func rotate(_ path: String) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        if let size = attrs?[.size] as? Int, size > 10_000_000 {
            try? FileManager.default.removeItem(atPath: path + ".1")
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
        }
    }

    static func info(_ s: String) { write("INFO ", s) }
    static func error(_ s: String) { write("ERROR", s) }

    private static func write(_ level: String, _ s: String) {
        q.async {
            let line = "\(fmt.string(from: Date())) \(level) \(s)\n"
            if let d = line.data(using: .utf8) { handle?.write(d) }
            if isatty(STDOUT_FILENO) != 0 { FileHandle.standardOutput.write(Data(line.utf8)) }
        }
    }

    /// Wymusza zapis przed wyjściem z procesu.
    static func flush() { q.sync {} }
}

// MARK: - JSON helpers

enum JSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func write<T: Encodable>(_ v: T, to path: String) {
        guard let data = try? encoder.encode(v) else { return }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from path: String) -> T? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

// MARK: - State (przeżywa restart)

struct PersistedState: Codable {
    /// ID zdarzenia FSEvents, do którego wszystko jest już wysłane. Po restarcie odtwarzamy
    /// zdarzenia od tego miejsca zamiast skanować całe foldery.
    var checkpointId: UInt64?
    /// Kiedy ostatnio zrobiliśmy pełny przegląd danego folderu (klucz: lokalna ścieżka).
    var lastFullPass: [String: Date] = [:]
}

// MARK: - Status (czytany przez `drivesync status`)

struct Status: Codable {
    var pid: Int32
    var startedAt: Date
    var updatedAt: Date
    var syncState: String          // idle | waiting | syncing | error
    var current: String?
    var pendingFiles: Int
    var pendingDirs: Int
    var lastSuccess: Date?
    var lastError: String?
    var consecutiveFailures: Int
    var mountState: String         // disabled | starting | mounted | error | stopped
    var mountPath: String?
    var progress: SyncProgress?    // tylko gdy trwa wysyłanie
}

/// Postęp bieżącego przebiegu synchronizacji (wszystkie zadania razem).
struct SyncProgress: Codable {
    var folder: String
    var jobIndex: Int              // od 1
    var jobCount: Int
    var phase: String              // estimating | preparing | scanning | uploading
    var currentFiles: [String]
    var bytesDone: Int64
    var bytesTotal: Int64
    var speed: Double              // bajty/s
    var etaSeconds: Int?           // do końca CAŁEGO przebiegu
    var approx: Bool               // szacunek: nie znamy jeszcze pełnego rozmiaru
    var filesDone: Int
    var filesTotal: Int

    var fraction: Double { bytesTotal > 0 ? min(Double(bytesDone) / Double(bytesTotal), 1) : 0 }

    var phaseText: String {
        switch phase {
        case "estimating": return "Liczę, ile jest do wysłania…"
        case "preparing": return "Sprawdzam zmiany…"
        case "scanning": return "Porównuję z Dyskiem…"
        default:
            guard let f = currentFiles.first else { return "Wysyłam…" }
            let name = (f as NSString).lastPathComponent
            return currentFiles.count > 1 ? "Wysyłam: \(name) i \(currentFiles.count - 1) inne" : "Wysyłam: \(name)"
        }
    }

    var etaText: String {
        guard let e = etaSeconds else { return "Obliczam czas do końca…" }
        return "Do końca: " + formatETA(e)
    }

    var sizeText: String { "\(formatBytes(bytesDone)) z \(approx ? "ok. " : "")\(formatBytes(bytesTotal))" }
    var speedText: String { speed > 1024 ? formatSpeed(speed) : "" }
}

/// Zgrubny czas do końca: ma odpowiadać na pytanie „minuta czy godzina?”, a nie podawać minuty co do sekundy.
func formatETA(_ s: Int) -> String {
    let min = s / 60
    switch s {
    case ..<60: return "poniżej minuty"
    case ..<300: return "kilka minut"
    case ..<3_300: return "ok. \(max(5, Int((Double(min) / 5).rounded()) * 5)) min"  // co 5 min
    case ..<5_400: return "ok. godzina"
    case ..<86_400: return "ok. \(Int((Double(s) / 3600).rounded())) h"
    default: return "ponad dobę"
    }
}

func formatSpeed(_ bps: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s" }

/// Log rclone w czytelnej postaci (rclone zwraca JSON, bo z niego czytamy postęp).
enum RcloneLog {
    private static let q = DispatchQueue(label: "drivesync.rclonelog")
    private static var handle: FileHandle? = {
        if !FileManager.default.fileExists(atPath: Paths.rcloneLog) {
            try? FileManager.default.createDirectory(atPath: Paths.logs, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: Paths.rcloneLog, contents: nil)
        }
        let h = FileHandle(forWritingAtPath: Paths.rcloneLog)
        _ = try? h?.seekToEnd()
        return h
    }()

    static func append(_ o: [String: Any]) {
        let t = (o["time"] as? String) ?? ""
        let lvl = ((o["level"] as? String) ?? "info").uppercased()
        let obj = (o["object"] as? String).map { " \($0):" } ?? ""
        append("\(t) \(lvl) :\(obj) \((o["msg"] as? String) ?? "")")
    }

    static func append(_ line: String) {
        q.async { if let d = (line + "\n").data(using: .utf8) { handle?.write(d) } }
    }
}

// MARK: - Procesy

enum Proc {
    /// Uruchamia polecenie i czeka (z limitem czasu). Zwraca kod wyjścia i stdout+stderr.
    @discardableResult
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 15) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static let env: [String: String] = {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return e
    }()
}

// MARK: - Montowania (bez dotykania systemu plików, więc nie zawiesza się na martwym NFS)

enum Mounts {
    static func mountedPaths() -> Set<String> {
        var ptr: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&ptr, MNT_NOWAIT)
        guard n > 0, let base = ptr else { return [] }
        var out = Set<String>()
        for i in 0..<Int(n) {
            var entry = base[i]
            let path = withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            out.insert(path)
        }
        return out
    }

    static func isMounted(_ path: String) -> Bool {
        let resolved = Paths.real(path)
        let m = mountedPaths()
        return m.contains(path) || m.contains(resolved)
    }

    static func forceUnmount(_ path: String) {
        let r = Proc.run("/sbin/umount", ["-f", path], timeout: 10)
        if r.code != 0 && isMounted(path) {
            Proc.run("/usr/sbin/diskutil", ["unmount", "force", path], timeout: 15)
        }
    }
}
