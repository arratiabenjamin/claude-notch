// StateFileWatcher.swift
// FSEvents-based watcher on the directory containing active-sessions.json.
// We watch the PARENT directory (not the file fd) because the producer writes
// atomically (write-temp + rename), which kills any kqueue/dispatch source
// pinned to a specific inode.
//
// Concurrency contract (Swift 6 strict):
//   - This class is `@unchecked Sendable` because FSEvents takes a C function
//     pointer for its callback. The callback re-enters our instance via an
//     unmanaged opaque pointer.
//   - The C callback hops to the main queue immediately; we never mutate state
//     from the FSEvents queue.
//   - Public API (`start`, `stop`, `publisher`) is intended to be called from
//     the main actor by AppController.
import Foundation
import CoreServices
import Combine

final class StateFileWatcher: @unchecked Sendable {
    /// Absolute path to the directory containing active-sessions.json
    /// (typically `~/.claude/`).
    private let dirPath: String
    /// Filename inside `dirPath` we ultimately want to read.
    private let filename: String

    private var stream: FSEventStreamRef?
    private var pollingTimer: DispatchSourceTimer?
    private var lastEventAt: Date = .distantPast

    private let subject = PassthroughSubject<DataOrError, Never>()

    /// Polling cadence as a safety net if FSEvents goes silent (sleep/wake,
    /// container fs quirks, etc).
    private let safetyPollInterval: TimeInterval = 2.0

    /// Combine output: every emission is one (data?, error?) snapshot.
    var publisher: AnyPublisher<DataOrError, Never> { subject.eraseToAnyPublisher() }

    init(directory: String, filename: String = "active-sessions.json") {
        self.dirPath = (directory as NSString).expandingTildeInPath
        self.filename = filename
    }

    deinit {
        stopInternal()
    }

    // MARK: - Lifecycle

    /// Idempotent. Starts the FSEvents stream and the safety poll.
    func start() {
        stopInternal()

        // Emit one initial snapshot so the UI is not stuck in `.loading`
        // even if FSEvents takes a beat to fire its first callback.
        emitCurrent()

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
            StateFileWatcher.callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05, // latency in seconds — 50ms debounce per autoplan plan
            flags
        )

        guard let stream else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    private static let callback: FSEventStreamCallback = { _, contextInfo, _, _, _, _ in
        guard let contextInfo else { return }
        let watcher = Unmanaged<StateFileWatcher>.fromOpaque(contextInfo).takeUnretainedValue()
        watcher.handleFSEventCallback()
    }

    private func handleFSEventCallback() {
        lastEventAt = Date()
        // Hop off the FSEvents queue onto main before mutating any state.
        DispatchQueue.main.async { [weak self] in
            self?.emitCurrent()
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
            guard let self else { return }
            // Always re-read on the safety tick; the SessionStore upstream is
            // already idempotent on identical data.
            self.emitCurrent()
        }
        pollingTimer = timer
        timer.resume()
    }

    // MARK: - Read + publish

    private func emitCurrent() {
        let url = URL(fileURLWithPath: dirPath).appendingPathComponent(filename)
        let fm = FileManager.default

        // Distinguish file-missing from dir-missing for nicer UI feedback.
        if !fm.fileExists(atPath: dirPath) {
            subject.send(.error(WatcherError.dirMissing))
            return
        }
        if !fm.fileExists(atPath: url.path) {
            subject.send(.data(nil))
            return
        }

        do {
            let data = try Data(contentsOf: url, options: [.uncached])
            subject.send(.data(data))
        } catch {
            subject.send(.error(error))
        }
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

extension StateFileWatcher {
    /// Output of the watcher; one of these per emission.
    enum DataOrError {
        case data(Data?)   // nil = file does not exist
        case error(Error)
    }

    enum WatcherError: Error {
        case dirMissing
    }
}
