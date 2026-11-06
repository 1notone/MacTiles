import CoreServices
import Foundation

/// Calls back on the main thread when anything inside the given folders changes
/// (an app is copied in, updated, renamed or moved to the Trash).
/// Uses FSEvents, so it costs nothing while the folders are quiet.
@MainActor
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void

    init?(paths: [String], latency: TimeInterval = 0.5, onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let paths = (cfPaths as? [String]) ?? []
            // The stream is scheduled on the main queue.
            MainActor.assumeIsolated { watcher.onChange(Array(paths.prefix(count))) }
        }

        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagWatchRoot      // also notice ~/Applications being created
                           | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                               paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency, flags) else {
            NSLog("MacTiles: couldn't watch \(paths) for new apps")
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // The watcher lives as long as the app; stop() releases the stream if it's ever torn down early.
}
