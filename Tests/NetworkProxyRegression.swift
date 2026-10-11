import Foundation

// Localization is irrelevant to this isolated transport regression.
func t(_ key: String) -> String { key }

@main
struct NetworkProxyRegression {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let proxyPort = environment["WAIFUX_PROXY_TEST_PORT"],
              let originPort = environment["WAIFUX_PROXY_TEST_ORIGIN_PORT"] else {
            throw CocoaError(.coderValueNotFound)
        }
        let preferences = WaifuXPreferences.shared
        preferences.set(true, forKey: "proxy_enabled")
        preferences.set("127.0.0.1", forKey: "proxy_host")
        preferences.set(proxyPort, forKey: "proxy_port")
        preferences.synchronize()

        let retry = RetryConfiguration(maxRetries: 0, initialDelay: 0, maxDelay: 0,
                                       delayMultiplier: 1, allowRetryOnCellular: true)
        let service = NetworkService.shared
        let proxyURL = URL(string: "http://waifux-proxy-regression.invalid/initial")!
        let initial = try await service.fetchData(from: proxyURL, retryConfig: retry)
        precondition(String(decoding: initial, as: UTF8.self) == "proxy")
        print("PASS NetworkService initialization restores durable Helper proxy preferences")
        let initialGeneration = await service.proxySessionGeneration
        for _ in 0..<10 {
            await service.updateProxyConfiguration(enabled: true, host: "127.0.0.1", port: proxyPort)
        }
        let sameGeneration = await service.proxySessionGeneration
        precondition(sameGeneration == initialGeneration)
        print("PASS repeated equivalent proxy settings retain the existing URLSession")

        let slow = Task {
            try await service.fetchData(from: URL(string: "http://waifux-proxy-regression.invalid/slow")!, retryConfig: retry)
        }
        let originBase = "http://127.0.0.1:\(originPort)"
        var started = false
        for _ in 0..<100 {
            let data = try await service.fetchData(from: URL(string: originBase + "/started")!,
                                                   retryConfig: retry, bypassSystemProxy: true)
            if String(decoding: data, as: UTF8.self) == "1" { started = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(started)
        await service.updateProxyConfiguration(enabled: false, host: "", port: "")
        let changedGeneration = await service.proxySessionGeneration
        precondition(changedGeneration == initialGeneration + 1)
        let direct = try await service.fetchData(from: URL(string: originBase + "/origin")!, retryConfig: retry)
        precondition(String(decoding: direct, as: UTF8.self) == "origin")
        print("PASS disabling custom proxy routes future requests to the local origin")
        _ = try await service.fetchData(from: URL(string: originBase + "/release")!, retryConfig: retry)
        let completed = try await slow.value
        precondition(String(decoding: completed, as: UTF8.self) == "slow-proxy")
        print("PASS proxy replacement lets an already active request finish on its original session")

        await service.updateProxyConfiguration(enabled: false, host: "ignored", port: "12345")
        let disabledGeneration = await service.proxySessionGeneration
        precondition(disabledGeneration == changedGeneration)
        print("PASS disabled proxy field edits do not allocate another session")
    }
}
