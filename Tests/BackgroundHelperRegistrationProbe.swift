import AppKit
import Foundation
import ServiceManagement

private final class RegistrationReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(with: result)
    }
}

@main struct RegistrationProbe {
    @MainActor static func main() async {
        let arguments = CommandLine.arguments
        let service = SMAppService.agent(plistName: arguments[1])
        if arguments.contains("--unregister") { try? await service.unregister(); return }
        defer { try? service.unregister() }
        do {
            _ = NSApplication.shared
            let initialStatus = service.status
            print("INITIAL_SERVICE_STATUS=\(initialStatus.rawValue)")
            try BackgroundAgentRegistration.validateBundle(Bundle.main.bundleURL, plistName: arguments[1], machServiceName: arguments[2])
            try BackgroundAgentRegistration.ensureEnabled(service)
            let connection = NSXPCConnection(machServiceName: arguments[2])
            connection.remoteObjectInterface = NSXPCInterface(with: BackgroundAgentXPC.self)
            connection.resume()
            defer { connection.invalidate() }
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                let gate = RegistrationReply(continuation)
                let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable in gate.finish(.failure($0)) } as! BackgroundAgentXPC
                proxy.hello { gate.finish(.success($0 as Data)) }
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    gate.finish(.failure(CocoaError(.xpcConnectionInvalid)))
                }
            }
            let hello = try JSONDecoder().decode(BackgroundAgentHello.self, from: data)
            guard hello.bundleIdentifier == BackgroundAgentWire.bundleIdentifier, hello.protocolVersion == BackgroundAgentWire.protocolVersion else { throw CocoaError(.coderInvalidValue) }
            try BackgroundAgentRegistration.ensureEnabled(service)
            print("SIGNED_SERVICE_MANAGEMENT_REGRESSION_PASSED initialStatus=\(initialStatus.rawValue) enabled=true helper=\(hello.bundleIdentifier) runtimeReady=\(hello.runtimeReady) repeatedStartup=true")
        } catch {
            fputs("REGISTRATION_FAILED \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
