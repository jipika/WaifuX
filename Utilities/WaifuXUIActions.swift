import AppKit

/// Runtime services request a UI action without depending on AppDelegate.
@MainActor
enum WaifuXUIActions {
    enum Action: String, Codable, Sendable {
        case main, library, wallpaperDetail, settings, scheduler, updates, releaseMemory
    }

    /// A single request travels through both launch arguments (cold start) and
    /// the URL event (already running). Its ID prevents presenting it twice.
    struct Request: Equatable {
        static let launchArgument = "--waifux-ui-request"
        let action: Action
        let id: UUID

        init(action: Action, id: UUID = UUID()) {
            self.action = action
            self.id = id
        }

        init?(url: URL) {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.scheme == "waifux", components.host == "ui",
                  components.user == nil, components.password == nil, components.port == nil,
                  let action = Action(rawValue: String(components.path.dropFirst())),
                  action != .releaseMemory,
                  let value = components.queryItems?.first(where: { $0.name == "request" })?.value,
                  let id = UUID(uuidString: value) else { return nil }
            self.init(action: action, id: id)
        }

        var url: URL {
            URL(string: "waifux://ui/\(action.rawValue)?request=\(id.uuidString)")!
        }

        static func from(arguments: [String]) -> Request? {
            guard let index = arguments.firstIndex(of: launchArgument),
                  arguments.indices.contains(index + 1),
                  let url = URL(string: arguments[index + 1]) else { return nil }
            return Request(url: url)
        }

        func openConfiguration() -> NSWorkspace.OpenConfiguration {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false // Only the requested window activates the UI.
            configuration.arguments = [Self.launchArgument, url.absoluteString]
            return configuration
        }
    }

    struct RequestRouter {
        private var isReady = false
        private var pending: [Action] = []
        private var handledIDs: [UUID] = []

        mutating func receive(_ request: Request) -> Action? {
            guard !handledIDs.contains(request.id) else { return nil }
            handledIDs.append(request.id)
            if handledIDs.count > 64 { handledIDs.removeFirst() }
            if isReady { return request.action }
            pending.append(request.action)
            return nil
        }

        mutating func start(arguments: [String]) -> [Action] {
            guard !isReady else { return [] }
            if let request = Request.from(arguments: arguments) { _ = receive(request) }
            isReady = true
            let actions = pending.isEmpty ? [.main] : pending
            pending.removeAll()
            return actions
        }
    }

    static var handler: ((Action) -> Void)?

    static func perform(_ action: Action) {
        handler?(action)
    }
}
