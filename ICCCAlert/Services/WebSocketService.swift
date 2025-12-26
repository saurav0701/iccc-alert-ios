import Foundation
import Combine
import UIKit

class WebSocketService: ObservableObject {
    static let shared = WebSocketService()
    
    @Published var isConnected = false
    @Published var connectionStatus = "Disconnected"
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    
    private let baseURL = "ws://192.168.29.69:2222"
    
    private var pendingSubscriptionUpdate = false
    private var hasSubscribed = false
    private var lastSubscriptionTime: TimeInterval = 0
 
    private let messageProcessingQueue = DispatchQueue(label: "com.iccc.messageProcessing", qos: .userInitiated)
    private let ackQueue = DispatchQueue(label: "com.iccc.ackProcessing", qos: .utility)
    
    private var pendingAcks: [String] = []
    private let ackLock = NSLock()
    private let maxAckBatchSize = 50
    private var ackFlushTimer: Timer?

    private let statsLock = NSLock()
    private var _receivedCount = 0
    private var _processedCount = 0
    private var _droppedCount = 0
    private var _ackedCount = 0
    
    private var receivedCount: Int {
        get {
            statsLock.lock()
            defer { statsLock.unlock() }
            return _receivedCount
        }
        set {
            statsLock.lock()
            _receivedCount = newValue
            statsLock.unlock()
        }
    }
    
    private var processedCount: Int {
        get {
            statsLock.lock()
            defer { statsLock.unlock() }
            return _processedCount
        }
        set {
            statsLock.lock()
            _processedCount = newValue
            statsLock.unlock()
        }
    }
    
    private var droppedCount: Int {
        get {
            statsLock.lock()
            defer { statsLock.unlock() }
            return _droppedCount
        }
        set {
            statsLock.lock()
            _droppedCount = newValue
            statsLock.unlock()
        }
    }
    
    private var ackedCount: Int {
        get {
            statsLock.lock()
            defer { statsLock.unlock() }
            return _ackedCount
        }
        set {
            statsLock.lock()
            _ackedCount = newValue
            statsLock.unlock()
        }
    }

    private var lastProcessedTimestamp: TimeInterval = 0
    private var catchUpMode = false
    private let catchUpThreshold = 10 
    
    private var memoryWarningObserver: NSObjectProtocol?
    private let maxQueuedMessages = 1000
    private var queuedMessageCount = 0
    
    // CRITICAL: Track if user is actively viewing cameras to prevent updates
    private var isViewingCameras = false
    
    private var clientId: String {
        if let uuid = UIDevice.current.identifierForVendor?.uuidString {
            return "ios-\(String(uuid.prefix(8)))"
        }
        return "ios-unknown"
    }
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
        
        startAckFlusher()
        startHealthMonitor()
        setupMemoryWarningHandler()
        
        // Listen for player state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePlayerStateChange),
            name: NSNotification.Name("PlayerStateChanged"),
            object: nil
        )
    }
    
    @objc private func handlePlayerStateChange(_ notification: Notification) {
        if let isActive = notification.userInfo?["isActive"] as? Bool {
            isViewingCameras = isActive
            DebugLogger.shared.log("📹 Camera viewing state: \(isActive ? "ACTIVE" : "INACTIVE")", emoji: "📹", color: .blue)
        }
    }
    
    private func setupMemoryWarningHandler() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            DebugLogger.shared.log("⚠️ MEMORY WARNING - Clearing caches", emoji: "🧹", color: .red)
            
            self.ackLock.lock()
            self.pendingAcks.removeAll()
            self.ackLock.unlock()
            
            EventImageLoader.shared.clearCache()
            
            self.queuedMessageCount = 0
        }
    }

    private func startHealthMonitor() {
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            guard self.isConnected else { return }
            
            let now = Date().timeIntervalSince1970
            
            if self.lastProcessedTimestamp > 0 && (now - self.lastProcessedTimestamp) > 30 {
                DebugLogger.shared.log("⚠️ Processing stalled (30s), reconnecting", emoji: "🔄", color: .orange)
                self.reconnect()
                return
            }
            
            if self.queuedMessageCount > self.maxQueuedMessages {
                DebugLogger.shared.log("⚠️ Message queue overflow, clearing", emoji: "🧹", color: .orange)
                self.queuedMessageCount = 0
            }
        }
    }
    
    func connect() {
        guard webSocketTask == nil else {
            DebugLogger.shared.log("WebSocket already exists", emoji: "⚠️", color: .orange)
            return
        }
        
        guard let url = URL(string: "\(baseURL)/ws") else {
            DebugLogger.shared.log("Invalid URL", emoji: "❌", color: .red)
            return
        }
        
        DebugLogger.shared.log("Connecting... clientId=\(clientId)", emoji: "🔌", color: .blue)
        
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        receiveMessage()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if self.webSocketTask?.state == .running {
                self.isConnected = true
                self.connectionStatus = "Connected"
                self.hasSubscribed = false
                DebugLogger.shared.log("Connected successfully", emoji: "✅", color: .green)
                self.startPing()
  
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.sendSubscriptionV2()
                }
            } else {
                DebugLogger.shared.log("Connection failed", emoji: "❌", color: .red)
            }
        }
    }
    
    func disconnect() {
        flushAcksSync()
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        hasSubscribed = false
        pingTimer?.invalidate()
        ackFlushTimer?.invalidate()
        DebugLogger.shared.log("Disconnected", emoji: "🔌", color: .gray)
    }
    
    private func reconnect() {
        DebugLogger.shared.log("Attempting reconnect...", emoji: "🔄", color: .orange)
        
        guard webSocketTask?.state != .running else {
            DebugLogger.shared.log("Already connected, skipping reconnect", emoji: "⚠️", color: .orange)
            return
        }
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        hasSubscribed = false
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.connect()
        }
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                autoreleasepool {
                    switch message {
                    case .string(let text):
                        self.handleIncomingMessage(text)
                        
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleIncomingMessage(text)
                        }
                    @unknown default:
                        break
                    }
                }
                
                if self.queuedMessageCount < self.maxQueuedMessages {
                    self.receiveMessage()
                } else {
                    DebugLogger.shared.log("⚠️ Pausing message reception - queue full", emoji: "⏸️", color: .orange)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.queuedMessageCount = 0
                        self.receiveMessage()
                    }
                }
                
            case .failure(let error):
                DebugLogger.shared.log("WebSocket error: \(error.localizedDescription)", emoji: "❌", color: .red)
                self.isConnected = false
                
                if self.webSocketTask?.state != .canceling {
                    self.reconnect()
                }
            }
        }
    }
    
    private func handleIncomingMessage(_ text: String) {
        receivedCount += 1
        lastProcessedTimestamp = Date().timeIntervalSince1970
        
        guard queuedMessageCount < maxQueuedMessages else {
            droppedCount += 1
            return
        }
        
        queuedMessageCount += 1
        
        messageProcessingQueue.async { [weak self] in
            autoreleasepool {
                self?.handleMessage(text)
                self?.queuedMessageCount -= 1
            }
        }
    }

    private func handleMessage(_ text: String) {
        do {
            try _handleMessageInternal(text)
        } catch {
            DebugLogger.shared.log("❌ Error handling message: \(error)", emoji: "❌", color: .red)
            droppedCount += 1
        }
    }

    private func _handleMessageInternal(_ text: String) throws {
        if text.contains("\"status\":\"subscribed\"") {
            DebugLogger.shared.log("✅ Subscription confirmed", emoji: "✅", color: .green)
            pendingSubscriptionUpdate = false
            return
        }

        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: "WebSocket", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert to data"])
        }
        
        if let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            
            if let type = jsonDict["type"] as? String, type == "camera-list" {
                // CRITICAL: Only process camera updates if NOT actively viewing cameras
                guard !isViewingCameras else {
                    DebugLogger.shared.log("⏸️ Skipping camera update (user viewing cameras)", emoji: "⏸️", color: .orange)
                    return
                }
                
                DebugLogger.shared.log("📹 CAMERA LIST DETECTED", emoji: "📹", color: .green)
                
                if let dataDict = jsonDict["data"] as? [String: Any],
                   let rawCameraJSON = dataDict["_raw_camera_json"] as? String {
                    
                    if let cameraData = rawCameraJSON.data(using: .utf8) {
                        do {
                            let cameraResponse = try JSONDecoder().decode(CameraListResponse.self, from: cameraData)
                            DebugLogger.shared.log("✅ Decoded \(cameraResponse.cameras.count) cameras", emoji: "✅", color: .green)
                            
                            handleCameraList(cameraResponse)
                            return
                            
                        } catch {
                            DebugLogger.shared.log("❌ Failed to decode cameras: \(error)", emoji: "❌", color: .red)
                        }
                    }
                }
                
                return
            }
        }
        
        let decoder = JSONDecoder()
        
        guard let event = try? decoder.decode(Event.self, from: data) else {
            throw NSError(domain: "WebSocket", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to decode as Event"])
        }
        
        handleEvent(event)
    }

    private func handleCameraList(_ response: CameraListResponse) {
        let onlineCount = response.cameras.filter { $0.isOnline }.count
        
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📹", color: .blue)
        DebugLogger.shared.log("📹 Processing camera list", emoji: "📹", color: .blue)
        DebugLogger.shared.log("   Total: \(response.cameras.count)", emoji: "📊", color: .blue)
        DebugLogger.shared.log("   Online: \(onlineCount)", emoji: "🟢", color: .green)
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📹", color: .blue)
        
        // CRITICAL: Delay camera update if user might be in transition
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !self.isViewingCameras else {
                DebugLogger.shared.log("⏸️ Still viewing cameras, deferring update", emoji: "⏸️", color: .orange)
                return
            }
            
            CameraManager.shared.updateCameras(response.cameras)
            DebugLogger.shared.log("✅ CameraManager updated", emoji: "✅", color: .green)
        }
    }
    
    private func handleEvent(_ event: Event) {
        guard let eventId = event.id,
              let area = event.area,
              let type = event.type else {
            droppedCount += 1
            return
        }
        
        let channelId = "\(area)_\(type)"
 
        let sequence: Int64 = {
            if let seqValue = event.data?["_seq"] {
                switch seqValue {
                case .int64(let val):
                    return val
                case .int(let val):
                    return Int64(val)
                default:
                    return 0
                }
            }
            return 0
        }()

        if !SubscriptionManager.shared.isSubscribed(channelId: channelId) {
            droppedCount += 1
            sendAck(eventId: eventId)
            return
        }

        let isNew = ChannelSyncState.shared.recordEventReceived(
            channelId: channelId,
            eventId: eventId,
            timestamp: event.timestamp,
            seq: sequence
        )
        
        if !isNew && sequence > 0 {
            droppedCount += 1
            sendAck(eventId: eventId)
            return
        }

        let added = SubscriptionManager.shared.addEvent(event)
        
        if added {
            processedCount += 1
 
            if !catchUpMode {
                let tempChannel = Channel(
                    id: channelId,
                    area: area,
                    areaDisplay: event.areaDisplay ?? area,
                    eventType: type,
                    eventTypeDisplay: event.typeDisplay ?? type,
                    description: "",
                    isSubscribed: true,
                    isMuted: false,
                    isPinned: false
                )

                DispatchQueue.main.async {
                    NotificationManager.shared.sendEventNotification(event: event, channel: tempChannel)
                }
            }

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .newEventReceived,
                    object: nil,
                    userInfo: ["channelId": channelId, "eventId": eventId]
                )
            }
        } else {
            droppedCount += 1
        }
        
        sendAck(eventId: eventId)

        if processedCount % 100 == 0 {
            let stats = "received=\(receivedCount), processed=\(processedCount), dropped=\(droppedCount), acked=\(ackedCount)"
            DebugLogger.shared.log("STATS: \(stats)", emoji: "📊", color: .blue)
        }
    }

    private func sendAck(eventId: String) {
        ackLock.lock()
        pendingAcks.append(eventId)
        let shouldFlush = pendingAcks.count >= maxAckBatchSize
        ackLock.unlock()
        
        if shouldFlush {
            flushAcks()
        }
    }

    private func startAckFlusher() {
        ackFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.flushAcks()
        }
    }

    private func flushAcks() {
        ackQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.isConnected, self.webSocketTask?.state == .running else { return }
            
            self.ackLock.lock()
            guard !self.pendingAcks.isEmpty else {
                self.ackLock.unlock()
                return
            }

            let count = min(self.pendingAcks.count, 100)
            let acksToSend = Array(self.pendingAcks.prefix(count))
            self.pendingAcks.removeFirst(count)
            self.ackLock.unlock()
            
            let msg: [String: Any]
            if acksToSend.count == 1 {
                msg = [
                    "type": "ack",
                    "eventId": acksToSend[0],
                    "clientId": self.clientId
                ]
            } else {
                msg = [
                    "type": "batch_ack",
                    "eventIds": acksToSend,
                    "clientId": self.clientId
                ]
            }
            
            guard let data = try? JSONSerialization.data(withJSONObject: msg),
                  let str = String(data: data, encoding: .utf8) else {
                self.ackLock.lock()
                self.pendingAcks.insert(contentsOf: acksToSend, at: 0)
                self.ackLock.unlock()
                return
            }
            
            self.webSocketTask?.send(.string(str)) { error in
                if let error = error {
                    self.ackLock.lock()
                    self.pendingAcks.insert(contentsOf: acksToSend, at: 0)
                    self.ackLock.unlock()
                } else {
                    self.ackedCount += acksToSend.count
                }
            }
        }
    }

    private func flushAcksSync() {
        ackLock.lock()
        let allAcks = pendingAcks
        pendingAcks.removeAll()
        ackLock.unlock()
        
        guard !allAcks.isEmpty else { return }
        
        let msg: [String: Any] = [
            "type": "batch_ack",
            "eventIds": allAcks,
            "clientId": clientId
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }
        
        let semaphore = DispatchSemaphore(value: 0)
        webSocketTask?.send(.string(str)) { _ in
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    func sendSubscriptionV2() {
        guard isConnected, webSocketTask?.state == .running else {
            DebugLogger.shared.log("Cannot subscribe - not connected", emoji: "⚠️", color: .orange)
            pendingSubscriptionUpdate = true
            reconnect()
            return
        }
        
        let now = Date().timeIntervalSince1970
        if hasSubscribed && (now - lastSubscriptionTime) < 5 {
            return
        }
        
        let subscriptions = SubscriptionManager.shared.subscribedChannels
        guard !subscriptions.isEmpty else { return }
        
        let filters = subscriptions.map { channel -> [String: String] in
            return ["area": channel.area, "eventType": channel.eventType]
        }

        subscriptions.forEach { channel in
            ChannelSyncState.shared.enableCatchUpMode(channelId: channel.id)
        }
 
        var hasSyncState = false
        var syncState: [String: [String: Any]] = [:]
        
        subscriptions.forEach { channel in
            if let info = ChannelSyncState.shared.getSyncInfo(channelId: channel.id) {
                hasSyncState = true
                syncState[channel.id] = [
                    "lastEventId": info.lastEventId ?? "",
                    "lastTimestamp": info.lastEventTimestamp,
                    "lastSeq": info.highestSeq
                ]
            }
        }
        
        let resetConsumers = !hasSyncState
        
        let request: [String: Any] = [
            "clientId": clientId,
            "filters": filters,
            "syncState": syncState,
            "resetConsumers": resetConsumers
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let str = String(data: data, encoding: .utf8) else {
            return
        }
        
        let mode = resetConsumers ? "RESET" : "RESUME"
        DebugLogger.shared.log("Sending subscription (\(mode)): \(subscriptions.count) channels", emoji: "📤", color: .blue)
        
        if !resetConsumers {
            catchUpMode = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                if self.catchUpMode {
                    self.catchUpMode = false
                    DebugLogger.shared.log("✅ CATCH-UP MODE DISABLED", emoji: "🎯", color: .green)
                }
            }
        }
        
        webSocketTask?.send(.string(str)) { error in
            if let error = error {
                DebugLogger.shared.log("Subscription failed: \(error.localizedDescription)", emoji: "❌", color: .red)
                self.reconnect()
            } else {
                self.hasSubscribed = true
                self.lastSubscriptionTime = now
            }
        }
    }
    
    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            guard self.isConnected else { return }
            
            if self.webSocketTask?.state == .running {
                self.webSocketTask?.sendPing { error in
                    if error != nil {
                        // Don't immediately reconnect on single ping failure
                    }
                }
            } else {
                self.reconnect()
            }
        }
    }
    
    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

extension Notification.Name {
    static let newEventReceived = Notification.Name("newEventReceived")
}