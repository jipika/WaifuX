import Foundation
import Combine
import CFNetwork

/// Injectable TCP transport. Tests feed CRLF JSON without opening sockets.
@MainActor
protocol AnimeSyncPlayTransport: AnyObject {
    var onData: ((Data) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func connect(host: String, port: UInt16)
    func send(_ data: Data)
    func startTLS(host: String) throws
    func close()
}

/// CFStream supports the protocol's in-place STARTTLS upgrade, with normal system certificate validation.
@MainActor
final class AnimeSyncPlayStreamTransport: NSObject, AnimeSyncPlayTransport, StreamDelegate {
    var onData: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    private var input: InputStream?
    private var output: OutputStream?
    private var pending = Data()
    private var closed = true

    func connect(host: String, port: UInt16) {
        close()
        closed = false
        var read: InputStream?
        var write: OutputStream?
        Stream.getStreamsToHost(withName: host, port: Int(port), inputStream: &read, outputStream: &write)
        guard let read, let write else { fail(t("无法创建 TCP 连接。")); return }
        input = read; output = write
        for stream in [read as Stream, write as Stream] {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .common)
            stream.open()
        }
    }
    func send(_ data: Data) {
        guard !closed else { return }
        guard pending.count + data.count <= 262_144 else { fail(t("发送队列已满。")); return }
        pending.append(data); flush()
    }
    private func flush() {
        guard !closed, let output, output.hasSpaceAvailable, !pending.isEmpty else { return }
        while !closed && output.hasSpaceAvailable && !pending.isEmpty {
            let written = pending.withUnsafeBytes { buffer -> Int in
                guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return output.write(pointer, maxLength: buffer.count)
            }
            if written < 0 { fail(t("TCP 写入失败。")); return }
            if written == 0 { return }
            pending.removeFirst(written)
        }
    }
    func startTLS(host: String) throws {
        guard let input, let output, pending.isEmpty else { throw AnimeSyncPlayProtocolError.invalidTLS }
        let settings: [String: Any] = [kCFStreamSSLPeerName as String: host,
            kCFStreamSSLLevel as String: kCFStreamSocketSecurityLevelNegotiatedSSL,
            kCFStreamSSLValidatesCertificateChain as String: true]
        let key = Stream.PropertyKey(rawValue: kCFStreamPropertySSLSettings as String)
        guard input.setProperty(settings as NSDictionary, forKey: key), output.setProperty(settings as NSDictionary, forKey: key) else {
            throw AnimeSyncPlayProtocolError.invalidTLS
        }
    }
    func close() {
        closed = true
        for stream in [input as Stream?, output as Stream?].compactMap({ $0 }) {
            stream.delegate = nil; stream.remove(from: .main, forMode: .common); stream.close()
        }
        input = nil; output = nil; pending.removeAll(keepingCapacity: false)
    }
    nonisolated func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        // Both streams are scheduled exclusively on the main run loop. Bridge
        // only value types; the non-Sendable Stream stays outside the closure.
        let streamID = ObjectIdentifier(aStream)
        let eventMask = eventCode.rawValue
        MainActor.assumeIsolated { handle(streamID, event: Stream.Event(rawValue: eventMask)) }
    }
    private func handle(_ streamID: ObjectIdentifier, event: Stream.Event) {
        guard !closed else { return }
        let inputID = input.map { ObjectIdentifier($0) }
        let outputID = output.map { ObjectIdentifier($0) }
        guard inputID == streamID || outputID == streamID else { return }
        switch event {
        case .hasBytesAvailable:
            guard let input else { return }
            var bytes = [UInt8](repeating: 0, count: 8192)
            while !closed && input.hasBytesAvailable {
                let count = input.read(&bytes, maxLength: bytes.count)
                if count < 0 { fail(t("TCP 读取失败。")); return }
                if count == 0 { return }
                onData?(Data(bytes.prefix(count)))
            }
        case .hasSpaceAvailable, .openCompleted: flush()
        case .errorOccurred: fail(t("连接失败或 TLS 证书验证失败。"))
        case .endEncountered: fail(t("服务器关闭了连接。"))
        default: break
        }
    }
    private func fail(_ message: String) {
        guard !closed else { return }
        let handler = onError
        close(); handler?(message)
    }
}

enum AnimeSyncPlayProtocolError: Error { case invalidTLS, invalidJSON }

/// One instance per player VM. Init/updateLocalPlayback never connect; only connect() starts a session.
@MainActor
final class AnimeSyncPlayService: ObservableObject {
    @Published var endpoint = AnimeSyncPlayEndpoint.upstreamDefault
    @Published var username = ""
    @Published var room = ""
    @Published private(set) var connectionState: AnimeSyncPlayConnectionState = .disconnected
    @Published private(set) var messages: [AnimeSyncPlayMessage] = []
    @Published private(set) var error: String?
    @Published private(set) var roundTripMilliseconds = 0
    @Published private(set) var connectedRoom = ""
    var onRemotePlayback: ((Bool, Double) -> Void)?
    var onRemoteEpisode: ((Int) -> Void)?
    /// Set from the VM's public Bangumi detail for Kazumi's numeric file identifiers.
    var bangumiID: Int?

    private struct Configuration {
        let endpoint: AnimeSyncPlayEndpoint
        let user: String
        let room: String
    }
    private let transportFactory: @MainActor () -> any AnimeSyncPlayTransport
    private var transport: (any AnimeSyncPlayTransport)?
    private var configuration: Configuration?
    private var generation = UUID()
    private var buffer = Data()
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var wantsConnection = false
    private var helloSent = false
    private var joined = false
    private var roomInitialized = false
    private var receivedRemoteState = false
    private var acceptsRemotePlayback = false
    private var stagedRoomState: [String: Any]?
    private var activeUsername = ""
    private var lastReceive = Date()
    private var lastSend = Date.distantPast
    private var lastPosition: Double = 0
    private var isPlaying = false
    private var episodeNumber = 0
    private var title = ""
    private var localUpdatedAt = Date()
    private var advertisedFile = ""
    private var suppressUntil = Date.distantPast
    private var expectedRemoteEpisode: Int?
    private var expectedEpisodeDeadline = Date.distantPast
    private var pendingRemotePlayback: (Bool, Double)?
    private var applyingRemote = false
    private var clientIgnore = 0
    private var serverIgnore = 0
    private var latencyCalculation: Double?
    private var clientRTT: Double = 0
    private var averageRTT: Double = 0

    init(transportFactory: @escaping @MainActor () -> any AnimeSyncPlayTransport = { AnimeSyncPlayStreamTransport() }) {
        self.transportFactory = transportFactory
    }

    /// Syncplay creates a room on the first Hello; create/join share its server-confirmed handshake.
    func connect(createRoom: Bool = false) {
        disconnect()
        error = nil
        guard let parsed = AnimeSyncPlayEndpoint(endpoint) else { failValidation(t("服务器格式应为 HOST:PORT 或 syncplays://HOST:PORT。")); return }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let roomName = room.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validLabel(user), validLabel(roomName) else { failValidation(t("用户名和房间名须为 1–128 个字符，且不含换行或控制字符。")); return }
        configuration = Configuration(endpoint: parsed, user: user, room: roomName)
        wantsConnection = true; reconnectAttempt = 0; messages.removeAll(); error = nil
        appendSystem(createRoom ? t("正在创建或加入房间，等待服务器确认。") : t("正在加入房间，等待服务器确认。"))
        beginConnection()
    }

    func disconnect() {
        wantsConnection = false; generation = UUID()
        heartbeatTask?.cancel(); heartbeatTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        transport?.close(); transport = nil
        configuration = nil; buffer.removeAll(); joined = false; roomInitialized = false
        receivedRemoteState = false; acceptsRemotePlayback = false; stagedRoomState = nil
        connectedRoom = ""; activeUsername = ""
        expectedRemoteEpisode = nil; pendingRemotePlayback = nil; applyingRemote = false; suppressUntil = .distantPast
        clientIgnore = 0; serverIgnore = 0; latencyCalculation = nil
        roundTripMilliseconds = 0; connectionState = .disconnected
    }

    func sendChat(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined else { error = t("请先加入房间。"); return }
        guard !message.isEmpty, message.count <= 500, !message.contains("\0") else { error = t("消息须为 1–500 个字符。"); return }
        send(["Chat": message])
        // The server echo is the delivery receipt; do not fabricate a successful local message.
    }

    func updateLocalPlayback(isPlaying: Bool, position: Double, episodeNumber: Int, title: String, force: Bool = false) {
        guard position.isFinite, position >= 0, episodeNumber >= 0 else { return }
        let now = Date()
        let predicted = currentPosition(at: now)
        let changed = self.isPlaying != isPlaying
        let seek = abs(position - predicted) > 1.5
        let episodeChanged = self.episodeNumber != episodeNumber || self.title != title
        self.isPlaying = isPlaying; lastPosition = position; localUpdatedAt = now
        self.episodeNumber = episodeNumber; self.title = title
        guard joined, roomInitialized, acceptsRemotePlayback, !applyingRemote else { return }
        if let expectedRemoteEpisode {
            if now < expectedEpisodeDeadline {
                if episodeNumber == expectedRemoteEpisode {
                    self.expectedRemoteEpisode = nil
                    suppressUntil = now.addingTimeInterval(2)
                    if let desired = pendingRemotePlayback {
                        pendingRemotePlayback = nil
                        self.isPlaying = desired.0; lastPosition = desired.1; localUpdatedAt = now
                        applyingRemote = true; onRemotePlayback?(desired.0, desired.1); applyingRemote = false
                    }
                }
                return
            }
            self.expectedRemoteEpisode = nil; pendingRemotePlayback = nil
        }
        guard now >= suppressUntil else { return }
        if episodeChanged { publishFile() }
        if force || changed || seek || episodeChanged {
            clientIgnore += 1
            sendState(doSeek: seek || episodeChanged || force)
        }
    }

    private func beginConnection() {
        guard wantsConnection, let configuration else { return }
        generation = UUID()
        let current = generation
        transport?.close()
        buffer.removeAll(); helloSent = false; joined = false; roomInitialized = false
        receivedRemoteState = false; acceptsRemotePlayback = false; stagedRoomState = nil
        pendingRemotePlayback = nil; expectedRemoteEpisode = nil
        advertisedFile = ""; clientIgnore = 0; serverIgnore = 0
        latencyCalculation = nil; clientRTT = 0; averageRTT = 0
        lastReceive = Date(); lastSend = .distantPast
        connectionState = reconnectAttempt == 0 ? .connecting : .reconnecting(reconnectAttempt)
        let socket = transportFactory(); transport = socket
        socket.onData = { [weak self] data in
            guard let self, self.generation == current else { return }
            self.receive(data)
        }
        socket.onError = { [weak self] message in
            guard let self, self.generation == current else { return }
            self.connectionFailed(message)
        }
        socket.connect(host: configuration.endpoint.host, port: configuration.endpoint.port)
        // Writes are buffered until TCP is writable; no Hello crosses an unencrypted official connection.
        if configuration.endpoint.requiresTLS {
            connectionState = .securing
            send(["TLS": ["startTLS": "send"]])
        } else { sendHello() }
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.generation == current, self.wantsConnection else { return }
                if Date().timeIntervalSince(self.lastReceive) > (self.joined ? 30 : 15) {
                    self.connectionFailed(self.joined ? t("服务器心跳超时。") : t("握手或房间确认超时。"))
                    return
                }
                if self.joined && Date().timeIntervalSince(self.lastSend) >= 5 { self.sendState() }
            }
        }
    }

    private func sendHello() {
        guard !helloSent, let configuration else { return }
        helloSent = true; connectionState = .joining
        send(["Hello": ["username": configuration.user, "room": ["name": configuration.room], "version": "1.7.0",
            "features": ["sharedPlaylists": true, "chat": true, "featureList": true,
                         "readiness": true, "managedRooms": false]]])
    }
    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 1_048_576 else { connectionFailed(t("服务器消息超过限制。")); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard !line.isEmpty, line != Data([13]) else { continue }
            do {
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw AnimeSyncPlayProtocolError.invalidJSON }
                lastReceive = Date()
                handle(object)
            } catch { connectionFailed(t("服务器返回了无效的 JSON 消息。")); return }
            if transport == nil { return }
        }
    }
    private func handle(_ json: [String: Any]) {
        if json["Error"] != nil { connectionFailed(t("Syncplay 服务器拒绝了请求，请检查房间与服务器配置。"), retry: false); return }
        if let tls = json["TLS"] as? [String: Any] {
            guard !helloSent, configuration?.endpoint.requiresTLS == true,
                  tls["startTLS"] as? String == "true", let configuration else {
                connectionFailed(t("服务器拒绝或返回了无效的 TLS 升级。"), retry: false); return
            }
            do { try transport?.startTLS(host: configuration.endpoint.host); sendHello() }
            catch { connectionFailed(t("TLS 升级失败，未发送用户名或房间信息。"), retry: false) }
            return
        }
        if let hello = json["Hello"] as? [String: Any] {
            guard helloSent, !joined, let actualUser = hello["username"] as? String,
                  !actualUser.isEmpty, let actualRoom = (hello["room"] as? [String: Any])?["name"] as? String,
                  actualRoom == configuration?.room else {
                connectionFailed(t("房间握手回执不匹配。"), retry: false); return
            }
            joined = true; activeUsername = actualUser; connectedRoom = actualRoom
            connectionState = .connected; error = nil; reconnectAttempt = 0
            appendSystem(String(format: t("已加入房间 %@，用户名 %@。"), actualRoom, actualUser))
            send(["Set": ["ready": ["isReady": true, "manuallyInitiated": false]]])
            send(["List": NSNull()])
        }
        guard joined else { return }
        if let list = json["List"] as? [String: Any], !roomInitialized, let roomUsers = list[connectedRoom] as? [String: Any] {
            let peers = roomUsers.keys.filter { $0 != activeUsername }.sorted()
            initializeRoom(hasPeers: !peers.isEmpty)
            if let first = peers.first, let peer = roomUsers[first] as? [String: Any], let file = peer["file"] as? [String: Any] {
                receiveFile(file, sender: first)
            }
        }
        if let set = json["Set"] as? [String: Any] {
            if let playlist = set["playlistIndex"] as? [String: Any], !roomInitialized {
                let owner = playlist["user"] as? String ?? ""
                initializeRoom(hasPeers: !owner.isEmpty && owner != activeUsername)
            }
            if let users = set["user"] as? [String: Any] {
                for (sender, raw) in users {
                    guard let details = raw as? [String: Any] else { continue }
                    if let event = details["event"] as? [String: Any], sender != activeUsername {
                        if event["joined"] as? Bool == true { appendSystem(String(format: t("%@ 加入了房间。"), sender)) }
                        if event["left"] as? Bool == true { appendSystem(String(format: t("%@ 离开了房间。"), sender)) }
                    }
                    if let file = details["file"] as? [String: Any] { receiveFile(file, sender: sender) }
                }
            }
        }
        if let chat = json["Chat"] as? [String: Any], let text = chat["message"] as? String,
           let sender = chat["username"] as? String {
            appendMessage(AnimeSyncPlayMessage(username: String(sender.prefix(128)), text: String(text.prefix(2000)), isSystem: false))
        }
        if let state = json["State"] as? [String: Any] {
            if roomInitialized { receiveState(state) }
            else { stagedRoomState = state }
        }
    }

    private func initializeRoom(hasPeers: Bool) {
        guard !roomInitialized else { return }
        roomInitialized = true
        if hasPeers {
            appendSystem(t("已有用户在房间中，将跟随房间进度。"))
            // Do not advertise a different episode while joining; wait for the peer file/state.
        } else {
            acceptsRemotePlayback = true
            stagedRoomState = nil
            appendSystem(t("当前房间只有你，已共享当前番剧标识。"))
            publishFile()
            if !receivedRemoteState { clientIgnore += 1; sendState(doSeek: true) }
        }
    }
    private func receiveFile(_ file: [String: Any], sender: String) {
        guard sender != activeUsername, let name = file["name"] as? String, name.count <= 512 else { return }
        // Kazumi uses BangumiID[episode]; WaifuX uses the human title[episode] when no ID is provided.
        guard let open = name.lastIndex(of: "["), name.hasSuffix("]"),
              let number = Int(name[name.index(after: open)..<name.index(before: name.endIndex)]), number > 0,
              number <= 100_000 else { return }
        let identifier = String(name[..<open])
        let normalized: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping }
        let matches: Bool
        if let remoteID = Int(identifier) { matches = bangumiID == remoteID && remoteID > 0 }
        else { matches = !title.isEmpty && normalized(identifier) == normalized(title) }
        acceptsRemotePlayback = matches
        guard matches else {
            pendingRemotePlayback = nil; expectedRemoteEpisode = nil
            appendSystem(t("房间中播放的番剧与本地不一致，未自动切集。"))
            return
        }
        if number != episodeNumber, expectedRemoteEpisode != number {
            pendingRemotePlayback = nil
            expectedRemoteEpisode = number; expectedEpisodeDeadline = Date().addingTimeInterval(20)
            suppressUntil = Date().addingTimeInterval(2)
            applyingRemote = true; onRemoteEpisode?(number); applyingRemote = false
            appendSystem(String(format: t("%@ 切换到第 %d 集。"), sender, number))
        }
        if let staged = stagedRoomState {
            stagedRoomState = nil
            receiveState(staged)
        }
    }
    private func receiveState(_ state: [String: Any]) {
        let now = Date()
        if let ping = state["ping"] as? [String: Any] {
            latencyCalculation = (ping["latencyCalculation"] as? NSNumber)?.doubleValue
            if let echoed = (ping["clientLatencyCalculation"] as? NSNumber)?.doubleValue {
                let sample = now.timeIntervalSince1970 - echoed
                if sample.isFinite && sample >= 0 && sample < 30 {
                    clientRTT = sample
                    averageRTT = averageRTT == 0 ? sample : averageRTT * 0.85 + sample * 0.15
                    roundTripMilliseconds = Int(sample * 1000)
                }
            }
        }
        if let ignoring = state["ignoringOnTheFly"] as? [String: Any] {
            if let server = ignoring["server"] as? Int { serverIgnore = server; clientIgnore = 0 }
            else if let client = ignoring["client"] as? Int, client == clientIgnore { clientIgnore = 0 }
        }
        if clientIgnore == 0, let playback = state["playstate"] as? [String: Any],
           let paused = playback["paused"] as? Bool, let rawPosition = (playback["position"] as? NSNumber)?.doubleValue,
           rawPosition.isFinite, rawPosition >= 0, rawPosition <= 31_536_000 {
            receivedRemoteState = true
            let position = rawPosition + (paused ? 0 : min(averageRTT / 2, 1))
            let remotePlaying = !paused
            let seek = playback["doSeek"] as? Bool ?? false
            let sender = playback["setBy"] as? String ?? ""
            if acceptsRemotePlayback && sender != activeUsername && (expectedRemoteEpisode != nil || remotePlaying != isPlaying || seek || abs(position - currentPosition(at: now)) > 1) {
                isPlaying = remotePlaying; lastPosition = position; localUpdatedAt = now
                suppressUntil = now.addingTimeInterval(2)
                if expectedRemoteEpisode != nil {
                    pendingRemotePlayback = (remotePlaying, position)
                } else {
                    applyingRemote = true; onRemotePlayback?(remotePlaying, position); applyingRemote = false
                }
            }
        }
        sendState()
    }
    private func publishFile() {
        guard joined, episodeNumber > 0 else { return }
        // No API accepts a media URL, headers, Cookie, or signed query; only this bounded display title enters the room.
        let safeTitle = title.contains("://") ? "WaifuX" : title
        let sanitized = String(safeTitle.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(240))
        let identifier = bangumiID.flatMap { $0 > 0 ? String($0) : nil } ?? (sanitized.isEmpty ? "WaifuX" : sanitized)
        let filename = "\(identifier)[\(episodeNumber)]"
        guard filename != advertisedFile else { return }
        advertisedFile = filename
        send(["Set": ["file": ["name": filename, "duration": 0, "size": 0]]])
    }
    private func sendState(doSeek: Bool? = nil) {
        guard joined else { return }
        var ping: [String: Any] = ["clientRtt": clientRTT, "clientLatencyCalculation": Date().timeIntervalSince1970]
        if let latencyCalculation, latencyCalculation.isFinite { ping["latencyCalculation"] = latencyCalculation }
        var playstate: [String: Any] = ["position": currentPosition(at: Date()), "paused": !isPlaying, "setBy": activeUsername]
        if let doSeek { playstate["doSeek"] = doSeek }
        var state: [String: Any] = ["ping": ping, "playstate": playstate]
        var ack: [String: Int] = [:]
        if clientIgnore > 0 { ack["client"] = clientIgnore }
        if serverIgnore > 0 { ack["server"] = serverIgnore; serverIgnore = 0 }
        if !ack.isEmpty { state["ignoringOnTheFly"] = ack }
        send(["State": state])
    }
    private func send(_ object: [String: Any]) {
        guard let transport, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var framed = data; framed.append(contentsOf: [13, 10])
        lastSend = Date(); transport.send(framed)
    }
    private func currentPosition(at now: Date) -> Double {
        lastPosition + (isPlaying ? max(0, now.timeIntervalSince(localUpdatedAt)) : 0)
    }
    private func connectionFailed(_ message: String, retry: Bool = true) {
        generation = UUID(); heartbeatTask?.cancel(); heartbeatTask = nil
        transport?.close(); transport = nil; buffer.removeAll()
        joined = false; roomInitialized = false; connectedRoom = ""; error = message
        guard wantsConnection, retry, reconnectAttempt < 3 else {
            wantsConnection = false; connectionState = .failed; appendSystem(message); return
        }
        reconnectAttempt += 1; let attempt = reconnectAttempt
        connectionState = .reconnecting(attempt)
        appendSystem(String(format: t("%@ 准备第 %d 次重连。"), message, attempt))
        let current = generation
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(Double(1 << (attempt - 1)))) } catch { return }
            guard let self, self.wantsConnection, self.generation == current else { return }
            self.beginConnection()
        }
    }
    private func validLabel(_ label: String) -> Bool {
        !label.isEmpty && label.count <= 128 && !label.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private func failValidation(_ message: String) { error = message; connectionState = .failed }
    private func appendSystem(_ text: String) { appendMessage(AnimeSyncPlayMessage(username: "Syncplay", text: text, isSystem: true)) }
    private func appendMessage(_ message: AnimeSyncPlayMessage) {
        messages.append(message)
        if messages.count > 200 { messages.removeFirst(messages.count - 200) }
    }
}
