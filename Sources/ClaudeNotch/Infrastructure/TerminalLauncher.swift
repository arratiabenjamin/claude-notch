// TerminalLauncher.swift
// Open Terminal.app and cd into a session's working directory. v1.1 keeps
// this deliberately simple: we always open a new tab/window. Matching an
// existing tab via lsof/AppleScript is fragile (works ~70% of the time and
// requires extra Automation prompts), so we punt that to v1.2.
import AppKit
import Foundation

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
    /// Open a fresh Terminal tab at `cwd` and bring Terminal to the front.
    /// Always creates a new tab (no fragile lsof/window-matching) — this is
    /// the boring-and-reliable path.
    @discardableResult
    static func openOrFocus(cwd: String) -> Result<Void, TerminalError> {
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
