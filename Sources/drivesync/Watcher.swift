import Foundation
import CoreServices

/// Cienka nakładka na FSEvents (zdarzenia na poziomie plików, z odtwarzaniem historii od ID).
final class FSWatcher {
    typealias Handler = (_ path: String, _ flags: UInt32, _ id: UInt64) -> Void

    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    private let handler: Handler

    init(queue: DispatchQueue, handler: @escaping Handler) {
        self.queue = queue
        self.handler = handler
    }

    /// `since == nil` → tylko nowe zdarzenia. Inaczej odtwarza zdarzenia od podanego ID.
    func start(paths: [String], since: UInt64?) -> Bool {
        var ctx = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            // strumień trzyma silny wskaźnik na watchera: callback nigdy nie dostanie zwolnionej pamięci
            retain: { p in _ = Unmanaged<FSWatcher>.fromOpaque(p!).retain(); return p },
            release: { p in Unmanaged<FSWatcher>.fromOpaque(p!).release() },
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, eventIds in
            guard let info = info else { return }
            let w = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self)
            for i in 0..<count {
                guard let p = paths[i] as? String else { continue }
                w.handler(p, eventFlags[i], eventIds[i])
            }
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        let sinceId = since ?? UInt64(kFSEventStreamEventIdSinceNow)

        guard let s = FSEventStreamCreate(
            nil, callback, &ctx, paths as CFArray, sinceId, 2.0, flags)
        else { return false }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        return FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    static var currentEventId: UInt64 { FSEventsGetCurrentEventId() }
}
