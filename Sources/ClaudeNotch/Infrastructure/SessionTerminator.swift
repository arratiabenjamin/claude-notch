// SessionTerminator.swift
// Send a graceful interrupt (SIGINT) to a Claude Code session by pid so it
// can flush its state file and unregister cleanly. Equivalent to the user
// pressing Ctrl+C in the terminal — Claude Code's signal handler catches it
// and exits via its normal teardown path.
//
// We deliberately avoid SIGTERM/SIGKILL: those skip Claude Code's cleanup
// and can leave stale entries in ~/.claude/active-sessions.json until the
// notifier's cleanup pass kicks in.
import Darwin
import Foundation
import os.log

private let log = Logger(subsystem: "com.velion.claude-notch", category: "session-terminator")

enum SessionTerminator {
    enum Failure: Error, LocalizedError {
        case invalidPid
        case noSuchProcess
        case notPermitted
        case unknown(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidPid:    return "Session has no pid recorded."
            case .noSuchProcess: return "That process is no longer running."
            case .notPermitted:  return "Not permitted to signal that process."
            case .unknown(let e): return "Could not interrupt session (errno \(e))."
            }
        }
    }

    /// Send SIGINT to `pid`. Returns success even if the process happens to be
    /// already gone — the user-visible outcome (session ends) is the same.
    @discardableResult
    static func endSession(pid: Int) -> Result<Void, Failure> {
        guard pid > 0 else {
            log.error("endSession called with invalid pid=\(pid, privacy: .public)")
            return .failure(.invalidPid)
        }
        log.info("sending SIGINT to pid=\(pid, privacy: .public)")
        let result = kill(pid_t(pid), SIGINT)
        if result == 0 { return .success(()) }
        let err = errno
        switch err {
        case ESRCH:
            log.info("pid=\(pid, privacy: .public) already gone, treating as success")
            return .success(())
        case EPERM:
            log.error("EPERM signaling pid=\(pid, privacy: .public)")
            return .failure(.notPermitted)
        default:
            log.error("kill() failed errno=\(err, privacy: .public)")
            return .failure(.unknown(err))
        }
    }
}
