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
 
    // ✅ CRITICAL: Reduce queue size to prevent memory issues
    private let messageProcessingQueue = DispatchQueue(label: "com.iccc.messageProcessing", qos: .utility) // Lower priority
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
    
    private var memoryWarningObserver: NSObjectProtocol?
    
    // ✅ CRITICAL: Much lower limits
    private let maxQueuedMessages = 100 // Reduced from 1000
    private var queuedMessageCount = 0
    
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
        
        // ✅ CRITICAL: Reduce memory usage
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        session = URLSession(configuration: config)
        
        startAckFlusher()
        startHealthMonitor()
        setupMemoryWarningHandler()
    }
    
    private func setupMemoryWarningHandler() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            print("⚠️⚠️⚠️ MEMORY WARNING - AGGRESSIVE CLEANUP")
            
            // Clear everything
            self.ackLock.lock()
            self.pendingAcks.removeAll()
            self.ackLock.unlock()
            
            EventImageLoader.shared.clearCache()
            HLSPlayerManager.shared.releaseAllPlayers()
            
            self.queuedMessageCount = 0
            
            // Force garbage collection
            autoreleasepool { }
        }
    }

    private func startHealthMonitor() {
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            guard self.isConnected else { return }
            
            let now = Date().timeIntervalSince1970
            
            // ✅ Detect stalls faster
            if self.lastProcessedTimestamp > 0 && (now - self.lastProcessedTimestamp) > 15 {
                print("⚠️ Processing stalled, reconnecting")
                self.reconnect()
                return
            }
            
            // ✅ Clear queue more aggressively
            if self.queuedMessageCount > 50 {
                print("⚠️ Queue overflow (\(self.queuedMessageCount)), clearing")
                self.queuedMessageCount = 0
            }
        }
    }
    
    func connect() {
        guard webSocketTask == nil else {
            print("⚠️ WebSocket already exists")
            return
        }
        
        guard let url = URL(string: "\(baseURL)/ws") else {
            print("❌ Invalid URL")
            return
        }
        
        print("🔌 Connecting... clientId=\(clientId)")
        
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        receiveMessage()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if self.webSocketTask?.state == .running {
                self.isConnected = true
                self.connectionStatus = "Connected"
                self.hasSubscribed = false
                print("✅ Connected successfully")
                self.startPing()
  
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.sendSubscriptionV2()
                }
            } else {
                print("❌ Connection failed")
            }
        }
    }
    
    func disconnect() {
        print("🔌 Disconnecting...")
        flushAcksSync()
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        hasSubscribed = false
        pingTimer?.invalidate()
        ackFlushTimer?.invalidate()
        print("✅ Disconnected")
    }
    
    private func reconnect() {
        print("🔄 Attempting reconnect...")
        
        guard webSocketTask?.state != .running else {
            print("⚠️ Already connected, skipping reconnect")
            return
        }
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        hasSubscribed = false
        
        // ✅ Clear queue on reconnect
        queuedMessageCount = 0
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.connect()
        }
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                // ✅ CRITICAL: Wrap everything in autoreleasepool
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
                
                // ✅ Continue receiving with queue check
                if self.queuedMessageCount < self.maxQueuedMessages {
                    self.receiveMessage()
                } else {
                    print("⚠️ Queue full, pausing reception")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self.queuedMessageCount = 0
                        self.receiveMessage()
                    }
                }
                
            case .failure(let error):
                print("❌ WebSocket error: \(error.localizedDescription)")
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
        
        // ✅ CRITICAL: Drop messages aggressively if queue is full
        guard queuedMessageCount < maxQueuedMessages else {
            droppedCount += 1
            if droppedCount % 10 == 0 {
                print("⚠️ Dropped \(droppedCount) messages")
            }
            return
        }
        
        queuedMessageCount += 1
        
        // ✅ Process with lower priority and autoreleasepool
        messageProcessingQueue.async { [weak self] in
            autoreleasepool {
                self?.handleMessage(text)
                self?.queuedMessageCount -= 1
            }
        }
    }

    private func handleMessage(_ text: String) {
        // ✅ CRITICAL: Catch ALL exceptions
        do {
            try _handleMessageInternal(text)
        } catch {
            print("❌ Error handling message: \(error)")
            droppedCount += 1
        }
    }

    private func _handleMessageInternal(_ text: String) throws {
        // ✅ Handle subscription confirmation
        if text.contains("\"status\":\"subscribed\"") {
            print("✅ Subscription confirmed")
            pendingSubscriptionUpdate = false
            return
        }

        guard let data = text.data(using: .utf8) else {
            return
        }
        
        // ✅ CRITICAL: Safe JSON parsing
        guard let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Not valid JSON, ignore
            return
        }
        
        // ✅ Check if camera list (handle FIRST before other processing)
        if let type = jsonDict["type"] as? String, type == "camera-list" {
            handleCameraListMessage(jsonDict)
            return
        }
        
        // ✅ Try to decode as Event
        let decoder = JSONDecoder()
        guard let event = try? decoder.decode(Event.self, from: data) else {
            // Not an event we care about
            return
        }
        
        handleEvent(event)
    }
    
    // ✅ CRITICAL: Simplified camera handler
    private func handleCameraListMessage(_ jsonDict: [String: Any]) {
        autoreleasepool {
            guard let dataDict = jsonDict["data"] as? [String: Any],
                  let rawCameraJSON = dataDict["_raw_camera_json"] as? String,
                  let cameraData = rawCameraJSON.data(using: .utf8) else {
                print("❌ Invalid camera message")
                return
            }
            
            do {
                let cameraResponse = try JSONDecoder().decode(CameraListResponse.self, from: cameraData)
                
                // ✅ Update on main thread (avoid race conditions)
                DispatchQueue.main.async {
                    CameraManager.shared.updateCameras(cameraResponse.cameras)
                }
                
            } catch {
                print("❌ Camera decode error: \(error)")
            }
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

        // ✅ Log less frequently
        if processedCount % 50 == 0 {
            print("📊 Stats: received=\(receivedCount), processed=\(processedCount), dropped=\(droppedCount)")
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
        // ✅ Slower flushing
        ackFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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

            let count = min(self.pendingAcks.count, 50)
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
                    print("❌ ACK failed: \(error.localizedDescription)")
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
        
        print("💾 Flushed \(allAcks.count) ACKs")
    }

    func sendSubscriptionV2() {
        guard isConnected, webSocketTask?.state == .running else {
            print("⚠️ Cannot subscribe - not connected")
            pendingSubscriptionUpdate = true
            return
        }
        
        let now = Date().timeIntervalSince1970
        if hasSubscribed && (now - lastSubscriptionTime) < 5 {
            print("⚠️ Skipping duplicate subscription")
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
            print("❌ Failed to serialize subscription")
            return
        }
        
        print("📤 Sending subscription: \(subscriptions.count) channels")
        
        if !resetConsumers {
            catchUpMode = true
            print("⚡ CATCH-UP MODE ENABLED")

            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                if self.catchUpMode {
                    self.catchUpMode = false
                    print("✅ CATCH-UP MODE DISABLED")
                }
            }
        }
        
        webSocketTask?.send(.string(str)) { error in
            if let error = error {
                print("❌ Subscription failed: \(error.localizedDescription)")
                self.reconnect()
            } else {
                self.hasSubscribed = true
                self.lastSubscriptionTime = now
                print("✅ Subscription sent")
            }
        }
    }
    
    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            guard self.isConnected else { return }
            
            if self.webSocketTask?.state == .running {
                self.webSocketTask?.sendPing { error in
                    if let error = error {
                        print("❌ Ping failed: \(error.localizedDescription)")
                        self.reconnect()
                    }
                }
            } else {
                print("🔄 WebSocket not running, reconnecting")
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

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        return min(max(self, limits.lowerBound), limits.upperBound)
    }
}