import Foundation

enum AppConfiguration {
    static let appID = "agentx"
    static let protocolVersion = 5
    static var rpcPort: UInt16 {
        guard let url = Bundle.main.url(forResource: "AgentXConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let value = config["RPCPort"] as? Int, (1024...65535).contains(value), value != 45678 else {
            preconditionFailure("AgentX requires its independent RPC port configuration")
        }
        return UInt16(value)
    }
}
