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
    
    // ✅ CRITICAL FIX: Use serial queue for WebSocket operations
    private let wsQueue = DispatchQueue(label: "com.iccc.websocket", qos: .userInitiated)
    
    // Processing queue for events
    private let processingQueue = DispatchQueue(label: "com.iccc.processing", qos: .userInitiated)
    
    // ✅ REMOVED: ACK system completely disabled for now
    
    // Ping/Pong
    private var pingTimer: Timer?
    private let pingInterval: TimeInterval = 30.0
    
    // Connection state
    private var hasSubscribed = AtomicBoolean(false)
    
    private var cancellables = Set<AnyCancellable>()
    private let logger = DebugLogger.shared
    
    // ✅ NEW: Track last successful event to detect hangs
    private var lastEventTime = Date()
    private var hangDetectionTimer: Timer?
    
    // MARK: - Initialization
    private init() {
        logger.log("INIT", "WebSocketService initializing...")
        setupClientId()
        setupSession()
        startHangDetection()
    }
    
    private func setupClientId() {
        clientId = KeychainClientID.getOrCreateClientID()
        logger.log("CLIENT_ID", "Using: \(clientId)")
        UserDefaults.standard.set(clientId, forKey: "persistent_client_id")
    }
    
    private func setupSession() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 0
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }
    
    // ✅ NEW: Detect when no events are coming through
    private func startHangDetection() {
        DispatchQueue.main.async { [weak self] in
            self?.hangDetectionTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                
                let timeSinceLastEvent = Date().timeIntervalSince(self.lastEventTime)
                
                if self.isConnected && timeSinceLastEvent > 30 {
                    self.logger.logWarning("HANG", "No events for \(Int(timeSinceLastEvent))s - connection may be hung")
                    
                    // Force reconnect if hung for >60s
                    if timeSinceLastEvent > 60 {
                        self.logger.logError("HANG", "Forcing reconnect due to hang")
                        self.disconnect()
                        self.connect()
                    }
                }
            }
        }
    }
    
    // MARK: - Connection Management
    func connect() {
        logger.log("CONNECT", "Connect called - isConnected=\(isConnected)")
        
        if isConnected && webSocketTask != nil {
            logger.logWebSocket("⚠️ Already connected, skipping")
            return
        }
        
        disconnect()
        
        guard let url = URL(string: wsURL) else {
            logger.logError("CONNECT", "Invalid URL: \(wsURL)")
            return
        }
        
        logger.logWebSocket("🔌 Connecting to \(wsURL)")
        
        DispatchQueue.main.async { [weak self] in
            self?.connectionStatus = "Connecting..."
        }
        
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        isConnected = true
        reconnectAttempts = 0
        lastEventTime = Date() // Reset hang detector
        
        DispatchQueue.main.async { [weak self] in
            self?.connectionStatus = "Connected - Monitoring alerts"
        }
        
        logger.logWebSocket("✅ Connected, starting receivers...")
        
        startReceiving()
        startPingPong()
        startStatsLogging()
        
        // ✅ Send subscription immediately
        wsQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendSubscriptionV2()
        }
    }
    
    func disconnect() {
        logger.logWebSocket("Disconnecting...")
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        hasSubscribed.value = false
        
        DispatchQueue.main.async { [weak self] in
            self?.connectionStatus = "Disconnected"
        }
        
        stopPingPong()
        
        logger.logWebSocket("🔌 Disconnected")
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
                self.logger.logError("WS_RECEIVE", "❌ Error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.hasSubscribed.value = false
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
        
        // ✅ Update counter on main thread
        DispatchQueue.main.async { [weak self] in
            self?.receivedCount += 1
        }
        
        // ✅ Process on background thread
        processingQueue.async { [weak self] in
            self?.processEvent(messageText)
        }
    }
    
    // ✅ CRITICAL FIX: Simplified event processing - NO ACK
    private func processEvent(_ text: String) {
        // Check subscription confirmation
        if text.contains("\"status\":\"subscribed\"") || text.contains("\"status\":\"ok\"") {
            DispatchQueue.main.async { [weak self] in
                self?.hasSubscribed.value = true
                self?.logger.logWebSocket("✅ Subscription confirmed")
            }
            return
        }
        
        if text.contains("\"error\"") {
            DispatchQueue.main.async { [weak self] in
                self?.errorCount += 1
            }
            logger.logError("EVENT", "Error in message: \(text)")
            return
        }
        
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
            logger.logError("PARSE", "Failed to parse JSON")
            return
        }
        
        guard let eventId = json["id"] as? String,
              let area = json["area"] as? String,
              let type = json["type"] as? String else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
            logger.logError("PARSE", "Missing required fields")
            return
        }
        
        let channelId = "\(area)_\(type)"
        let eventData = json["data"] as? [String: Any] ?? [:]
        
        // ✅ Check subscription BEFORE processing
        guard SubscriptionManager.shared.isSubscribed(channelId: channelId) else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
            logger.log("FILTER", "Not subscribed to \(channelId), dropping")
            return
        }
        
        // ✅ Extract sequence number
        let sequence: Int64 = {
            guard let seqValue = eventData["_seq"] else { return 0 }
            if let seqNum = seqValue as? Int64 { return seqNum }
            if let seqStr = seqValue as? String, let seqNum = Int64(seqStr) { return seqNum }
            if let seqInt = seqValue as? Int { return Int64(seqInt) }
            return 0
        }()
        
        let timestamp = json["timestamp"] as? Int64 ?? 0
        
        // ✅ Check if event is new (deduplication)
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
            logger.log("DEDUP", "Duplicate event \(eventId) (seq: \(sequence))")
            return
        }
        
        // ✅ Parse full event
        guard let event = parseEvent(json: json) else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
            logger.logError("PARSE", "Failed to parse event structure")
            return
        }
        
        // ✅ CRITICAL: Add event to storage
        let added = SubscriptionManager.shared.addEvent(event: event)
        
        if added {
            // ✅ Update last event time (hang detection)
            lastEventTime = Date()
            
            // ✅ Update counter on main thread
            DispatchQueue.main.async { [weak self] in
                self?.processedCount += 1
            }
            
            logger.log("EVENT", "✅ Processed event \(eventId) for \(channelId) (seq: \(sequence))")
            
            // ✅ Post notification on BACKGROUND thread
            NotificationCenter.default.post(
                name: .newEventReceived,
                object: nil,
                userInfo: ["event": event, "channelId": channelId]
            )
            
            // ✅ Send local notification
            sendLocalNotification(for: event)
            
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
            logger.log("STORAGE", "Failed to add event \(eventId) (already exists)")
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
                self.logger.logError("NOTIFICATION", "Failed: \(error.localizedDescription)")
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
    
    // MARK: - Subscription Management
    
    /// Send subscription to server
    func sendSubscriptionV2() {
        // ✅ Execute on WebSocket queue
        wsQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard self.isConnected, self.webSocketTask != nil else {
                self.logger.logError("SUBSCRIPTION", "Cannot subscribe - not connected")
                return
            }
            
            // ✅ Get subscriptions safely
            let subscriptions = SubscriptionManager.shared.getSubscriptions()
            
            guard !subscriptions.isEmpty else {
                self.logger.logError("SUBSCRIPTION", "No subscriptions to send")
                return
            }
            
            self.logger.log("SUBSCRIPTION", "✅ Subscribing to \(subscriptions.count) channels")
            
            let filters = subscriptions.map { sub in
                SubscriptionFilter(area: sub.area, eventType: sub.eventType)
            }
            
            // ✅ Enable catch-up mode for all channels
            subscriptions.forEach { sub in
                ChannelSyncState.shared.enableCatchUpMode("\(sub.area)_\(sub.eventType)")
            }
            
            // ✅ Build sync state
            var hasSyncState = false
            var syncState = [String: SyncStateInfo]()
            
            subscriptions.forEach { sub in
                let channelId = "\(sub.area)_\(sub.eventType)"
                if let info = ChannelSyncState.shared.getSyncInfo(channelId: channelId) {
                    hasSyncState = true
                    syncState[channelId] = SyncStateInfo(
                        lastEventId: info.lastEventId,
                        lastTimestamp: info.lastEventTimestamp,
                        lastSeq: info.highestSeq
                    )
                }
            }
            
            let resetConsumers = !hasSyncState
            
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
            
            self.logger.log("SUBSCRIPTION", "📤 Sending: \(jsonString)")
            
            // ✅ Send on WebSocket queue
            self.send(message: jsonString) { [weak self] success in
                guard let self = self else { return }
                if success {
                    self.hasSubscribed.value = true
                    self.logger.log("SUBSCRIPTION", "✅ Subscription SENT successfully")
                } else {
                    self.logger.logError("SUBSCRIPTION", "❌ Failed to send subscription")
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
        webSocketTask?.sendPing { [weak self] error in
            if let error = error {
                self?.logger.logError("PING", "Failed: \(error.localizedDescription)")
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
    
    /// Send message on WebSocket - thread-safe
    private func send(message: String, completion: ((Bool) -> Void)? = nil) {
        wsQueue.async { [weak self] in
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
        
        let timeSinceLastEvent = Date().timeIntervalSince(lastEventTime)
        
        logger.log("STATS", """
            Received: \(receivedCount), Processed: \(processedCount), 
            Dropped: \(droppedCount), Last event: \(Int(timeSinceLastEvent))s ago
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
}

// MARK: - Helper: AtomicBoolean
class AtomicBoolean {
    private var _value: Bool
    private let lock = NSLock()
    
    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }
    
    init(_ initialValue: Bool = false) {
        _value = initialValue
    }
}