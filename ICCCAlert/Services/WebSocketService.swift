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
    
    // ✅ FIX 1: Single serial queue for ALL operations
    private let processingQueue = DispatchQueue(label: "com.iccc.processing", qos: .userInitiated)
    
    // ✅ FIX 2: Simple buffer without complex locking
    private var eventBuffer: [String] = []
    
    // ✅ FIX 3: Processing state without deadlock risk
    private var isProcessingEvents = false
    
    // ACK batching
    private var pendingAcks: [String] = []
    private let ackBatchSize = 50
    private var ackTimer: Timer?
    
    // Ping/Pong
    private var pingTimer: Timer?
    private let pingInterval: TimeInterval = 30.0
    
    // ✅ FIX 4: Proper catch-up monitoring
    private var catchUpChannels: Set<String> = []
    private var catchUpTimer: Timer?
    private let catchUpCheckInterval: TimeInterval = 3.0
    private var consecutiveEmptyChecks: [String: Int] = [:]
    private let stableEmptyThreshold = 2
    
    // Connection state tracking
    private var lastConnectionTime: Date?
    private var hasSubscribed = false
    private var lastSubscriptionTime: TimeInterval = 0
    
    private var cancellables = Set<AnyCancellable>()
    private let logger = DebugLogger.shared
    
    // ✅ FIX 5: Separate live event queue for immediate processing
    private var liveEventQueue: [String] = []
    
    // MARK: - Initialization
    private init() {
        logger.log("INIT", "WebSocketService initializing...")
        setupClientId()
        setupSession()
        logger.log("INIT", "WebSocketService initialized with clientId: \(clientId)")
    }
    
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
        
        DispatchQueue.main.async { [weak self] in
            self?.connectionStatus = "Connecting..."
        }
        
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        isConnected = true
        reconnectAttempts = 0
        lastConnectionTime = Date()
        
        DispatchQueue.main.async { [weak self] in
            self?.connectionStatus = "Connected - Monitoring alerts"
        }
        
        logger.logWebSocket("✅ WebSocket connected, starting receivers...")
        
        startReceiving()
        startPingPong()
        startAckFlusher()
        startEventProcessor()
        startStatsLogging()
        
        // Send subscription immediately after connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendSubscriptionV2()
        }
    }
    
    func disconnect() {
        logger.logWebSocket("Disconnecting...")
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        hasSubscribed = false
        
        DispatchQueue.main.async { [weak self] in
            self?.connectionStatus = "Disconnected"
        }
        
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
                self.handleMessage(message)
                self.receiveMessage() // Continue receiving
                
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
        
        // ✅ FIX 6: Add to buffer on serial queue (no locks needed)
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Check if any channel is in catch-up mode
            let inCatchUpMode = SubscriptionManager.shared.subscribedChannels.contains { channel in
                ChannelSyncState.shared.isInCatchUpMode(channelId: channel.id)
            }
            
            if inCatchUpMode {
                self.eventBuffer.append(messageText)
            } else {
                // Live mode - prioritize immediate processing
                self.liveEventQueue.append(messageText)
            }
        }
    }
    
    // ✅ FIX 7: Single processor with priority handling
    private func startEventProcessor() {
        processingQueue.async { [weak self] in
            self?.eventProcessorLoop()
        }
    }
    
    // ✅ FIX 8: Non-blocking processor with live event priority
    private func eventProcessorLoop() {
        while isConnected {
            autoreleasepool {
                // Check if already processing
                guard !isProcessingEvents else {
                    Thread.sleep(forTimeInterval: 0.01)
                    return
                }
                
                isProcessingEvents = true
                defer { isProcessingEvents = false }
                
                // ✅ PRIORITY 1: Process live events first
                if !liveEventQueue.isEmpty {
                    let messageText = liveEventQueue.removeFirst()
                    processEvent(messageText, isLive: true)
                    return
                }
                
                // ✅ PRIORITY 2: Process catch-up events
                if !eventBuffer.isEmpty {
                    let messageText = eventBuffer.removeFirst()
                    processEvent(messageText, isLive: false)
                    return
                }
                
                // No events, sleep briefly
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }
    
    // ✅ FIX 9: Streamlined event processing with live mode flag
    private func processEvent(_ text: String, isLive: Bool) {
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
        let sequence: Int64 = {
            guard let seqValue = eventData["_seq"] else { return 0 }
            if let seqNum = seqValue as? Int64 { return seqNum }
            if let seqStr = seqValue as? String, let seqNum = Int64(seqStr) { return seqNum }
            if let seqInt = seqValue as? Int { return Int64(seqInt) }
            return 0
        }()
        
        let timestamp = json["timestamp"] as? Int64 ?? 0
        
        // ✅ Record in sync state FIRST
        let isNew = ChannelSyncState.shared.recordEventReceived(
            channelId: channelId,
            eventId: eventId,
            timestamp: timestamp,
            seq: sequence
        )
        
        if !isNew && sequence > 0 {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
            if requireAck { sendAck(eventId: eventId) }
            return
        }
        
        // Parse event
        guard let event = parseEvent(json: json) else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
            return
        }
        
        // ✅ CRITICAL: Add to storage
        let added = SubscriptionManager.shared.addEvent(event: event)
        
        if added {
            DispatchQueue.main.async { [weak self] in
                self?.processedCount += 1
            }
            
            // ✅ FIX 10: For live events, send notification immediately
            if isLive {
                DispatchQueue.main.async { [weak self] in
                    self?.broadcastEvent(event, channelId: channelId)
                    self?.sendLocalNotification(for: event, channelId: channelId)
                }
            } else {
                // Catch-up events - broadcast only (batch notifications)
                DispatchQueue.main.async { [weak self] in
                    self?.broadcastEvent(event, channelId: channelId)
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
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingAcks.append(eventId)
            
            if self.pendingAcks.count >= self.ackBatchSize {
                self.flushAcks()
            }
        }
    }
    
    private func flushAcks() {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.pendingAcks.isEmpty else { return }
            
            let acksToSend = Array(self.pendingAcks.prefix(100))
            self.pendingAcks.removeFirst(min(100, self.pendingAcks.count))
            
            let ackMessage: [String: Any]
            if acksToSend.count == 1 {
                ackMessage = [
                    "type": "ack",
                    "eventId": acksToSend[0],
                    "clientId": self.clientId
                ]
            } else {
                ackMessage = [
                    "type": "batch_ack",
                    "eventIds": acksToSend,
                    "clientId": self.clientId
                ]
            }
            
            if let jsonData = try? JSONSerialization.data(withJSONObject: ackMessage),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                self.send(message: jsonString) { [weak self] success in
                    if success {
                        DispatchQueue.main.async {
                            self?.ackedCount += acksToSend.count
                        }
                    } else {
                        self?.logger.logError("ACK", "Failed to send, re-queuing")
                        self?.processingQueue.async {
                            self?.pendingAcks.insert(contentsOf: acksToSend, at: 0)
                        }
                    }
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
    
    // MARK: - Catch-up Monitoring
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
        
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            for channelId in self.catchUpChannels {
                if ChannelSyncState.shared.isInCatchUpMode(channelId: channelId) {
                    let progress = ChannelSyncState.shared.getCatchUpProgress(channelId: channelId)
                    
                    let bufferEmpty = self.eventBuffer.isEmpty
                    let notProcessing = !self.isProcessingEvents
                    
                    if progress > 0 && bufferEmpty && notProcessing {
                        let count = (self.consecutiveEmptyChecks[channelId] ?? 0) + 1
                        self.consecutiveEmptyChecks[channelId] = count
                        
                        if count >= self.stableEmptyThreshold {
                            ChannelSyncState.shared.disableCatchUpMode(channelId: channelId)
                            self.catchUpChannels.remove(channelId)
                            self.consecutiveEmptyChecks.removeValue(forKey: channelId)
                            self.logger.log("CATCHUP", "✅ Complete for \(channelId) (\(progress) events)")
                            
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(name: .catchUpComplete, object: nil)
                            }
                        } else {
                            allComplete = false
                        }
                    } else {
                        self.consecutiveEmptyChecks[channelId] = 0
                        allComplete = false
                    }
                }
            }
            
            if allComplete && self.catchUpChannels.isEmpty {
                self.logger.log("CATCHUP", "🎉 ALL CHANNELS CAUGHT UP")
                DispatchQueue.main.async { [weak self] in
                    self?.stopCatchUpMonitoring()
                }
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
        
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            let bufferCount = self.eventBuffer.count
            let liveCount = self.liveEventQueue.count
            let pendingAckCount = self.pendingAcks.count
            
            self.logger.log("STATS", """
                Received: \(self.receivedCount), Buffered: \(bufferCount), Live: \(liveCount),
                Processed: \(self.processedCount), Dropped: \(self.droppedCount), 
                Pending ACKs: \(pendingAckCount)
                """)
        }
        
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.logStats()
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let newEventReceived = Notification.Name("newEventReceived")
    static let subscriptionsUpdated = Notification.Name("subscriptionsUpdated")
    static let catchUpComplete = Notification.Name("catchUpComplete")
}