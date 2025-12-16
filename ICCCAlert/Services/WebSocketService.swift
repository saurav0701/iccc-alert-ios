import Foundation
import Combine
import UserNotifications

class WebSocketService: ObservableObject {
    static let shared = WebSocketService()
    
    // MARK: - Published Properties
    @Published var isConnected = false
    @Published var connectionStatus = "Disconnected"
    @Published var receivedCount = 0
    @Published var processedCount = 0
    @Published var ackedCount = 0
    @Published var droppedCount = 0
    @Published var errorCount = 0
    
    // MARK: - Private Properties
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private let wsURL = "ws://192.168.29.70:19999/ws"
    
    private var clientId: String = ""
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = Int.max
    private let reconnectDelay: TimeInterval = 5.0
    
    // ✅ OPTIMIZED: Background queue for event processing
    private let processingQueue = DispatchQueue(label: "com.iccc.processing", qos: .userInitiated, attributes: .concurrent)
    private let eventBuffer = NSMutableArray() // Thread-safe array
    private let bufferLock = NSLock()
    
    // ✅ NEW: Batch processing for UI updates
    private var pendingUIUpdates = Set<String>() // channelIds
    private var uiBatchTimer: Timer?
    private let uiBatchDelay: TimeInterval = 0.5 // Batch UI updates every 500ms during catch-up
    
    // ACK batching
    private var pendingAcks: [String] = []
    private let ackLock = NSLock()
    private let ackBatchSize = 100 // ✅ Increased from 50
    private var ackTimer: Timer?
    
    // Ping/Pong
    private var pingTimer: Timer?
    private let pingInterval: TimeInterval = 30.0
    
    // ✅ OPTIMIZED: Catch-up monitoring
    private var catchUpChannels: Set<String> = []
    private var catchUpTimer: Timer?
    private let catchUpCheckInterval: TimeInterval = 3.0 // ✅ Reduced from 5s
    private var consecutiveEmptyChecks: [String: Int] = [:]
    private let stableEmptyThreshold = 2 // ✅ Reduced from 3
    
    // Connection state tracking
    private var lastConnectionTime: Date?
    private var connectionLostTime: Date?
    
    private var hasSubscribed = false
    private var lastSubscriptionTime: TimeInterval = 0
    
    // ✅ NEW: Processing control
    private var isProcessingBatch = false
    private let maxConcurrentProcessors = 4
    private var activeProcessors = 0
    
    // Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    // ✅ DEBUG LOGGER
    private let logger = DebugLogger.shared
    
    // MARK: - Initialization
    private init() {
        logger.log("INIT", "WebSocketService initializing...")
        setupClientId()
        setupSession()
        logger.log("INIT", "WebSocketService initialized with clientId: \(clientId)")
    }
    
    // MARK: - Client ID Management
    private func setupClientId() {
        clientId = KeychainClientID.getOrCreateClientID()
        logger.log("CLIENT_ID", "Using Keychain client ID: \(clientId)")
        UserDefaults.standard.set(clientId, forKey: "persistent_client_id")
    }
    
    private func setupSession() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 0
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: nil, delegateQueue: nil)
        logger.log("SESSION", "URLSession configured")
    }
    
    // MARK: - Connection Management
    func connect() {
        logger.log("CONNECT", "Connect called - isConnected=\(isConnected), hasTask=\(webSocketTask != nil)")
        
        if isConnected && webSocketTask != nil {
            logger.logWebSocket("⚠️ Already connected, skipping connect")
            return
        }
        
        disconnect()
        
        guard let url = URL(string: wsURL) else {
            logger.logError("CONNECT", "Invalid WebSocket URL: \(wsURL)")
            return
        }
        
        logger.logWebSocket("🔌 Connecting to \(wsURL) with client ID: \(clientId)")
        connectionStatus = "Connecting..."
        
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        isConnected = true
        reconnectAttempts = 0
        lastConnectionTime = Date()
        connectionStatus = "Connected - Monitoring alerts"
        
        logger.logWebSocket("✅ WebSocket connected, starting receivers...")
        
        startReceiving()
        startPingPong()
        startAckFlusher()
        startEventProcessors() // ✅ NEW: Start background processors
        startUIBatcher() // ✅ NEW: Start UI update batcher
        startStatsLogging()
        
        // Send subscription after connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.sendSubscriptionV2()
        }
    }
    
    func disconnect() {
        logger.logWebSocket("Disconnecting...")
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        hasSubscribed = false
        connectionLostTime = Date()
        connectionStatus = "Disconnected"
        
        stopPingPong()
        stopAckFlusher()
        stopCatchUpMonitoring()
        stopUIBatcher() // ✅ NEW
        
        logger.logWebSocket("🔌 WebSocket disconnected")
    }
    
    private func startReceiving() {
        logger.logWebSocket("Starting message receiver...")
        receiveMessage()
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessage()
                
            case .failure(let error):
                self.logger.logError("WS_RECEIVE", "❌ WebSocket error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.hasSubscribed = false
                    self.connectionStatus = "Disconnected - Reconnecting..."
                    self.scheduleReconnect()
                }
            }
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        var text: String?
        
        switch message {
        case .string(let str):
            text = str
        case .data(let data):
            text = String(data: data, encoding: .utf8)
        @unknown default:
            logger.logError("MESSAGE", "Unknown message type")
            return
        }
        
        guard let messageText = text else { return }
        
        DispatchQueue.main.async { [weak self] in
            self?.receivedCount += 1
        }
        
        // ✅ CRITICAL: Add to buffer WITHOUT blocking
        bufferLock.lock()
        eventBuffer.add(messageText)
        bufferLock.unlock()
    }
    
    // MARK: - ✅ NEW: Background Event Processors
    
    private func startEventProcessors() {
        for i in 0..<maxConcurrentProcessors {
            processingQueue.async { [weak self] in
                self?.eventProcessorLoop(id: i)
            }
        }
        logger.log("PROCESSORS", "Started \(maxConcurrentProcessors) background processors")
    }
    
    private func eventProcessorLoop(id: Int) {
        while isConnected {
            autoreleasepool {
                bufferLock.lock()
                let text = eventBuffer.count > 0 ? eventBuffer.firstObject as? String : nil
                if text != nil {
                    eventBuffer.removeObject(at: 0)
                }
                bufferLock.unlock()
                
                if let messageText = text {
                    processEvent(messageText)
                } else {
                    // No events, sleep briefly
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }
    }
    
    // MARK: - ✅ OPTIMIZED: Event Processing
    
    private func processEvent(_ text: String) {
        // Check for subscription confirmation
        if text.contains("\"status\":\"subscribed\"") || text.contains("\"status\":\"ok\"") {
            DispatchQueue.main.async { [weak self] in
                self?.hasSubscribed = true
                self?.logger.logWebSocket("✅ Subscription confirmed by server")
            }
            return
        }
        
        // Skip error messages
        if text.contains("\"error\"") {
            DispatchQueue.main.async { [weak self] in
                self?.errorCount += 1
            }
            return
        }
        
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
            return
        }
        
        guard let eventId = json["id"] as? String,
              let area = json["area"] as? String,
              let type = json["type"] as? String else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
            return
        }
        
        let channelId = "\(area)_\(type)"
        
        let eventData = json["data"] as? [String: Any] ?? [:]
        let requireAck = eventData["_requireAck"] as? Bool ?? true
        
        // Check if subscribed
        guard SubscriptionManager.shared.isSubscribed(channelId: channelId) else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
            if requireAck { sendAck(eventId: eventId) }
            return
        }
        
        // Get sequence number
        let sequence: Int64
        if let seqValue = eventData["_seq"] {
            if let seqNum = seqValue as? Int64 {
                sequence = seqNum
            } else if let seqStr = seqValue as? String, let seqNum = Int64(seqStr) {
                sequence = seqNum
            } else if let seqInt = seqValue as? Int {
                sequence = Int64(seqInt)
            } else {
                sequence = 0
            }
        } else {
            sequence = 0
        }
        
        let timestamp = json["timestamp"] as? Int64 ?? 0
        
        // ✅ CRITICAL: Record in sync state FIRST (thread-safe)
        let isNew = ChannelSyncState.shared.recordEventReceived(
            channelId: channelId,
            eventId: eventId,
            timestamp: timestamp,
            seq: sequence
        )
        
        // Duplicate check
        if !isNew && sequence > 0 {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
            if requireAck { sendAck(eventId: eventId) }
            return
        }
        
        // Convert to Event object
        guard let event = parseEvent(json: json) else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
            return
        }
        
        // ✅ CRITICAL: Add to storage (thread-safe)
        let added = SubscriptionManager.shared.addEvent(event: event)
        
        if added {
            DispatchQueue.main.async { [weak self] in
                self?.processedCount += 1
            }
            
            // ✅ OPTIMIZED: Queue UI update (don't block)
            let inCatchUpMode = ChannelSyncState.shared.isInCatchUpMode(channelId: channelId)
            
            if inCatchUpMode {
                // During catch-up: batch UI updates
                queueUIUpdate(for: channelId)
            } else {
                // Live mode: immediate UI update
                DispatchQueue.main.async { [weak self] in
                    self?.broadcastEvent(event, channelId: channelId)
                    self?.sendLocalNotification(for: event, channelId: channelId)
                }
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
        }
        
        // Send ACK
        if requireAck {
            sendAck(eventId: eventId)
        }
    }
    
    // ✅ NEW: Queue UI Update for Batching
    private func queueUIUpdate(for channelId: String) {
        DispatchQueue.main.async { [weak self] in
            self?.pendingUIUpdates.insert(channelId)
        }
    }
    
    // ✅ NEW: UI Update Batcher
    private func startUIBatcher() {
        DispatchQueue.main.async { [weak self] in
            self?.uiBatchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.flushUIUpdates()
            }
        }
    }
    
    private func stopUIBatcher() {
        uiBatchTimer?.invalidate()
        uiBatchTimer = nil
        flushUIUpdates() // Final flush
    }
    
    private func flushUIUpdates() {
        guard !pendingUIUpdates.isEmpty else { return }
        
        let channelsToUpdate = pendingUIUpdates
        pendingUIUpdates.removeAll()
        
        // Single UI update for multiple channels
        for channelId in channelsToUpdate {
            if let lastEvent = SubscriptionManager.shared.getLastEvent(channelId: channelId) {
                broadcastEvent(lastEvent, channelId: channelId)
            }
        }
    }
    
    private func broadcastEvent(_ event: Event, channelId: String) {
        NotificationCenter.default.post(
            name: .newEventReceived,
            object: nil,
            userInfo: ["event": event, "channelId": channelId]
        )
    }
    
    private func sendLocalNotification(for event: Event, channelId: String) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.message
        content.sound = .default
        content.badge = 1
        
        let request = UNNotificationRequest(
            identifier: event.id ?? UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                self.logger.logError("NOTIFICATION", "❌ Failed to send: \(error.localizedDescription)")
            }
        }
    }
    
    private func parseEvent(json: [String: Any]) -> Event? {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: json)
            let decoder = JSONDecoder()
            let event = try decoder.decode(Event.self, from: jsonData)
            return event
        } catch {
            logger.logError("PARSE", "Failed to parse event: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - ACK Management
    private func sendAck(eventId: String) {
        ackLock.lock()
        pendingAcks.append(eventId)
        let shouldFlush = pendingAcks.count >= ackBatchSize
        ackLock.unlock()
        
        if shouldFlush {
            flushAcks()
        }
    }
    
    private func flushAcks() {
        ackLock.lock()
        guard !pendingAcks.isEmpty else {
            ackLock.unlock()
            return
        }
        
        let acksToSend = Array(pendingAcks.prefix(100))
        pendingAcks.removeFirst(min(100, pendingAcks.count))
        ackLock.unlock()
        
        let ackMessage: [String: Any]
        if acksToSend.count == 1 {
            ackMessage = [
                "type": "ack",
                "eventId": acksToSend[0],
                "clientId": clientId
            ]
        } else {
            ackMessage = [
                "type": "batch_ack",
                "eventIds": acksToSend,
                "clientId": clientId
            ]
        }
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: ackMessage),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            send(message: jsonString) { [weak self] success in
                if success {
                    DispatchQueue.main.async {
                        self?.ackedCount += acksToSend.count
                    }
                    if acksToSend.count > 50 {
                        self?.logger.log("ACK", "✅ Sent ACK for \(acksToSend.count) events")
                    }
                } else {
                    self?.logger.logError("ACK", "Failed to send, re-queuing")
                    self?.ackLock.lock()
                    self?.pendingAcks.insert(contentsOf: acksToSend, at: 0)
                    self?.ackLock.unlock()
                }
            }
        }
    }
    
    private func startAckFlusher() {
        DispatchQueue.main.async { [weak self] in
            self?.ackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.flushAcks()
            }
        }
    }
    
    private func stopAckFlusher() {
        ackTimer?.invalidate()
        ackTimer = nil
        flushAcks()
    }
    
    // MARK: - Subscription Management
    func sendSubscriptionV2() {
        logger.log("SUBSCRIPTION", "sendSubscriptionV2 called")
        
        guard isConnected, webSocketTask != nil else {
            logger.logError("SUBSCRIPTION", "Cannot subscribe - not connected")
            return
        }
        
        let now = Date().timeIntervalSince1970
        if hasSubscribed && (now - lastSubscriptionTime) < 5.0 {
            logger.log("SUBSCRIPTION", "⚠️ Skipping duplicate subscription")
            return
        }
        
        let subscriptions = SubscriptionManager.shared.getSubscriptions()
        guard !subscriptions.isEmpty else {
            logger.logError("SUBSCRIPTION", "No subscriptions to send")
            return
        }
        
        logger.log("SUBSCRIPTION", "Subscribing to \(subscriptions.count) channels")
        
        let filters = subscriptions.map { sub in
            SubscriptionFilter(area: sub.area, eventType: sub.eventType)
        }
        
        // ✅ Enable catch-up mode for ALL channels
        subscriptions.forEach { sub in
            let channelId = "\(sub.area)_\(sub.eventType)"
            ChannelSyncState.shared.enableCatchUpMode(channelId: channelId)
            catchUpChannels.insert(channelId)
        }
        
        var syncState: [String: SyncStateInfo] = [:]
        
        for sub in subscriptions {
            let channelId = "\(sub.area)_\(sub.eventType)"
            if let info = ChannelSyncState.shared.getSyncInfo(channelId: channelId) {
                syncState[channelId] = SyncStateInfo(
                    lastEventId: info.lastEventId,
                    lastTimestamp: info.lastEventTimestamp,
                    lastSeq: info.highestSeq
                )
            } else {
                syncState[channelId] = SyncStateInfo(
                    lastEventId: nil,
                    lastTimestamp: 0,
                    lastSeq: 0
                )
            }
        }
        
        let hasAnySyncState = ChannelSyncState.shared.getAllSyncStates().count > 0
        let resetConsumers = !hasAnySyncState
        
        let request = SubscriptionRequest(
            clientId: clientId,
            filters: filters,
            syncState: syncState.isEmpty ? nil : syncState,
            resetConsumers: resetConsumers
        )
        
        guard let jsonData = try? JSONEncoder().encode(request),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.logError("SUBSCRIPTION", "Failed to encode request")
            return
        }
        
        logger.log("SUBSCRIPTION", "Sending: \(jsonString)")
        
        send(message: jsonString) { [weak self] success in
            if success {
                self?.hasSubscribed = true
                self?.lastSubscriptionTime = Date().timeIntervalSince1970
                self?.logger.log("SUBSCRIPTION", "✅ Subscription sent successfully")
                self?.startCatchUpMonitoring()
            } else {
                self?.logger.logError("SUBSCRIPTION", "Failed to send")
            }
        }
    }
    
    // MARK: - ✅ OPTIMIZED: Catch-up Monitoring
    
    private func startCatchUpMonitoring() {
        stopCatchUpMonitoring()
        
        DispatchQueue.main.async { [weak self] in
            self?.catchUpTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.checkCatchUpProgress()
            }
        }
    }
    
    private func stopCatchUpMonitoring() {
        catchUpTimer?.invalidate()
        catchUpTimer = nil
    }
    
    private func checkCatchUpProgress() {
        var allComplete = true
        
        for channelId in catchUpChannels {
            if ChannelSyncState.shared.isInCatchUpMode(channelId: channelId) {
                let progress = ChannelSyncState.shared.getCatchUpProgress(channelId: channelId)
                
                bufferLock.lock()
                let bufferEmpty = eventBuffer.count == 0
                bufferLock.unlock()
                
                if progress > 0 && bufferEmpty {
                    let count = (consecutiveEmptyChecks[channelId] ?? 0) + 1
                    consecutiveEmptyChecks[channelId] = count
                    
                    if count >= stableEmptyThreshold {
                        // ✅ Catch-up complete!
                        ChannelSyncState.shared.disableCatchUpMode(channelId: channelId)
                        catchUpChannels.remove(channelId)
                        consecutiveEmptyChecks.removeValue(forKey: channelId)
                        logger.log("CATCHUP", "✅ Complete for \(channelId) (\(progress) events)")
                        
                        // Final UI refresh for this channel
                        if let lastEvent = SubscriptionManager.shared.getLastEvent(channelId: channelId) {
                            DispatchQueue.main.async { [weak self] in
                                self?.broadcastEvent(lastEvent, channelId: channelId)
                            }
                        }
                    } else {
                        allComplete = false
                    }
                } else {
                    consecutiveEmptyChecks[channelId] = 0
                    allComplete = false
                }
            }
        }
        
        if allComplete && catchUpChannels.isEmpty {
            logger.log("CATCHUP", "🎉 ALL CHANNELS CAUGHT UP")
            stopCatchUpMonitoring()
            
            // Final UI update
            DispatchQueue.main.async { [weak self] in
                self?.flushUIUpdates()
                NotificationCenter.default.post(name: .catchUpComplete, object: nil)
            }
        }
    }
    
    // MARK: - Ping/Pong
    private func startPingPong() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: self.pingInterval, repeats: true) { [weak self] _ in
                self?.sendPing()
            }
        }
    }
    
    private func stopPingPong() {
        pingTimer?.invalidate()
        pingTimer = nil
    }
    
    private func sendPing() {
        webSocketTask?.sendPing { error in
            if let error = error {
                self.logger.logError("PING", "❌ Ping failed: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Reconnection
    private func scheduleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            connectionStatus = "Connection failed - Tap to retry"
            return
        }
        
        reconnectAttempts += 1
        let delay = reconnectDelay * Double(min(reconnectAttempts, 12))
        
        logger.log("RECONNECT", "Reconnecting in \(delay)s (attempt \(reconnectAttempts))")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }
    
    // MARK: - Message Sending
    private func send(message: String, completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completion?(false)
                return
            }
            
            let wsMessage = URLSessionWebSocketTask.Message.string(message)
            self.webSocketTask?.send(wsMessage) { error in
                if let error = error {
                    self.logger.logError("SEND", "Failed: \(error.localizedDescription)")
                    completion?(false)
                } else {
                    completion?(true)
                }
            }
        }
    }
    
    // MARK: - Stats Logging
    private func startStatsLogging() {
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.logStats()
        }
    }
    
    private func logStats() {
        guard isConnected else { return }
        
        bufferLock.lock()
        let bufferCount = eventBuffer.count
        bufferLock.unlock()
        
        logger.log("STATS", """
            Received: \(receivedCount), Buffered: \(bufferCount), 
            Processed: \(processedCount), Dropped: \(droppedCount), 
            Pending ACKs: \(pendingAcks.count)
            """)
        
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.logStats()
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let newEventReceived = Notification.Name("newEventReceived")
    static let subscriptionsUpdated = Notification.Name("subscriptionsUpdated")
    static let catchUpComplete = Notification.Name("catchUpComplete") // ✅ NEW
}