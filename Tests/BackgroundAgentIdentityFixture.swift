import Foundation

@_silgen_name("identity_fixture_value")
private func identityFixtureValue() -> Int32

@main
private enum IdentityFixture {
    static func main() throws {
        func report() throws {
            let values: [String: Any] = [
                "running": BackgroundAgentBuildIdentity.running() ?? "",
                "embedded": BackgroundAgentBuildIdentity.executable(URL(fileURLWithPath: CommandLine.arguments[0])) ?? "",
                "value": identityFixtureValue(),
            ]
            let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
        }
        try report()
        if CommandLine.arguments.contains("--wait") {
            _ = readLine()
            try report()
        }
    }
}
