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
    
    // Event processing
    private let eventQueue = DispatchQueue(label: "com.iccc.eventQueue", attributes: .concurrent)
    private let processingQueue = DispatchQueue(label: "com.iccc.processing", qos: .userInitiated)
    private var eventBuffer: [String] = []
    private let bufferLock = NSLock()
    
    // ACK batching
    private var pendingAcks: [String] = []
    private let ackLock = NSLock()
    private let ackBatchSize = 50
    private var ackTimer: Timer?
    
    // Ping/Pong
    private var pingTimer: Timer?
    private let pingInterval: TimeInterval = 30.0
    
    // Catch-up monitoring
    private var catchUpChannels: Set<String> = []
    private var catchUpTimer: Timer?
    
    // Connection state tracking
    private var lastConnectionTime: Date?
    private var connectionLostTime: Date?
    
    private var hasSubscribed = false
    private var lastSubscriptionTime: TimeInterval = 0
    
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
                self.logger.log("WS_RECEIVE", "✅ Message received")
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
        switch message {
        case .string(let text):
            receivedCount += 1
            logger.log("MESSAGE", "📨 String message received (total: \(receivedCount))")
            logger.log("MESSAGE_RAW", "Content: \(text.prefix(200))...") // Log first 200 chars
            
            bufferLock.lock()
            eventBuffer.append(text)
            bufferLock.unlock()
            
            processingQueue.async { [weak self] in
                self?.processEvent(text)
            }
            
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                receivedCount += 1
                logger.log("MESSAGE", "📨 Data message received (total: \(receivedCount))")
                
                bufferLock.lock()
                eventBuffer.append(text)
                bufferLock.unlock()
                
                processingQueue.async { [weak self] in
                    self?.processEvent(text)
                }
            }
            
        @unknown default:
            logger.logError("MESSAGE", "Unknown message type")
            break
        }
    }
    
    // MARK: - Event Processing
    private func processEvent(_ text: String) {
        logger.log("PROCESS", "🔄 Processing event...")
        
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
            DispatchQueue.main.async {
                self.errorCount += 1
            }
            logger.logError("PROCESS", "❌ Received error message: \(text)")
            return
        }
        
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.logError("PROCESS", "Failed to parse JSON")
            DispatchQueue.main.async { self.droppedCount += 1 }
            return
        }
        
        guard let eventId = json["id"] as? String,
              let area = json["area"] as? String,
              let type = json["type"] as? String else {
            logger.logError("PROCESS", "Missing required fields: id/area/type")
            DispatchQueue.main.async { self.droppedCount += 1 }
            return
        }
        
        let channelId = "\(area)_\(type)"
        logger.log("PROCESS", "Event: id=\(eventId), channel=\(channelId)")
        
        let eventData = json["data"] as? [String: Any] ?? [:]
        let requireAck = eventData["_requireAck"] as? Bool ?? true
        
        // Check if subscribed
        guard SubscriptionManager.shared.isSubscribed(channelId: channelId) else {
            logger.log("PROCESS", "⏭️ Not subscribed to \(channelId), dropping")
            DispatchQueue.main.async { self.droppedCount += 1 }
            if requireAck { sendAck(eventId: eventId) }
            return
        }
        
        logger.log("PROCESS", "✅ Subscribed to \(channelId), processing...")
        
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
        
        // Record event in sync state
        let isNew = ChannelSyncState.shared.recordEventReceived(
            channelId: channelId,
            eventId: eventId,
            timestamp: timestamp,
            seq: sequence
        )
        
        logger.log("SYNC", "Sync check: isNew=\(isNew), seq=\(sequence)")
        
        // Duplicate check
        if !isNew && sequence > 0 {
            logger.log("PROCESS", "⏭️ Duplicate event \(eventId) (seq=\(sequence))")
            DispatchQueue.main.async { self.droppedCount += 1 }
            if requireAck { sendAck(eventId: eventId) }
            return
        }
        
        // Convert to Event object
        guard let event = parseEvent(json: json) else {
            logger.logError("PROCESS", "Failed to parse event object")
            DispatchQueue.main.async { self.droppedCount += 1 }
            return
        }
        
        logger.logEvent(event, action: "PARSED EVENT")
        
        // ✅ CRITICAL: Add to subscription manager
        let added = SubscriptionManager.shared.addEvent(event: event)
        
        logger.log("STORAGE", "Storage result: added=\(added)")
        
        if added {
            DispatchQueue.main.async {
                self.processedCount += 1
                self.logger.log("SUCCESS", "✅ Event \(eventId) processed successfully (total: \(self.processedCount))")
                self.sendLocalNotification(for: event, channelId: channelId)
            }
            
            // ✅ CRITICAL: Post notification for UI update
            logger.log("BROADCAST", "📡 Broadcasting event to UI...")
            NotificationCenter.default.post(
                name: .newEventReceived,
                object: nil,
                userInfo: ["event": event, "channelId": channelId]
            )
            
            logger.log("BROADCAST", "✅ Event broadcast complete")
            
        } else {
            logger.log("STORAGE", "⚠️ Event \(eventId) was NOT added (duplicate?)")
            DispatchQueue.main.async { self.droppedCount += 1 }
        }
        
        // Send ACK
        if requireAck {
            sendAck(eventId: eventId)
        }
        
        // Log current state
        DispatchQueue.main.async { [weak self] in
            self?.logger.logChannelEvents()
        }
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
            } else {
                self.logger.log("NOTIFICATION", "✅ Notification sent for \(event.id ?? "?")")
            }
        }
    }
    
    private func parseEvent(json: [String: Any]) -> Event? {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json),
              let event = try? JSONDecoder().decode(Event.self, from: jsonData) else {
            return nil
        }
        return event
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
                    if acksToSend.count > 10 {
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
        
        // Enable catch-up mode
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
    
    // MARK: - Catch-up Monitoring
    private func startCatchUpMonitoring() {
        stopCatchUpMonitoring()
        
        DispatchQueue.main.async { [weak self] in
            self?.catchUpTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
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
                
                if progress > 0 {
                    bufferLock.lock()
                    let isQueueEmpty = eventBuffer.isEmpty
                    bufferLock.unlock()
                    
                    if isQueueEmpty {
                        ChannelSyncState.shared.disableCatchUpMode(channelId: channelId)
                        catchUpChannels.remove(channelId)
                        logger.log("CATCHUP", "✅ Complete for \(channelId) (\(progress) events)")
                    } else {
                        allComplete = false
                    }
                } else {
                    allComplete = false
                }
            }
        }
        
        if allComplete {
            logger.log("CATCHUP", "🎉 ALL CHANNELS CAUGHT UP")
            stopCatchUpMonitoring()
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
        
        logger.logWebSocketStatus()
        logger.logChannelEvents()
        
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.logStats()
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let newEventReceived = Notification.Name("newEventReceived")
    static let subscriptionsUpdated = Notification.Name("subscriptionsUpdated")
}