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
    
    // ✅ CRITICAL FIX: Separate queues like Android
    private let eventQueue = DispatchQueue(label: "com.iccc.eventProcessing", qos: .userInitiated, attributes: .concurrent)
    private let ackQueue = DispatchQueue(label: "com.iccc.ackProcessing", qos: .utility)
    private let messageQueue = DispatchQueue(label: "com.iccc.messages")
    
    // ✅ CRITICAL FIX: Concurrent processing like Android (4 processors)
    private let processorCount = 4
    private var processingJobs: [DispatchWorkItem] = []
    private var pendingMessages: [String] = []
    private let processorLock = NSLock()
    private var activeProcessors = 0
    
    // ✅ CRITICAL FIX: Notification batching to prevent UI hang
    private var notificationQueue: [Event] = []
    private var notificationBatchTimer: Timer?
    private let notificationBatchDelay: TimeInterval = 0.5
    
    // ACK batching
    private var pendingAcks: [String] = []
    private let ackBatchSize = 50
    private var ackTimer: Timer?
    
    // Ping/Pong
    private var pingTimer: Timer?
    private let pingInterval: TimeInterval = 30.0
    
    // Catch-up monitoring
    private var catchUpChannels: Set<String> = []
    private var catchUpTimer: Timer?
    private let catchUpCheckInterval: TimeInterval = 5.0
    private var consecutiveEmptyChecks: [String: Int] = [:]
    private let stableEmptyThreshold = 3
    private var catchUpStartTime: [String: Date] = [:]
    private let maxCatchUpDuration: TimeInterval = 30.0
    
    // Connection state
    private var lastConnectionTime: Date?
    private var hasSubscribed = false
    private var lastSubscriptionTime: TimeInterval = 0
    
    private var cancellables = Set<AnyCancellable>()
    private let logger = DebugLogger.shared
    
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
        logger.log("CONNECT", "Connect called - isConnected=\(isConnected)")
        
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
        startEventProcessors() // ✅ Start concurrent processors
        startNotificationBatcher() // ✅ Batch notifications
        startStatsLogging()
        
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
        
        // Cancel all processing jobs
        processingJobs.forEach { $0.cancel() }
        processingJobs.removeAll()
        
        DispatchQueue.main.async { [weak self] in
            self?.connectionStatus = "Disconnected"
        }
        
        stopPingPong()
        stopAckFlusher()
        stopNotificationBatcher()
        
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
        
        // ✅ CRITICAL FIX: Queue message for background processing
        messageQueue.async { [weak self] in
            self?.pendingMessages.append(messageText)
        }
    }
    
    // ✅ CRITICAL FIX: Start concurrent processors (like Android)
    private func startEventProcessors() {
        for i in 0..<processorCount {
            let workItem = DispatchWorkItem { [weak self] in
                self?.processEventsLoop(processorId: i)
            }
            processingJobs.append(workItem)
            eventQueue.async(execute: workItem)
        }
        logger.log("PROCESSORS", "✅ Started \(processorCount) concurrent processors")
    }
    
    // ✅ CRITICAL FIX: Background processing loop (never blocks main thread)
    private func processEventsLoop(processorId: Int) {
        while isConnected {
            autoreleasepool {
                var message: String?
                
                messageQueue.sync {
                    if !pendingMessages.isEmpty {
                        message = pendingMessages.removeFirst()
                    }
                }
                
                if let msg = message {
                    processorLock.lock()
                    activeProcessors += 1
                    processorLock.unlock()
                    
                    processEvent(msg)
                    
                    processorLock.lock()
                    activeProcessors -= 1
                    processorLock.unlock()
                } else {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
        }
    }
    
    // ✅ CRITICAL FIX: Streamlined event processing (minimal work on background thread)
    private func processEvent(_ text: String) {
        // Check subscription confirmation
        if text.contains("\"status\":\"subscribed\"") || text.contains("\"status\":\"ok\"") {
            DispatchQueue.main.async { [weak self] in
                self?.hasSubscribed = true
                self?.logger.logWebSocket("✅ Subscription confirmed by server")
            }
            
            // Check if backend says we're caught up
            if let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let consumers = json["consumers"] as? [[String: Any]] {
                
                for consumer in consumers {
                    if let numPending = consumer["numPending"] as? Int,
                       let filterArea = consumer["filterArea"] as? String,
                       let filterEventType = consumer["filterEventType"] as? String {
                        
                        let channelId = "\(filterArea)_\(filterEventType)"
                        
                        if numPending == 0 {
                            logger.log("CATCHUP", "⚡ \(channelId): numPending=0, disabling catch-up immediately")
                            ChannelSyncState.shared.disableCatchUpMode(channelId: channelId)
                            catchUpChannels.remove(channelId)
                            consecutiveEmptyChecks.removeValue(forKey: channelId)
                        }
                    }
                }
            }
            return
        }
        
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
        
        guard SubscriptionManager.shared.isSubscribed(channelId: channelId) else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
            if requireAck { sendAck(eventId: eventId) }
            return
        }
        
        let sequence: Int64 = {
            guard let seqValue = eventData["_seq"] else { return 0 }
            if let seqNum = seqValue as? Int64 { return seqNum }
            if let seqStr = seqValue as? String, let seqNum = Int64(seqStr) { return seqNum }
            if let seqInt = seqValue as? Int { return Int64(seqInt) }
            return 0
        }()
        
        let timestamp = json["timestamp"] as? Int64 ?? 0
        
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
        
        guard let event = parseEvent(json: json) else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
            return
        }
        
        let added = SubscriptionManager.shared.addEvent(event: event)
        
        if added {
            DispatchQueue.main.async { [weak self] in
                self?.processedCount += 1
            }
            
            let inCatchUpMode = ChannelSyncState.shared.isInCatchUpMode(channelId: channelId)
            
            // ✅ CRITICAL FIX: Always broadcast and send notifications (no catch-up mode)
            DispatchQueue.main.async { [weak self] in
                self?.broadcastEvent(event, channelId: channelId)
            }
            
            // ✅ Always send notifications in real-time
            queueNotification(for: event, channelId: channelId)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
        }
        
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
    
    // ✅ CRITICAL FIX: Queue notifications for batching
    private func queueNotification(for event: Event, channelId: String) {
        messageQueue.async { [weak self] in
            self?.notificationQueue.append(event)
        }
    }
    
    // ✅ CRITICAL FIX: Batch notifications to prevent UI hang
    private func startNotificationBatcher() {
        DispatchQueue.main.async { [weak self] in
            self?.notificationBatchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.processNotificationBatch()
            }
        }
    }
    
    private func stopNotificationBatcher() {
        notificationBatchTimer?.invalidate()
        notificationBatchTimer = nil
    }
    
    // ✅ CRITICAL FIX: Process notifications in batches
    private func processNotificationBatch() {
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            
            let batch = self.notificationQueue
            self.notificationQueue.removeAll()
            
            if batch.isEmpty { return }
            
            // Group by channel and only send latest per channel
            let latestPerChannel = Dictionary(grouping: batch, by: { "\($0.area ?? "")_\($0.type ?? "")" })
                .mapValues { $0.last! }
            
            DispatchQueue.main.async {
                for event in latestPerChannel.values {
                    self.sendLocalNotification(for: event)
                }
            }
        }
    }
    
    private func sendLocalNotification(for event: Event) {
        let channelId = "\(event.area ?? "")_\(event.type ?? "")"
        
        if SubscriptionManager.shared.isChannelMuted(channelId: channelId) {
            return
        }
        
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
        ackQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingAcks.append(eventId)
            
            if self.pendingAcks.count >= self.ackBatchSize {
                self.flushAcks()
            }
        }
    }
    
    private func flushAcks() {
        ackQueue.async { [weak self] in
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
                        self?.ackQueue.async {
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
        logger.log("SUBSCRIPTION", "🔵 sendSubscriptionV2 called")
        
        guard isConnected, webSocketTask != nil else {
            logger.logError("SUBSCRIPTION", "❌ Cannot subscribe - not connected")
            return
        }
        
        let subscriptions = SubscriptionManager.shared.getSubscriptions()
        logger.log("SUBSCRIPTION", "🔵 Found \(subscriptions.count) subscriptions")
        
        guard !subscriptions.isEmpty else {
            logger.logError("SUBSCRIPTION", "❌ No subscriptions to send")
            return
        }
        
        logger.log("SUBSCRIPTION", "✅ Subscribing to \(subscriptions.count) channels")
        
        let filters = subscriptions.map { sub in
            SubscriptionFilter(area: sub.area, eventType: sub.eventType)
        }
        
        subscriptions.forEach { sub in
            let channelId = "\(sub.area)_\(sub.eventType)"
            ChannelSyncState.shared.enableCatchUpMode(channelId: channelId)
            catchUpChannels.insert(channelId)
            catchUpStartTime[channelId] = Date()
        }
        
        var syncState: [String: SyncStateInfo] = [:]
        
        // ✅ DISABLED: No sync state - always start fresh for live events
        for sub in subscriptions {
            let channelId = "\(sub.area)_\(sub.eventType)"
            syncState[channelId] = SyncStateInfo(
                lastEventId: nil,
                lastTimestamp: 0,
                lastSeq: 0
            )
        }
        
        // ✅ CRITICAL: Always reset consumers for fresh start
        let resetConsumers = true
        
        let request = SubscriptionRequest(
            clientId: clientId,
            filters: filters,
            syncState: syncState.isEmpty ? nil : syncState,
            resetConsumers: resetConsumers
        )
        
        guard let jsonData = try? JSONEncoder().encode(request),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.logError("SUBSCRIPTION", "❌ Failed to encode request")
            return
        }
        
        send(message: jsonString) { [weak self] success in
            guard let self = self else { return }
            if success {
                self.hasSubscribed = true
                self.lastSubscriptionTime = Date().timeIntervalSince1970
                self.logger.log("SUBSCRIPTION", "✅✅✅ Subscription SENT - LIVE MODE ONLY")
                // ✅ DISABLED: No catch-up monitoring
            } else {
                self.logger.logError("SUBSCRIPTION", "❌❌❌ Failed to SEND subscription")
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
        
        var queueCount = 0
        messageQueue.sync {
            queueCount = pendingMessages.count
        }
        
        var pendingAckCount = 0
        ackQueue.sync {
            pendingAckCount = pendingAcks.count
        }
        
        logger.log("STATS", """
            Received: \(receivedCount), Queued: \(queueCount),
            Processed: \(processedCount), Dropped: \(droppedCount), 
            Pending ACKs: \(pendingAckCount)
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
    static let catchUpComplete = Notification.Name("catchUpComplete")
}