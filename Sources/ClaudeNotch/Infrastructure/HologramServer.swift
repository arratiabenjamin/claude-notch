// HologramServer.swift
// Tiny HTTP/1.1 server that serves the Pepper's ghost pyramid page and a
// Server-Sent Events stream of live state updates. Runs on the user's LAN
// (or iPhone hotspot) so any browser device — phone laid under an acrylic
// pyramid, Raspberry Pi kiosk, etc. — can render the holographic projection
// of the orb without USB tethering or app-side helpers.
//
// Endpoints:
//   GET /            → hologram.html bundled in the app, fullscreen-friendly.
//   GET /state       → text/event-stream. Pushes JSON state on every change.
//   GET /health      → 200 OK plain. Used by the Settings UI to verify the
//                       port is reachable from the local network.
//
// Implementation choice: pure Network.framework (NWListener) so we stay
// dependency-free. No SwiftNIO, no Vapor — the surface area is small enough
// that a hundred lines of socket plumbing is cleaner than a framework dep.
//
// Concurrency: @MainActor because the listener and connection collections
// are mutated alongside SwiftUI state. NWListener's queue is also main —
// requests are tiny, so this is fine for a local-only debug server.
import Foundation
import Network
import os.log

private let log = Logger(subsystem: "com.velion.claude-notch", category: "hologram-server")

@MainActor
final class HologramServer: ObservableObject {
    /// Port chosen high enough to avoid clashes with anything common.
    static let port: UInt16 = 8765

    /// Whether the listener is up and reachable.
    @Published private(set) var isRunning: Bool = false
    /// Public URL the user should point their phone at, e.g.
    /// `http://192.168.1.42:8765`. Nil while stopped or while we couldn't
    /// resolve a non-loopback IPv4 (rare — happens with WiFi off + no
    /// Ethernet).
    @Published private(set) var url: String?
    /// Number of clients currently subscribed to the SSE state stream.
    /// Surfaces in Settings so the user knows whether a browser is
    /// actually receiving updates.
    @Published private(set) var clientCount: Int = 0

    private var listener: NWListener?
    /// All open connections, keyed by ObjectIdentifier so we can erase on
    /// close. SSE clients stay in here for the lifetime of their stream;
    /// regular GET handlers drop themselves once the response is flushed.
    private var sseClients: [ObjectIdentifier: NWConnection] = [:]
    /// Latest state we pushed. Replayed verbatim to any newcomer so a
    /// browser that connects mid-cycle doesn't render a stale default.
    private var lastState: HologramState = .empty

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.includePeerToPeer = false
            let port = NWEndpoint.Port(rawValue: Self.port)!
            let listener = try NWListener(using: params, on: port)
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handleListenerState(state) }
            }
            listener.start(queue: .main)
            self.listener = listener
            self.url = computeURL()
            log.info("HologramServer started on port \(Self.port, privacy: .public) url=\(self.url ?? "?", privacy: .public)")
        } catch {
            log.error("HologramServer failed to start: \(String(describing: error), privacy: .public)")
            isRunning = false
            url = nil
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for conn in sseClients.values { conn.cancel() }
        sseClients.removeAll()
        clientCount = 0
        isRunning = false
        url = nil
        log.info("HologramServer stopped")
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
        case .failed(let err):
            log.error("Listener failed: \(String(describing: err), privacy: .public)")
            isRunning = false
            stop()
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    // MARK: - State broadcast

    /// Push a new state to all active SSE clients. Idempotent: if the state
    /// is byte-identical to the last one we sent, this is a no-op.
    func push(_ state: HologramState) {
        guard state != lastState else { return }
        lastState = state
        let frame = sseFrame(event: "state", data: state.jsonString())
        let data = frame.data(using: .utf8) ?? Data()
        for (id, conn) in sseClients {
            send(conn, data: data, closeAfter: false) { [weak self] error in
                if error != nil { Task { @MainActor in self?.dropClient(id) } }
            }
        }
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receiveRequest(conn, accumulated: Data())
    }

    /// Read until we have the full request headers, then dispatch.
    private func receiveRequest(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if let chunk, !chunk.isEmpty {
                let buffer = accumulated + chunk
                if let headerEnd = buffer.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) {
                    let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
                    Task { @MainActor in
                        self.dispatch(headerData: headerData, on: conn)
                    }
                } else if buffer.count < 65_536 {
                    Task { @MainActor in
                        self.receiveRequest(conn, accumulated: buffer)
                    }
                } else {
                    conn.cancel()
                }
            } else if isComplete || error != nil {
                conn.cancel()
            }
        }
    }

    private func dispatch(headerData: Data, on conn: NWConnection) {
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            respondNotFound(conn)
            return
        }
        let firstLine = headerString.split(separator: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            respondNotFound(conn)
            return
        }
        let path = String(parts[1].split(separator: "?").first ?? "")

        switch path {
        case "/", "/index.html":
            servePage(conn)
        case "/state":
            startSSE(conn)
        case "/health":
            respond(conn, status: "200 OK", contentType: "text/plain", body: "ok")
        default:
            respondNotFound(conn)
        }
    }

    // MARK: - Handlers

    private func servePage(_ conn: NWConnection) {
        guard let url = Bundle.main.url(forResource: "hologram", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            respond(conn, status: "500 Internal Server Error",
                    contentType: "text/plain",
                    body: "hologram.html missing from bundle")
            return
        }
        respond(conn, status: "200 OK",
                contentType: "text/html; charset=utf-8",
                body: html,
                extraHeaders: ["Cache-Control": "no-cache"])
    }

    private func startSSE(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        sseClients[id] = conn
        clientCount = sseClients.count

        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "Connection: keep-alive",
            "X-Accel-Buffering: no",
            "Access-Control-Allow-Origin: *",
            ""
        ].joined(separator: "\r\n") + "\r\n"

        let initial = sseFrame(event: "state", data: lastState.jsonString())
        let payload = (headers + initial).data(using: .utf8) ?? Data()

        send(conn, data: payload, closeAfter: false) { [weak self] error in
            if error != nil { Task { @MainActor in self?.dropClient(id) } }
        }

        // Hook up cancellation on the connection so we evict the slot when
        // the browser closes the tab.
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.dropClient(id) }
            default:
                break
            }
        }
    }

    private func dropClient(_ id: ObjectIdentifier) {
        if let conn = sseClients.removeValue(forKey: id) {
            conn.cancel()
        }
        clientCount = sseClients.count
    }

    // MARK: - HTTP response helpers

    private func respond(_ conn: NWConnection,
                         status: String,
                         contentType: String,
                         body: String,
                         extraHeaders: [String: String] = [:]) {
        let bodyData = body.data(using: .utf8) ?? Data()
        var headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "Access-Control-Allow-Origin: *"
        ]
        for (k, v) in extraHeaders {
            headers.append("\(k): \(v)")
        }
        let head = headers.joined(separator: "\r\n") + "\r\n\r\n"
        var payload = head.data(using: .utf8) ?? Data()
        payload.append(bodyData)
        send(conn, data: payload, closeAfter: true)
    }

    private func respondNotFound(_ conn: NWConnection) {
        respond(conn, status: "404 Not Found",
                contentType: "text/plain", body: "not found")
    }

    private func send(_ conn: NWConnection,
                      data: Data,
                      closeAfter: Bool,
                      completion: ((NWError?) -> Void)? = nil) {
        conn.send(content: data, completion: .contentProcessed { error in
            completion?(error)
            if closeAfter { conn.cancel() }
        })
    }

    private func sseFrame(event: String, data: String) -> String {
        var frame = "event: \(event)\n"
        // SSE spec: each line of `data` becomes a separate `data:` field.
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
            frame += "data: \(line)\n"
        }
        frame += "\n"
        return frame
    }

    // MARK: - Network discovery

    /// Best-effort LAN IPv4 of an active interface. Tries Wi-Fi and
    /// Ethernet first, falls back to bridge interfaces (which is what
    /// the iPhone hotspot uses on macOS). Skips loopback and APIPA.
    private func computeURL() -> String? {
        guard let ip = Self.lanIPv4() else {
            log.warning("Could not resolve any LAN IPv4 — server reachable only at localhost")
            return "http://localhost:\(Self.port)"
        }
        return "http://\(ip):\(Self.port)"
    }

    static func lanIPv4() -> String? {
        var addresses: [(name: String, ip: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            // en* = Wi-Fi / Ethernet / Thunderbolt.
            // bridge* = iPhone Hotspot bridge created by macOS.
            // utun* = VPN tunnel — skip, not LAN-routable.
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            var addr = interface.ifa_addr.pointee
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(&addr,
                                 socklen_t(interface.ifa_addr.pointee.sa_len),
                                 &hostname, socklen_t(hostname.count),
                                 nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }
            let ip = String(cString: hostname)
            // Skip loopback and link-local APIPA.
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") { continue }
            addresses.append((name, ip))
        }

        // Prefer Wi-Fi/Ethernet (en*) over bridge — the iPhone hotspot
        // bridge IP is reachable from the phone but harder to verify.
        if let primary = addresses.first(where: { $0.name.hasPrefix("en") }) {
            return primary.ip
        }
        return addresses.first?.ip
    }
}

/// What we push to clients. Mirrors VelionHologram's mode space + a few
/// extra counters the page uses for the bottom-right HUD readout.
struct HologramState: Equatable, Encodable, Sendable {
    enum Mode: String, Encodable, Sendable {
        case idle
        case thinking
        case speaking
    }
    var mode: Mode
    var amplitude: Double  // 0..1, only meaningful in .speaking
    var runningCount: Int
    var idleCount: Int

    static let empty = HologramState(mode: .idle, amplitude: 0, runningCount: 0, idleCount: 0)

    func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        guard let data = try? encoder.encode(self),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }
}
