// SaverSessionPoller.swift
// Periodic reader for ~/.claude/active-sessions.json, used inside the screen
// saver bundle.
//
// We deliberately do NOT use FSEventStream here — the legacyScreenSaver host
// process that loads .saver bundles has a different lifecycle (start/stop on
// every wake/idle cycle) and the cost of a stream setup vs. a 2.5s file read
// is not worth it. Polling is appropriate at human-perceptible cadence:
// session changes during a screen saver are rare, and a 2.5s lag is invisible.
import Foundation
import os.log

private let log = Logger(subsystem: "com.velion.claude-notch.saver", category: "poller")

@MainActor
final class SaverSessionPoller: ObservableObject {
    @Published private(set) var sessions: [SessionState] = []

    private var timer: Timer?

    /// Mirror file written by the main app's SessionStore on every state
    /// change. We can't read ~/.claude/active-sessions.json directly from the
    /// legacyScreenSaver sandbox, so we go through /tmp which IS accessible.
    /// If the main app isn't running, this file is stale or absent and the
    /// saver shows zero satellites — acceptable degradation.
    private static let stateFilePath: String = "/tmp/com.velion.claude-notch.sessions.json"

    /// Begin polling. Safe to call multiple times — re-entrant: an existing
    /// timer is invalidated and replaced.
    func start() {
        stop()
        load()
        let t = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
        // Common run loop mode so the timer keeps firing while the saver
        // is interacting with the run loop normally.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func load() {
        let url = URL(fileURLWithPath: Self.stateFilePath)
        let exists = FileManager.default.fileExists(atPath: Self.stateFilePath)
        log.info("load() path=\(Self.stateFilePath, privacy: .public) exists=\(exists, privacy: .public)")
        guard let data = try? Data(contentsOf: url) else {
            log.error("load() failed to read data from \(Self.stateFilePath, privacy: .public)")
            if !sessions.isEmpty { sessions = [] }
            return
        }
        log.info("load() read \(data.count, privacy: .public) bytes")
        do {
            let decoded = try JSONLoader.decode(from: data)
            log.info("load() decoded \(decoded.count, privacy: .public) sessions")
            // Stable order so satellites don't visually jitter between reads.
            sessions = decoded.sorted { $0.id < $1.id }
        } catch {
            log.error("load() decode error: \(String(describing: error), privacy: .public)")
            // Malformed mid-write — keep the previous list rather than blink.
        }
    }
}
