// DirectoryWatcher.swift
// FSEvents-based watcher that emits a *signal* (not file content) whenever
// anything changes inside `directory`. Used for `~/.claude/sessions/` so that
// `/rename <name>` updates show up in the notch immediately instead of waiting
// for the next active-sessions.json tick.
//
// Concurrency contract mirrors StateFileWatcher: `@unchecked Sendable` so the
// FSEvents C callback can re-enter; the callback hops to main before mutating
// any state. Public surface is intended to be used from the main actor.
import Foundation
import CoreServices
import Combine

final class DirectoryWatcher: @unchecked Sendable {
    private let dirPath: String

    private var stream: FSEventStreamRef?
    private var pollingTimer: DispatchSourceTimer?

    private let subject = PassthroughSubject<Void, Never>()

    /// Cadence of the safety poll (FSEvents occasionally goes silent across
    /// sleep/wake or on weird container filesystems).
    private let safetyPollInterval: TimeInterval = 5.0

    /// Combine output: every emission means "something changed in the dir,
    /// re-read whatever you care about."
    var publisher: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    init(directory: String) {
        self.dirPath = (directory as NSString).expandingTildeInPath
    }

    deinit {
        stopInternal()
    }

    // MARK: - Lifecycle

    /// Idempotent. Safe to call from the main actor.
    func start() {
        stopInternal()

        // Emit one initial "go re-read" signal so consumers refresh on launch
        // even before the first FSEvent.
        subject.send(())

        startFSEventsStream()
        startSafetyPoll()
    }

    func stop() {
        stopInternal()
    }

    // MARK: - FSEvents

    private func startFSEventsStream() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [dirPath] as CFArray
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot
        )

        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            DirectoryWatcher.callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05, // 50ms debounce — same as StateFileWatcher
            flags
        )

        guard let stream else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    private static let callback: FSEventStreamCallback = { _, contextInfo, _, _, _, _ in
        guard let contextInfo else { return }
        let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(contextInfo).takeUnretainedValue()
        watcher.handleFSEventCallback()
    }

    private func handleFSEventCallback() {
        DispatchQueue.main.async { [weak self] in
            self?.subject.send(())
        }
    }

    // MARK: - Safety polling

    private func startSafetyPoll() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(
            deadline: .now() + safetyPollInterval,
            repeating: safetyPollInterval
        )
        timer.setEventHandler { [weak self] in
            self?.subject.send(())
        }
        pollingTimer = timer
        timer.resume()
    }

    private func stopInternal() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        pollingTimer?.cancel()
        pollingTimer = nil
    }
}
