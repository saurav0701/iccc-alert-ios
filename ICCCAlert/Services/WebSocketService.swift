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
    
    // ✅ FIX 1: Serial queue for ALL operations - prevents race conditions
    private let serialQueue = DispatchQueue(label: "com.iccc.websocket.serial", qos: .userInitiated)
    
    // ✅ FIX 2: Separate queues for different priorities
    private var liveEventQueue: [String] = []      // Live events - process immediately
    private var catchupEventQueue: [String] = []   // Catch-up events - batch process
    
    // ✅ FIX 3: Processing control - prevent concurrent processing
    private var isProcessing = false
    private var processingTimer: Timer?
    
    // ACK batching
    private var pendingAcks: [String] = []
    private let ackBatchSize = 100  // Increased for bulk operations
    private var ackTimer: Timer?
    
    // Ping/Pong
    private var pingTimer: Timer?
    private let pingInterval: TimeInterval = 30.0
    
    // ✅ FIX 4: Proper catch-up state tracking
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
    
    // ✅ FIX 5: Background task for processing
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    // MARK: - Initialization
    private init() {
        logger.log("INIT", "WebSocketService initializing...")
        setupClientId()
        setupSession()
        setupNotificationObservers()
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
    
    // ✅ FIX 6: Setup app lifecycle observers
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    @objc private func appDidEnterBackground() {
        logger.log("LIFECYCLE", "App entering background")
        
        // Start background task
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
        
        // Force save state
        SubscriptionManager.shared.forceSave()
        ChannelSyncState.shared.forceSave()
    }
    
    @objc private func appWillEnterForeground() {
        logger.log("LIFECYCLE", "App entering foreground")
    }
    
    @objc private func appDidBecomeActive() {
        logger.log("LIFECYCLE", "App became active")
        
        // End background task
        endBackgroundTask()
        
        // Reconnect if disconnected
        if !isConnected {
            logger.log("LIFECYCLE", "Reconnecting after foreground...")
            connect()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    
    // MARK: - Connection Management
    func connect() {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            
            if self.isConnected && self.webSocketTask != nil {
                self.logger.logWebSocket("⚠️ Already connected, skipping connect")
                return
            }
            
            self.disconnect()
            
            guard let url = URL(string: self.wsURL) else {
                self.logger.logError("CONNECT", "Invalid WebSocket URL: \(self.wsURL)")
                return
            }
            
            self.logger.logWebSocket("🔌 Connecting to \(self.wsURL) with client ID: \(self.clientId)")
            
            DispatchQueue.main.async {
                self.connectionStatus = "Connecting..."
            }
            
            self.webSocketTask = self.session?.webSocketTask(with: url)
            self.webSocketTask?.resume()
            
            self.isConnected = true
            self.reconnectAttempts = 0
            self.lastConnectionTime = Date()
            
            DispatchQueue.main.async {
                self.connectionStatus = "Connected - Monitoring alerts"
            }
            
            self.logger.logWebSocket("✅ WebSocket connected, starting receivers...")
            
            self.startReceiving()
            self.startPingPong()
            self.startAckFlusher()
            self.startEventProcessor()
            self.startStatsLogging()
            
            // ✅ FIX 7: Send subscription after connection is established
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.sendSubscriptionV2()
            }
        }
    }
    
    func disconnect() {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.logger.logWebSocket("Disconnecting...")
            self.webSocketTask?.cancel(with: .goingAway, reason: nil)
            self.webSocketTask = nil
            self.isConnected = false
            self.hasSubscribed = false
            
            DispatchQueue.main.async {
                self.connectionStatus = "Disconnected"
            }
            
            self.stopPingPong()
            self.stopAckFlusher()
            self.stopEventProcessor()
            self.stopCatchUpMonitoring()
            
            self.logger.logWebSocket("🔌 WebSocket disconnected")
        }
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
                
                self.serialQueue.async {
                    self.isConnected = false
                    self.hasSubscribed = false
                    
                    DispatchQueue.main.async {
                        self.connectionStatus = "Disconnected - Reconnecting..."
                        self.scheduleReconnect()
                    }
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
        
        // ✅ FIX 8: Route messages to appropriate queue
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Check if any channel is in catch-up mode
            let inCatchUpMode = SubscriptionManager.shared.subscribedChannels.contains { channel in
                ChannelSyncState.shared.isInCatchUpMode(channelId: channel.id)
            }
            
            if inCatchUpMode {
                // During catch-up: queue for batch processing
                self.catchupEventQueue.append(messageText)
            } else {
                // Live mode: queue for immediate processing
                self.liveEventQueue.append(messageText)
            }
        }
    }
    
    // ✅ FIX 9: Single event processor with priority handling
    private func startEventProcessor() {
        stopEventProcessor()
        
        processingTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            self?.processNextEvent()
        }
        
        RunLoop.current.add(processingTimer!, forMode: .common)
    }
    
    private func stopEventProcessor() {
        processingTimer?.invalidate()
        processingTimer = nil
    }
    
    // ✅ FIX 10: Process events with priority - live first, then catch-up
    private func processNextEvent() {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Prevent concurrent processing
            guard !self.isProcessing else { return }
            
            self.isProcessing = true
            defer { self.isProcessing = false }
            
            // Priority 1: Process live events immediately
            if !self.liveEventQueue.isEmpty {
                let messageText = self.liveEventQueue.removeFirst()
                self.processEvent(messageText, isLive: true)
                return
            }
            
            // Priority 2: Process catch-up events in batches
            if !self.catchupEventQueue.isEmpty {
                let messageText = self.catchupEventQueue.removeFirst()
                self.processEvent(messageText, isLive: false)
                return
            }
        }
    }
    
    // ✅ FIX 11: Streamlined event processing - NO BLOCKING
    private func processEvent(_ text: String, isLive: Bool) {
        // Skip subscription confirmations
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
        
        // Parse JSON
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
            return
        }
        
        // Extract event data
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
        
        // Check subscription
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
        
        // ✅ CRITICAL: Record in sync state FIRST
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
        
        // ✅ CRITICAL: Add to storage (this is FAST - no blocking)
        let added = SubscriptionManager.shared.addEvent(event: event)
        
        if added {
            DispatchQueue.main.async { [weak self] in
                self?.processedCount += 1
            }
            
            // ✅ FIX 12: For live events, send notification immediately
            if isLive {
                DispatchQueue.main.async { [weak self] in
                    self?.broadcastEvent(event, channelId: channelId)
                    self?.sendLocalNotification(for: event, channelId: channelId)
                }
            } else {
                // Catch-up events - broadcast only (no notifications)
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
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingAcks.append(eventId)
            
            if self.pendingAcks.count >= self.ackBatchSize {
                self.flushAcks()
            }
        }
    }
    
    private func flushAcks() {
        serialQueue.async { [weak self] in
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
                        self?.serialQueue.async {
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
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard self.isConnected, self.webSocketTask != nil else {
                self.logger.logError("SUBSCRIPTION", "Cannot subscribe - not connected")
                return
            }
            
            let now = Date().timeIntervalSince1970
            if self.hasSubscribed && (now - self.lastSubscriptionTime) < 5.0 {
                self.logger.log("SUBSCRIPTION", "⚠️ Skipping duplicate subscription")
                return
            }
            
            let subscriptions = SubscriptionManager.shared.getSubscriptions()
            guard !subscriptions.isEmpty else {
                self.logger.logError("SUBSCRIPTION", "No subscriptions to send")
                return
            }
            
            self.logger.log("SUBSCRIPTION", "Subscribing to \(subscriptions.count) channels")
            
            let filters = subscriptions.map { sub in
                SubscriptionFilter(area: sub.area, eventType: sub.eventType)
            }
            
            // ✅ Enable catch-up mode for ALL channels
            subscriptions.forEach { sub in
                let channelId = "\(sub.area)_\(sub.eventType)"
                ChannelSyncState.shared.enableCatchUpMode(channelId: channelId)
                self.catchUpChannels.insert(channelId)
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
                clientId: self.clientId,
                filters: filters,
                syncState: syncState.isEmpty ? nil : syncState,
                resetConsumers: resetConsumers
            )
            
            guard let jsonData = try? JSONEncoder().encode(request),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                self.logger.logError("SUBSCRIPTION", "Failed to encode request")
                return
            }
            
            self.logger.log("SUBSCRIPTION", "Sending: \(jsonString)")
            
            self.send(message: jsonString) { [weak self] success in
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
        
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            
            for channelId in self.catchUpChannels {
                if ChannelSyncState.shared.isInCatchUpMode(channelId: channelId) {
                    let progress = ChannelSyncState.shared.getCatchUpProgress(channelId: channelId)
                    
                    let queueEmpty = self.catchupEventQueue.isEmpty
                    let notProcessing = !self.isProcessing
                    
                    if progress > 0 && queueEmpty && notProcessing {
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
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard self.reconnectAttempts < self.maxReconnectAttempts else {
                DispatchQueue.main.async {
                    self.connectionStatus = "Connection failed - Tap to retry"
                }
                return
            }
            
            self.reconnectAttempts += 1
            let delay = self.reconnectDelay * Double(min(self.reconnectAttempts, 12))
            
            self.logger.log("RECONNECT", "Reconnecting in \(delay)s (attempt \(self.reconnectAttempts))")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.connect()
            }
        }
    }
    
    // MARK: - Message Sending
    private func send(message: String, completion: ((Bool) -> Void)? = nil) {
        let wsMessage = URLSessionWebSocketTask.Message.string(message)
        webSocketTask?.send(wsMessage) { error in
            if let error = error {
                self.logger.logError("SEND", "Failed: \(error.localizedDescription)")
                completion?(false)
            } else {
                completion?(true)
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
        
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            
            let liveCount = self.liveEventQueue.count
            let catchupCount = self.catchupEventQueue.count
            let pendingAckCount = self.pendingAcks.count
            
            self.logger.log("STATS", """
                Received: \(self.receivedCount), Live: \(liveCount), Catchup: \(catchupCount),
                Processed: \(self.processedCount), Dropped: \(self.droppedCount), 
                Pending ACKs: \(pendingAckCount)
                """)
        }
        
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.logStats()
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        endBackgroundTask()
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let newEventReceived = Notification.Name("newEventReceived")
    static let subscriptionsUpdated = Notification.Name("subscriptionsUpdated")
    static let catchUpComplete = Notification.Name("catchUpComplete")
}