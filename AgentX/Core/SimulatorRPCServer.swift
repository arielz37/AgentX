import Foundation
import Network

final class SimulatorRPCServer {
    static var defaultPort: UInt16 { AppConfiguration.rpcPort }

    typealias CommandHandler = (_ method: String, _ params: [String: Any]) async throws -> (result: Any, shouldStop: Bool)

    private let listener: NWListener
    private let onReady: (UInt16) -> Void
    private let onStop: () -> Void
    private let commandHandler: CommandHandler
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "com.agentx.rpc")

    init(
        onReady: @escaping (UInt16) -> Void,
        onStop: @escaping () -> Void,
        commandHandler: @escaping CommandHandler
    ) throws {
        let port = NWEndpoint.Port(rawValue: Self.defaultPort)!
        // Do not expose the RPC server on LAN interfaces. The intended access patterns are:
        // - Simulator: connect via localhost.
        // - Physical device: connect via a paired tunnel/port-forward (CoreDevice tunnel or usbmux).
        //
        // We intentionally *do not* require a specific interface type here because the CoreDevice
        // tunnel can present as Wi-Fi-backed. Instead, we reject connections in newConnectionHandler
        // unless the peer address is loopback (simulator) or an IPv6 ULA (CoreDevice tunnel).
        self.listener = try NWListener(using: .tcp, on: port)
        self.onReady = onReady
        self.onStop = onStop
        self.commandHandler = commandHandler
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port?.rawValue else { return }
                self.onReady(port)
            case .failed(let error):
                print("RPC server failed: \(error)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            guard Self.isLocalConnection(connection.endpoint) else {
                connection.cancel()
                return
            }

            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }

        listener.start(queue: queue)
    }

    func stop() {
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        listener.cancel()
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        var buffer = buffer
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                buffer.append(data)
                self.processBufferedLines(&buffer, on: connection)
            }

            if isComplete || error != nil {
                self.removeConnection(connection)
                connection.cancel()
                return
            }

            self.receive(on: connection, buffer: buffer)
        }
    }

    private func processBufferedLines(_ buffer: inout Data, on connection: NWConnection) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.isEmpty {
                continue
            }
            handleLine(line, on: connection)
        }
    }

    private func handleLine(_ line: Data, on connection: NWConnection) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let request = try RPCRequest(data: line)
                do {
                    let outcome = try await self.commandHandler(request.method, request.params)
                    let response: [String: Any] = [
                        "id": request.id,
                        "result": outcome.result
                    ]
                    self.sendResponse(response, on: connection) { [weak self] in
                        if outcome.shouldStop {
                            self?.onStop()
                        }
                    }
                } catch {
                    let response: [String: Any] = [
                        "id": request.id,
                        "error": ["message": error.localizedDescription]
                    ]
                    self.sendResponse(response, on: connection)
                }
            } catch {
                let response: [String: Any] = [
                    "id": NSNull(),
                    "error": ["message": error.localizedDescription]
                ]
                self.sendResponse(response, on: connection)
            }
        }
    }

    private func sendResponse(
        _ object: [String: Any],
        on connection: NWConnection,
        completion: (() -> Void)? = nil
    ) {
        guard JSONSerialization.isValidJSONObject(object),
              let payload = try? JSONSerialization.data(withJSONObject: object)
        else {
            completion?()
            return
        }

        var framed = payload
        framed.append(0x0A)

        connection.send(content: framed, completion: .contentProcessed { _ in
            completion?()
        })
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
    }

    private static func isLocalConnection(_ endpoint: NWEndpoint) -> Bool {
        // Defense-in-depth: only accept:
        // - loopback peers (simulator / same-host workflows)
        // - IPv6 Unique Local Addresses (CoreDevice tunnel on paired physical devices)
        guard case .hostPort(let host, _) = endpoint else { return false }

        switch host {
        case .ipv4(let addr):
            return addr == IPv4Address.loopback
        case .ipv6(let addr):
            if addr == IPv6Address.loopback {
                return true
            }
            // ULA = fc00::/7 (addresses starting with 0xfc or 0xfd)
            return addr.rawValue.first == 0xFC || addr.rawValue.first == 0xFD
        case .name(let name, _):
            return name == "localhost"
        @unknown default:
            return false
        }
    }
}

private enum RPCServerError: Swift.Error, LocalizedError {
    case invalidJSON
    case missingMethod
    case invalidMethod
    case invalidParams

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "Invalid JSON payload"
        case .missingMethod:
            "Missing 'method' field"
        case .invalidMethod:
            "Field 'method' must be a string"
        case .invalidParams:
            "Field 'params' must be an object"
        }
    }
}

private struct RPCRequest {
    let id: Any
    let method: String
    let params: [String: Any]

    init(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RPCServerError.invalidJSON
        }
        let objectParams = object["params"] as? [String: Any]
        guard let methodValue = object["method"] else {
            throw RPCServerError.missingMethod
        }
        guard let method = methodValue as? String else {
            throw RPCServerError.invalidMethod
        }
        if let params = object["params"], !(params is [String: Any]) {
            throw RPCServerError.invalidParams
        }

        self.id = object["id"] ?? NSNull()
        self.method = method
        self.params = objectParams ?? [:]
    }
}
