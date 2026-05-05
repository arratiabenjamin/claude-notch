// TerminalLauncher.swift
// Bring the user back to the terminal where their Claude Code session lives.
//
// Strategy (in order):
//   1. Walk the parent-process chain from the session's pid until we find a
//      known terminal emulator (Terminal, Ghostty, iTerm2, Warp, WezTerm,
//      kitty, alacritty, Hyper, Tabby). Activate that NSRunningApplication
//      so the user lands on the exact window/tab where their session is.
//   2. If `activate()` returns false (macOS 14+ may refuse cross-app focus
//      stealing under some conditions), try NSWorkspace.shared.openApplication
//      against the bundle URL as a stronger nudge.
//   3. If we can't identify a terminal in the tree (or no pid), fall back to
//      AppleScript on Terminal.app + cd into cwd (the v1.1 behavior).
//
// We deliberately do NOT try to focus a specific tab inside the terminal.
// That requires per-app AppleScript dialects (only Terminal/iTerm2 expose
// good APIs) and triggers extra Automation prompts. Activating the app is
// enough — the user's session is already visible inside it.
import AppKit
import Foundation
import os.log

private let log = Logger(subsystem: "com.velion.claude-notch", category: "terminal-launcher")

enum TerminalError: Error, LocalizedError {
    case applescriptFailed(String)
    case automationDenied
    case terminalNotInstalled

    var errorDescription: String? {
        switch self {
        case .applescriptFailed(let msg):
            return "Terminal AppleScript failed: \(msg)"
        case .automationDenied:
            return "Automation permission denied. Grant Claude Notch access to Terminal in System Settings → Privacy & Security → Automation."
        case .terminalNotInstalled:
            return "Terminal.app not found at /System/Applications/Utilities/Terminal.app."
        }
    }
}

@MainActor
enum TerminalLauncher {
    /// Bundle IDs we recognize as terminal emulators. Order doesn't matter for
    /// matching, but it does for the manual fallback paths below.
    private static let knownTerminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "co.zeit.hyper",
        "org.tabby"
    ]

    /// Process names (as reported by `ps`) we recognize as terminal emulators.
    /// `comm` reports the executable name only, e.g. "Ghostty", "Terminal",
    /// "iTerm2", "WezTerm", "kitty", "alacritty".
    private static let knownTerminalProcessNames: Set<String> = [
        "Terminal", "Ghostty", "iTerm2", "Warp", "WezTerm",
        "kitty", "alacritty", "Hyper", "Tabby"
    ]

    /// Best-effort: bring the terminal hosting `session.pid` to the front. If
    /// `pid` is nil or we can't identify a terminal in the tree, fall back to
    /// opening Terminal.app at `cwd`.
    @discardableResult
    static func openOrFocus(cwd: String, pid: Int? = nil) -> Result<Void, TerminalError> {
        log.info("openOrFocus called pid=\(pid ?? -1, privacy: .public) cwd=\(cwd, privacy: .public)")
        if let pid, let app = findHostingTerminal(forPid: pid) {
            log.info("found hosting terminal: \(app.bundleIdentifier ?? "?", privacy: .public) name=\(app.localizedName ?? "?", privacy: .public)")
            activate(app: app)
            return .success(())
        }
        log.info("no hosting terminal in process tree, falling back to Terminal.app")
        return openInTerminalAppFallback(cwd: cwd)
    }

    /// Bring `app` to the front using the right API for the deployment target.
    /// On macOS 14+ `activate(options:)` is deprecated; the documented
    /// replacement is parameter-less `activate()`. macOS 26 (Tahoe) seems to
    /// silently no-op the deprecated form for non-frontmost apps in some
    /// cases — using the modern API restores reliable focus stealing.
    /// If the activate call still reports false, kick the bundle URL through
    /// NSWorkspace.openApplication as a stronger nudge.
    private static func activate(app: NSRunningApplication) {
        let activated: Bool
        if #available(macOS 14.0, *) {
            activated = app.activate()
        } else {
            activated = app.activate(options: [.activateIgnoringOtherApps])
        }
        log.info("activate returned \(activated, privacy: .public)")
        if !activated, let url = app.bundleURL {
            log.info("retrying via NSWorkspace.openApplication on \(url.path, privacy: .public)")
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
                if let err {
                    log.error("openApplication failed: \(err.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Process-tree discovery

    /// Walk parent-process chain from `pid`. Return the first ancestor that
    /// is currently a running, regular application AND whose bundle ID or
    /// executable name matches a known terminal.
    private static func findHostingTerminal(forPid pid: Int) -> NSRunningApplication? {
        var current = pid
        // Hard cap walk depth — process tables don't go this deep, but a
        // pathological cycle should never lock us.
        for _ in 0..<32 {
            guard let parent = parentPid(of: current), parent > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: pid_t(parent)) {
                if let bundleID = app.bundleIdentifier,
                   knownTerminalBundleIDs.contains(bundleID) {
                    return app
                }
                if let name = app.localizedName,
                   knownTerminalProcessNames.contains(name) {
                    return app
                }
            }
            current = parent
        }
        return nil
    }

    /// Read parent PID via `ps -o ppid= -p <pid>`. Returns nil on any error.
    /// Synchronous and fast — `ps` returns in well under a millisecond per call.
    private static func parentPid(of pid: Int) -> Int? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "ppid=", "-p", "\(pid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed)
    }

    // MARK: - Fallback (Terminal.app + AppleScript)

    private static func openInTerminalAppFallback(cwd: String) -> Result<Void, TerminalError> {
        guard FileManager.default.fileExists(atPath: terminalAppPath) else {
            return .failure(.terminalNotInstalled)
        }

        // AppleScript-escape the path: backslashes first, then double quotes.
        // Wrapping in `quoted form of` inside the script then handles shell
        // quoting for the cd command itself.
        let escaped = cwd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let source = """
        tell application "Terminal"
            activate
            do script "cd " & quoted form of "\(escaped)"
        end tell
        """

        guard let script = NSAppleScript(source: source) else {
            return .failure(.applescriptFailed("could not compile AppleScript"))
        }

        var errInfo: NSDictionary?
        _ = script.executeAndReturnError(&errInfo)
        if let errInfo {
            // -1743 = errAEEventNotPermitted (Automation denied)
            // -600  = procNotFound (Terminal not running and could not launch)
            let code = (errInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            let msg = (errInfo[NSAppleScript.errorMessage] as? String) ?? "unknown"
            if code == -1743 {
                return .failure(.automationDenied)
            }
            return .failure(.applescriptFailed("\(msg) (code \(code))"))
        }
        return .success(())
    }

    private static let terminalAppPath = "/System/Applications/Utilities/Terminal.app"
}
