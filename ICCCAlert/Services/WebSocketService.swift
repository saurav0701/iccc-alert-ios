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
    
    // ✅ CRITICAL FIX: One serial queue for ALL WebSocket/blocking operations
    // This prevents race conditions AND deadlocks
    private let wsQueue = DispatchQueue(label: "com.iccc.websocket", qos: .userInitiated)
    
    // ✅ FIXED: Concurrent queue for CPU-bound event processing (non-blocking)
    private let processingQueue = DispatchQueue(label: "com.iccc.processing", qos: .userInitiated, attributes: .concurrent)
    
    // ACK batching (uses wsQueue, no separate ackQueue)
    private var pendingAcks: [String] = []
    private let ackBatchSize = 100
    private var ackTimer: Timer?
    
    // Ping/Pong
    private var pingTimer: Timer?
    private let pingInterval: TimeInterval = 30.0
    
    // Connection state
    private var hasSubscribed = false
    private let statsLock = NSLock()
    
    private var cancellables = Set<AnyCancellable>()
    private let logger = DebugLogger.shared
    
    // MARK: - Initialization
    private init() {
        logger.log("INIT", "WebSocketService initializing...")
        setupClientId()
        setupSession()
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
        
        DispatchQueue.main.async { [weak self] in
            self?.connectionStatus = "Connected - Monitoring alerts"
        }
        
        logger.logWebSocket("✅ Connected, starting receivers...")
        
        startReceiving()
        startPingPong()
        startAckFlusher()
        startStatsLogging()
        
        // ✅ FIX: Send subscription on WebSocket queue
        wsQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
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
        
        // ✅ Update counter on main thread (non-blocking, async)
        DispatchQueue.main.async { [weak self] in
            self?.receivedCount += 1
        }
        
        // ✅ CRITICAL FIX: Process on background CONCURRENT queue
        // This allows multiple events to process in parallel WITHOUT blocking
        processingQueue.async { [weak self] in
            self?.processEvent(messageText)
        }
    }
    
    // ✅ CRITICAL: NO blocking calls on wsQueue!
    // All blocking operations (SubscriptionManager, ChannelSyncState) happen here on processingQueue
    private func processEvent(_ text: String) {
        // Check subscription confirmation
        if text.contains("\"status\":\"subscribed\"") || text.contains("\"status\":\"ok\"") {
            DispatchQueue.main.async { [weak self] in
                self?.hasSubscribed = true
                self?.logger.logWebSocket("✅ Subscription confirmed")
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
        
        // ✅ CRITICAL: Check subscription WITHOUT blocking on wsQueue
        guard SubscriptionManager.shared.isSubscribed(channelId: channelId) else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
            if requireAck { 
                // ✅ Queue ACK (won't block)
                queueAck(eventId: eventId)
            }
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
        
        // ✅ CRITICAL: Record event WITHOUT blocking on wsQueue
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
            if requireAck { 
                queueAck(eventId: eventId)
            }
            return
        }
        
        guard let event = parseEvent(json: json) else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
            return
        }
        
        // ✅ CRITICAL FIX: Add event to storage (already on concurrent queue, no blocking)
        let added = SubscriptionManager.shared.addEvent(event: event)
        
        if added {
            // ✅ FIX: Update counter on main thread (non-blocking)
            DispatchQueue.main.async { [weak self] in
                self?.processedCount += 1
            }
            
            // ✅ FIX: Post notification on MAIN thread to avoid UIKit issues
            DispatchQueue.main.async { [weak self] in
                NotificationCenter.default.post(
                    name: .newEventReceived,
                    object: nil,
                    userInfo: ["event": event, "channelId": channelId]
                )
                self?.sendLocalNotification(for: event)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.droppedCount += 1
            }
        }
        
        // ✅ Queue ACK (won't block)
        if requireAck {
            queueAck(eventId: eventId)
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
    
    // MARK: - ACK Management
    // ✅ CRITICAL FIX: Queue ACK without blocking
    private func queueAck(eventId: String) {
        // ✅ Just append to array and schedule flush
        // This is non-blocking
        wsQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingAcks.append(eventId)
            
            if self.pendingAcks.count >= self.ackBatchSize {
                self.flushAcksInternal()
            }
        }
    }
    
    private func flushAcks() {
        // ✅ Call on wsQueue
        wsQueue.async { [weak self] in
            self?.flushAcksInternal()
        }
    }
    
    // ✅ Internal flush (called only on wsQueue)
    private func flushAcksInternal() {
        guard !pendingAcks.isEmpty, isConnected else { return }
        
        let acksToSend = Array(pendingAcks.prefix(100))
        pendingAcks.removeFirst(min(100, pendingAcks.count))
        
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
            
            // ✅ CRITICAL: Send directly without using send() to avoid nested wsQueue.async
            let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
            webSocketTask?.send(wsMessage) { [weak self] error in
                if error != nil {
                    self?.logger.logError("ACK", "Failed to send, re-queuing")
                    self?.wsQueue.async {
                        self?.pendingAcks.insert(contentsOf: acksToSend, at: 0)
                    }
                } else {
                    DispatchQueue.main.async {
                        self?.ackedCount += acksToSend.count
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
        wsQueue.async { [weak self] in
            self?.flushAcksInternal()
        }
    }
    
    // MARK: - Subscription Management (✅ COMPLETELY REWRITTEN)
    
    /// Send subscription to server - MUST be called on background thread
    func sendSubscriptionV2() {
        // ✅ CRITICAL FIX: Execute on WebSocket queue to prevent race conditions
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
            
            // ✅ Always reset for live events only
            let request = SubscriptionRequest(
                clientId: self.clientId,
                filters: filters,
                syncState: nil,
                resetConsumers: true
            )
            
            guard let jsonData = try? JSONEncoder().encode(request),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                self.logger.logError("SUBSCRIPTION", "Failed to encode request")
                return
            }
            
            // ✅ Send on WebSocket queue (already here)
            self.send(message: jsonString) { [weak self] success in
                guard let self = self else { return }
                if success {
                    self.hasSubscribed = true
                    self.logger.log("SUBSCRIPTION", "✅ Subscription SENT successfully")
                } else {
                    self.logger.logError("SUBSCRIPTION", "❌ Failed to send subscription")
                }
            }
        }
    }

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
                self.logger.logError("PING", "Failed: \(error.localizedDescription)")
            }
        }
    }

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

    private func send(message: String, completion: ((Bool) -> Void)? = nil) {
        // ✅ CRITICAL FIX: Send directly, don't nest async blocks
        let wsMessage = URLSessionWebSocketTask.Message.string(message)
        webSocketTask?.send(wsMessage) { [weak self] error in
            if let error = error {
                self?.logger.logError("SEND", "Failed: \(error.localizedDescription)")
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
        
        logger.log("STATS", """
            Received: \(receivedCount), Processed: \(processedCount), 
            Dropped: \(droppedCount), ACKed: \(ackedCount)
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