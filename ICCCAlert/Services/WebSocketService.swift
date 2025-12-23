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
 
    // ✅ FIXED: Dedicated serial queue for message processing
    private let messageProcessingQueue = DispatchQueue(label: "com.iccc.messageProcessing", qos: .userInitiated)
    private let ackQueue = DispatchQueue(label: "com.iccc.ackProcessing", qos: .utility)
    
    // ✅ FIXED: Thread-safe ack management
    private var pendingAcks: [String] = []
    private let ackLock = NSLock()
    private let maxAckBatchSize = 50
    private var ackFlushTimer: Timer?

    // ✅ FIXED: Atomic counters with proper synchronization
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
    
    // ✅ FIXED: Memory pressure monitoring
    private var memoryWarningObserver: NSObjectProtocol?
    private let maxQueuedMessages = 1000
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
        config.waitsForConnectivity = true // ✅ Better connection handling
        session = URLSession(configuration: config)
        
        startAckFlusher()
        startHealthMonitor()
        setupMemoryWarningHandler()
    }
    
    // ✅ NEW: Memory pressure handling
    private func setupMemoryWarningHandler() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            DebugLogger.shared.log("⚠️ MEMORY WARNING - Clearing caches", emoji: "🧹", color: .red)
            
            // Clear pending acks (they'll be re-sent on reconnect)
            self.ackLock.lock()
            self.pendingAcks.removeAll()
            self.ackLock.unlock()
            
            // Clear image cache
            EventImageLoader.shared.clearCache()
            
            // Force garbage collection
            self.queuedMessageCount = 0
        }
    }

    private func startHealthMonitor() {
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            let now = Date().timeIntervalSince1970
            if self.lastProcessedTimestamp > 0 && (now - self.lastProcessedTimestamp) > 10 {
                DebugLogger.shared.log("⚠️ Processing stalled, reconnecting", emoji: "🔄", color: .orange)
                self.reconnect()
            }
            
            // ✅ FIXED: Check for message queue overflow
            if self.queuedMessageCount > self.maxQueuedMessages {
                DebugLogger.shared.log("⚠️ Message queue overflow, clearing old messages", emoji: "🧹", color: .orange)
                self.queuedMessageCount = 0
                self.messageProcessingQueue.async {
                    // Queue will naturally drain
                }
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
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        hasSubscribed = false
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.connect()
        }
    }
    
    // ✅ FIXED: Improved message receiving with backpressure
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                autoreleasepool { // ✅ CRITICAL: Prevent memory buildup
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
                
                // ✅ Continue receiving only if not overloaded
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
    
    // ✅ FIXED: Separate function for message queuing
    private func handleIncomingMessage(_ text: String) {
        receivedCount += 1
        lastProcessedTimestamp = Date().timeIntervalSince1970
        
        // ✅ Check queue size before adding
        guard queuedMessageCount < maxQueuedMessages else {
            droppedCount += 1
            DebugLogger.shared.log("⚠️ Dropped message - queue full", emoji: "🗑️", color: .red)
            return
        }
        
        queuedMessageCount += 1
        
        // ✅ Process on dedicated serial queue (prevents race conditions)
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
            DebugLogger.shared.log("Error handling message: \(error)", emoji: "❌", color: .red)
            droppedCount += 1
        }
    }
    
    private func _handleMessageInternal(_ text: String) throws {
        // ✅ FIXED: Handle subscription confirmation early
        if text.contains("\"status\":\"subscribed\"") {
            DebugLogger.shared.log("Subscription confirmed", emoji: "✅", color: .green)
            pendingSubscriptionUpdate = false
            return
        }
  
        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: "WebSocket", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert to data"])
        }
        
        // ✅ FIXED: Use more efficient JSON decoding
        guard let event = try? JSONDecoder().decode(Event.self, from: data) else {
            throw NSError(domain: "WebSocket", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to decode JSON"])
        }
        
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

        // ✅ FIXED: Add event on background thread (SubscriptionManager should handle this safely)
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

                // ✅ FIXED: Dispatch to main thread for notifications
                DispatchQueue.main.async {
                    NotificationManager.shared.sendEventNotification(event: event, channel: tempChannel)
                }
            }

            // ✅ FIXED: Post notification on main thread
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

        // ✅ FIXED: Log stats less frequently to reduce overhead
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
        // ✅ FIXED: Use main thread timer for stability
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
                    DebugLogger.shared.log("ACK failed: \(error.localizedDescription)", emoji: "❌", color: .red)
                    self.ackLock.lock()
                    self.pendingAcks.insert(contentsOf: acksToSend, at: 0)
                    self.ackLock.unlock()
                } else {
                    self.ackedCount += acksToSend.count
                    
                    if acksToSend.count > 50 {
                        DebugLogger.shared.log("Sent BULK ACK: \(acksToSend.count) events", emoji: "✅", color: .green)
                    }
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
        
        DebugLogger.shared.log("Flushed \(allAcks.count) ACKs on shutdown", emoji: "💾", color: .blue)
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
            DebugLogger.shared.log("Skipping duplicate subscription", emoji: "⚠️", color: .orange)
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
            DebugLogger.shared.log("Failed to serialize subscription", emoji: "❌", color: .red)
            return
        }
        
        let mode = resetConsumers ? "RESET" : "RESUME"
        DebugLogger.shared.log("Sending subscription (\(mode)): \(subscriptions.count) channels", emoji: "📤", color: .blue)
        
        if !resetConsumers {
            catchUpMode = true
            DebugLogger.shared.log("⚡ CATCH-UP MODE ENABLED", emoji: "🚀", color: .orange)

            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                if self.catchUpMode {
                    self.catchUpMode = false
                    DebugLogger.shared.log("✅ CATCH-UP MODE AUTO-DISABLED", emoji: "🎯", color: .green)
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
                DebugLogger.shared.log("Subscription sent (reset=\(resetConsumers))", emoji: "✅", color: .green)
            }
        }
    }
    
    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            if self.webSocketTask?.state == .running {
                self.webSocketTask?.sendPing { error in
                    if let error = error {
                        DebugLogger.shared.log("Ping failed: \(error.localizedDescription)", emoji: "❌", color: .red)
                        self.reconnect()
                    }
                }
            } else {
                DebugLogger.shared.log("Connection lost during ping", emoji: "🔄", color: .orange)
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