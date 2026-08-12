import Foundation
import Network

/// Milestone 2 only. A loopback WebSocket server that Tailscale Serve fronts
/// with trusted TLS, so the phone can reach the Mac without the relay hop.
///
/// Binds ONLY to 127.0.0.1. It is never exposed on the LAN or on a Tailscale
/// interface directly — `tailscale serve` terminates TLS and proxies here, so
/// the Swift app never handles a certificate.
///
///     tailscale serve --bg --https=443 http://127.0.0.1:8787
///
/// Boundary: loopback binding + exact Origin check + an independent
/// DIRECT_TOKEN. Origin alone is not a security control (a non-browser client
/// can forge it) — it is defence in depth alongside the token.
final class DirectWebSocketServer: @unchecked Sendable {

    private let port: NWEndpoint.Port
    private let processor: ActionProcessor
    private let tokenProvider: @Sendable () -> String?
    private let allowedOriginProvider: @Sendable () -> String?
    private let stateProvider: @Sendable () -> (remoteEnabled: Bool, permission: PermissionState)

    private var listener: NWListener?
    private var current: NWConnection?
    private var authenticated = false
    private let queue = DispatchQueue(label: "com.clickbridge.direct")

    private(set) var isRunning = false
    var onStateChange: (@Sendable (Bool) -> Void)?

    init(
        port: UInt16 = Constants.directListenerPort,
        processor: ActionProcessor,
        tokenProvider: @escaping @Sendable () -> String?,
        allowedOriginProvider: @escaping @Sendable () -> String?,
        stateProvider: @escaping @Sendable () -> (remoteEnabled: Bool, permission: PermissionState)
    ) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.processor = processor
        self.tokenProvider = tokenProvider
        self.allowedOriginProvider = allowedOriginProvider
        self.stateProvider = stateProvider
    }

    // MARK: - Lifecycle

    func start() throws {
        guard listener == nil else { return }

        let websocket = NWProtocolWebSocket.Options(.version13)
        websocket.maximumMessageSize = Constants.maxMessageBytes
        websocket.autoReplyPing = true

        // Installed BEFORE the listener is created, per Network.framework's
        // contract, so the handshake can be inspected and rejected.
        // The handler receives the client's requested subprotocols and its
        // additional headers — there is no request object to query.
        websocket.setClientRequestHandler(queue) { [weak self] _, headers in
            guard let self else { return .init(status: .reject, subprotocol: nil) }
            guard let allowed = self.allowedOriginProvider(), !allowed.isEmpty else {
                return .init(status: .reject, subprotocol: nil)
            }
            // Header names are case-insensitive on the wire.
            let origin = headers.first { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }?.value
            guard origin == allowed else {
                return .init(status: .reject, subprotocol: nil)
            }
            return .init(status: .accept, subprotocol: nil)
        }

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isRunning = true
                self.onStateChange?(true)
            case .failed, .cancelled:
                self.isRunning = false
                self.onStateChange?(false)
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        current?.cancel()
        current = nil
        authenticated = false
        isRunning = false
        onStateChange?(false)
    }

    // MARK: - Connections

    /// One direct phone at a time; a new authenticated socket replaces the old,
    /// mirroring the relay's rule.
    private func accept(_ connection: NWConnection) {
        current?.cancel()
        current = connection
        authenticated = false

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state { self.drop(connection) }
            if case .cancelled = state { self.drop(connection) }
        }
        connection.start(queue: queue)
        receive(on: connection)

        // Unauthenticated sockets do not linger.
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.current === connection, !self.authenticated else { return }
            connection.cancel()
        }
    }

    private func drop(_ connection: NWConnection) {
        guard current === connection else { return }
        current = nil
        authenticated = false
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil { return self.drop(connection) }

            if let data, !data.isEmpty,
               let metadata = context?.protocolMetadata(
                    definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .text,
               let text = String(data: data, encoding: .utf8) {
                Task { await self.handle(text, on: connection) }
            }
            self.receive(on: connection)
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(
            content: Data(text.utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    private func handle(_ text: String, on connection: NWConnection) async {
        guard let message = try? Wire.decode(text) else { return }

        if !authenticated {
            guard case .hello(let hello) = message,
                  hello.role == "phone",
                  let expected = tokenProvider(),
                  !expected.isEmpty,
                  constantTimeEquals(hello.token, expected)
            else {
                connection.cancel()
                return
            }
            authenticated = true
            if let ok = try? Wire.encode(HelloOK(role: "phone")) { send(ok, on: connection) }
            let s = stateProvider()
            if let state = try? Wire.encode(PhoneState(
                macOnline: true, remoteEnabled: s.remoteEnabled, permission: s.permission)) {
                send(state, on: connection)
            }
            return
        }

        switch message {
        case .heartbeatRequest(let req):
            if let ack = try? Wire.encode(HeartbeatAck(sequence: req.sequence)) {
                send(ack, on: connection)
            }

        case .timeSyncRequest(let req):
            let receivedAt = Date().timeIntervalSince1970 * 1000
            let response = TimeSyncResponse(
                syncId: req.syncId,
                phoneSendUnixMs: req.phoneSendUnixMs,
                macReceiveUnixMs: receivedAt,
                macSendUnixMs: Date().timeIntervalSince1970 * 1000
            )
            if let text = try? Wire.encode(response) { send(text, on: connection) }

        case .actionRequest(let request):
            // The SAME actor as the relay path. This is what makes racing the
            // two transports safe — one execution authority, not two.
            let result = await processor.receive(request, via: .tailscale)
            if let text = try? Wire.encode(result) { send(text, on: connection) }

        default:
            break
        }
    }
}

/// Length-independent comparison, so a wrong token leaks no timing signal.
func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let ab = Array(a.utf8), bb = Array(b.utf8)
    guard ab.count == bb.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
    return diff == 0
}
