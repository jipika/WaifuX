import Foundation

@main
struct HelperProxyRegression {
    static var connection: NSXPCConnection!
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "HelperProxyRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        print("PASS \(message)")
    }
    static func rpc(_ operation: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let command = BackgroundAgentCommand(operation: operation, arguments: try BackgroundPropertyList.encode(arguments))
        let payload = try JSONEncoder().encode(command)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! BackgroundAgentXPC
            proxy.perform(payload as NSData) { continuation.resume(returning: $0 as Data) }
        }
        let reply = try JSONDecoder().decode(BackgroundAgentReply.self, from: data)
        if let error = reply.error { throw NSError(domain: "HelperProxyRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: error]) }
        return try BackgroundPropertyList.decode(reply.result ?? Data())
    }
    static func set(_ key: String, _ value: Any) async throws {
        let mutation = try BackgroundPropertyList.encode(["key": key, "value": value, "removed": false, "writerID": UUID().uuidString, "sequence": 1])
        _ = try await rpc("preferences.set", ["mutation": mutation])
    }
    static func main() async {
        do {
            let args = CommandLine.arguments
            let server = URL(string: args.last!)!
            let fixture = try Data(contentsOf: URL(fileURLWithPath: args[2]))
            connection = NSXPCConnection(machServiceName: args[1])
            connection.remoteObjectInterface = NSXPCInterface(with: BackgroundAgentXPC.self)
            connection.resume()
            _ = try await rpc("bootstrap", ["preferences": ["proxy_enabled": false]])
            try await set("proxy_host", "127.0.0.1")
            try await set("proxy_port", String(server.port!))
            try await set("proxy_enabled", true)
            let target = "http://waifux-proxy-regression/helper-via-proxy.mp4"
            let result = try await rpc("test.network.wait", ["url": target])
            try check(result["data"] as? Data == fixture, "Helper setting ACK applies a real custom HTTP proxy before the next request")
            let (statsData, _) = try await URLSession.shared.data(from: server.appendingPathComponent("stats"))
            let stats = try JSONSerialization.jsonObject(with: statsData) as! [String: Int]
            try check(stats[target] == 1, "loopback proxy receives the absolute request for an unresolved target")
            try await set("proxy_enabled", false)
            let direct = try await rpc("test.network.wait", ["url": server.appendingPathComponent("helper-direct.mp4").absoluteString])
            try check(direct["data"] as? Data == fixture, "Helper disabling custom proxy takes effect without restarting")
            _ = try await rpc("runtime.stop")
            connection.invalidate()
            print("BACKGROUND_HELPER_PROXY_REGRESSION_PASSED")
        } catch { fputs("FAIL \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
