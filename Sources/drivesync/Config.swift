import Foundation

/// Gdzie co leży. Wszystko pod jednym katalogiem, żeby łatwo było to znaleźć/usunąć.
enum Paths {
    /// Respektuje $HOME (przydatne do testów w piaskownicy); inaczej katalog domowy użytkownika.
    static let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
        ?? FileManager.default.homeDirectoryForCurrentUser.path
    static let support = home + "/Library/Application Support/DriveSync"
    static let logs = home + "/Library/Logs/DriveSync"
    static let configFile = support + "/config.json"
    static let stateFile = support + "/state.json"
    static let statusFile = support + "/status.json"
    static let indexFile = support + "/index.sqlite"
    static let offloadedFile = support + "/offloaded.json"
    static let pidFile = support + "/drivesync.pid"
    static let mountDisabledFlag = support + "/mount.disabled"
    static let cacheDir = home + "/Library/Caches/DriveSync"
    static let mainLog = logs + "/drivesync.log"
    static let rcloneLog = logs + "/rclone.log"

    /// Prawdziwa ścieżka (realpath), taka jak podaje FSEvents i tablica montowań.
    /// Uwaga: `URL.resolvingSymlinksInPath()` ucina „/private” (/private/tmp → /tmp), więc się nie nadaje.
    static func real(_ p: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(p, &buf) != nil ? String(cString: buf) : p
    }

    static func expand(_ p: String) -> String {
        if p == "~" { return home }
        if p.hasPrefix("~/") { return home + String(p.dropFirst(1)) }
        return p
    }
}

struct FolderMap: Codable {
    var local: String   // np. "~/Desktop"
    var remote: String  // ścieżka względem remoteRoot na Dysku, np. "Biurko"
}

struct MountConfig: Codable {
    var enabled = true
    var path = "~/GoogleDrive"
    /// Domyślnie tylko do odczytu: nie skasujesz przypadkiem plików z Findera.
    var readOnly = true
    var volumeName = "Google Drive"
    /// Twardy limit cache'u na dysku lokalnym (masz mało wolnego miejsca).
    var cacheMaxSize = "4G"
    var cacheMinFreeSpace = "6G"
    var cacheMaxAge = "24h"
    var dirCacheTime = "1h"
    var readAhead = "128M"

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        let def = MountConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? def.enabled
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? def.path
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? def.readOnly
        volumeName = try c.decodeIfPresent(String.self, forKey: .volumeName) ?? def.volumeName
        cacheMaxSize = try c.decodeIfPresent(String.self, forKey: .cacheMaxSize) ?? def.cacheMaxSize
        cacheMinFreeSpace = try c.decodeIfPresent(String.self, forKey: .cacheMinFreeSpace) ?? def.cacheMinFreeSpace
        cacheMaxAge = try c.decodeIfPresent(String.self, forKey: .cacheMaxAge) ?? def.cacheMaxAge
        dirCacheTime = try c.decodeIfPresent(String.self, forKey: .dirCacheTime) ?? def.dirCacheTime
        readAhead = try c.decodeIfPresent(String.self, forKey: .readAhead) ?? def.readAhead
    }
    enum K: String, CodingKey {
        case enabled, path, readOnly, volumeName, cacheMaxSize, cacheMinFreeSpace, cacheMaxAge, dirCacheTime, readAhead
    }
}

struct Config: Codable {
    /// Nazwa remote'a z `rclone config` (typ: drive).
    var remote = "gdrive"
    /// Folder na Dysku, pod którym lądują kopie folderów z Maca. Nic poza nim nie jest ruszane.
    var remoteRoot = "Mac"
    var folders: [FolderMap] = [
        .init(local: "~/Desktop", remote: "Biurko"),
        .init(local: "~/Documents", remote: "Dokumenty"),
        .init(local: "~/Downloads", remote: "Pobrane"),
        .init(local: "~/Pictures", remote: "Obrazy"),
        .init(local: "~/Movies", remote: "Filmy"),
        .init(local: "~/Music", remote: "Muzyka"),
    ]
    /// Wzorce w składni filtrów rclone.
    var excludes: [String] = [
        ".DS_Store", "._*", ".localized", ".Trash/**", ".Spotlight-V100/**", ".fseventsd/**",
        "*.icloud",               // placeholdery iCloud (plik nie jest pobrany)
        "~$*", "*.tmp", "*.crdownload", "*.download/**",
        "node_modules/**", ".venv/**", "__pycache__/**",
        ".gradle/**", ".cxx/**", "build/intermediates/**", "DerivedData/**", ".build/**", "Pods/**",  // artefakty kompilacji
        "*.photoslibrary/**",     // biblioteka Zdjęć: pakiet z bazą, zmienia się bez przerwy
    ]
    /// Ile sekund ciszy w FSEvents, zanim wyślemy zmiany.
    var debounceSeconds = 20
    /// Maksymalnie tyle sekund od pierwszej zmiany do wysyłki (żeby ciągły ruch nie głodził kolejki).
    var maxWaitSeconds = 300
    /// Pełny przegląd każdego folderu jako siatka bezpieczeństwa (FSEvents mogą coś zgubić).
    var fullScanHours = 12
    var transfers = 4
    var checkers = 8
    /// np. "8M" albo "08:00,2M 23:00,off"
    var bwlimit: String? = nil
    /// Nie nadpisuj plików, które na Dysku są nowsze niż lokalne (chroni wersje edytowane gdzie indziej).
    var skipIfNewerOnDrive = true
    var mount = MountConfig()
    var rclonePath: String? = nil

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        let def = Config()
        remote = try c.decodeIfPresent(String.self, forKey: .remote) ?? def.remote
        remoteRoot = try c.decodeIfPresent(String.self, forKey: .remoteRoot) ?? def.remoteRoot
        folders = try c.decodeIfPresent([FolderMap].self, forKey: .folders) ?? def.folders
        // domyślne wykluczenia są zawsze stosowane (nowe wersje mogą dodać kolejne), plus własne z configu
        let saved = try c.decodeIfPresent([String].self, forKey: .excludes) ?? []
        excludes = def.excludes + saved.filter { !def.excludes.contains($0) }
        debounceSeconds = try c.decodeIfPresent(Int.self, forKey: .debounceSeconds) ?? def.debounceSeconds
        maxWaitSeconds = try c.decodeIfPresent(Int.self, forKey: .maxWaitSeconds) ?? def.maxWaitSeconds
        fullScanHours = try c.decodeIfPresent(Int.self, forKey: .fullScanHours) ?? def.fullScanHours
        transfers = try c.decodeIfPresent(Int.self, forKey: .transfers) ?? def.transfers
        checkers = try c.decodeIfPresent(Int.self, forKey: .checkers) ?? def.checkers
        bwlimit = try c.decodeIfPresent(String.self, forKey: .bwlimit)
        skipIfNewerOnDrive = try c.decodeIfPresent(Bool.self, forKey: .skipIfNewerOnDrive) ?? def.skipIfNewerOnDrive
        mount = try c.decodeIfPresent(MountConfig.self, forKey: .mount) ?? def.mount
        rclonePath = try c.decodeIfPresent(String.self, forKey: .rclonePath)
    }
    enum K: String, CodingKey {
        case remote, remoteRoot, folders, excludes, debounceSeconds, maxWaitSeconds, fullScanHours
        case transfers, checkers, bwlimit, skipIfNewerOnDrive, mount, rclonePath
    }

    static func load() throws -> Config {
        guard FileManager.default.fileExists(atPath: Paths.configFile) else { return Config() }
        let data = try Data(contentsOf: URL(fileURLWithPath: Paths.configFile))
        return try JSONDecoder().decode(Config.self, from: data)
    }

    func write() throws {
        try FileManager.default.createDirectory(atPath: Paths.support, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: URL(fileURLWithPath: Paths.configFile), options: .atomic)
    }

    /// Ścieżka wewnątrz Dysku. `remote` zaczynające się od "/" jest liczone od korzenia Dysku
    /// (żeby np. ~/Documents/Archiwum mogło trafiać do istniejącego folderu „Archiwum”).
    func remoteSub(for f: FolderMap) -> String {
        if f.remote.hasPrefix("/") { return String(f.remote.dropFirst()) }
        return [remoteRoot, f.remote].filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// Cel na Dysku dla folderu: "gdrive:Mac/Biurko"
    func remoteSpec(for f: FolderMap) -> String { "\(remote):" + remoteSub(for: f) }
}
