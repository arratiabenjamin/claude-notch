// TranscriptWatcher.swift
// Tail-style live watcher over a Claude Code JSONL transcript. Replaces the
// earlier 5s poll inside ExpandedSessionView so the snippet updates as soon
// as Claude Code appends a new message.
//
// Approach:
//   - Open the file FD and attach a `DispatchSource.makeFileSystemObjectSource`
//     listening for writes/extend events. This is the cheapest way to get a
//     "file was appended" signal on macOS.
//   - On every event, re-parse the tail of the file via TranscriptParser.
//   - Keep a low-frequency safety timer in case the FD source goes silent
//     (the file was rotated, the volume disconnected, etc.) — every 5s we
//     reload the snippet anyway. Also handles "the file did not exist when
//     we started; try again later."
//
// Concurrency:
//   - The class is @MainActor so the @Published property is consumed safely
//     by SwiftUI.
//   - The dispatch source fires on a global queue; the handler hops back to
//     the main actor before mutating `snippet`.
import Foundation
import SwiftUI

@MainActor
final class TranscriptWatcher: ObservableObject {

    @Published var snippet: TranscriptParser.SnippetState = .loading

    private var fileSource: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var currentPath: String?

    /// Safety reload timer — handles cases where the FS event source went
    /// silent (rotation, sleep/wake) or the file didn't exist on `start`.
    private var safetyTimer: DispatchSourceTimer?
    private static let safetyInterval: TimeInterval = 5.0

    // No deinit teardown: callers are required to invoke `stop()` from
    // SwiftUI's `onDisappear`. Doing FD/dispatch teardown in a @MainActor
    // class' deinit hits Swift 6 strict concurrency checks because deinit
    // may run off the main actor.

    // MARK: - Lifecycle

    /// Begin watching `path`. If a previous watch is in flight, it is torn
    /// down first. An empty path stops the watcher and shows `.fileMissing`.
    func start(path: String) async {
        // Same path — nothing to do.
        if currentPath == path, fileSource != nil {
            return
        }

        stop()

        guard !path.isEmpty else {
            snippet = .fileMissing
            return
        }

        currentPath = path

        // Initial read so the UI lights up immediately.
        snippet = await TranscriptParser.lastAssistantText(at: path)

        attachSource(path: path)
        scheduleSafetyTimer()
    }

    func stop() {
        if let src = fileSource {
            src.cancel()
        }
        fileSource = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        safetyTimer?.cancel()
        safetyTimer = nil
        currentPath = nil
    }

    // MARK: - Internals

    private func attachSource(path: String) {
        // O_EVTONLY = "I just want events, not the data" — does not block
        // unlinks on the producer side.
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist (yet). The safety timer will retry.
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            // Capture the path snapshot off the main actor; the actual reload
            // hops back onto the main actor.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let data = source.data
                if data.contains(.delete) || data.contains(.rename) || data.contains(.revoke) {
                    // File rotated or removed — drop the FD and let the safety
                    // timer reattach when (if) the file reappears.
                    self.detachSource()
                    return
                }
                await self.reload()
            }
        }

        source.setCancelHandler { [weak self] in
            // Closing the FD is owned by `stop` / `detachSource`; nothing
            // extra to do here, but this hook keeps the dispatch source happy.
            _ = self
        }

        fileSource = source
        source.resume()
    }

    private func detachSource() {
        if let src = fileSource {
            src.cancel()
        }
        fileSource = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private func scheduleSafetyTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(
            deadline: .now() + Self.safetyInterval,
            repeating: Self.safetyInterval
        )
        timer.setEventHandler { [weak self] in
            guard let self, let path = self.currentPath else { return }
            // Re-attach if we lost the FD.
            if self.fileSource == nil {
                self.attachSource(path: path)
            }
            Task { @MainActor [weak self] in
                await self?.reload()
            }
        }
        safetyTimer = timer
        timer.resume()
    }

    private func reload() async {
        guard let path = currentPath else { return }
        let next = await TranscriptParser.lastAssistantText(at: path)
        // Only publish if the path is still the one we care about — async
        // callers may have raced a `stop` in between.
        if currentPath == path {
            snippet = next
        }
    }
}
