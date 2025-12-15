import Foundation
import Combine

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
    private let wsURL = "ws://192.168.29.69:19999/ws"
    
    private var clientId: String = ""
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = Int.max
    private let reconnectDelay: TimeInterval = 5.0
    
    // Connection health monitoring
    private var lastMessageTime: Date = Date()
    private var healthCheckTimer: Timer?
    
    // Event processing
    private let eventQueue = DispatchQueue(label: "com.iccc.eventQueue", attributes: .concurrent)
    private let processingQueue = DispatchQueue(label: "com.iccc.processing", qos: .userInitiated)
    private var eventBuffer: [String] = []
    private let bufferLock = NSLock()
    
    // ACK batching
    private var pendingAcks: [String] = []
    private let ackLock = NSLock()
    private let ackBatchSize = 10
    private var ackTimer: Timer?
    
    // Ping/Pong
    private var pingTimer: Timer?
    private let pingInterval: TimeInterval = 30.0
    private var missedPongs = 0
    private let maxMissedPongs = 3
    
    // Catch-up monitoring
    private var catchUpChannels: Set<String> = []
    private var catchUpTimer: Timer?
    
    // Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    private init() {
        setupClientId()
        setupSession()
    }
    
    // MARK: - Client ID Management
    private func setupClientId() {
        clientId = KeychainClientID.getOrCreateClientID()
        print("✅ Using Keychain client ID: \(clientId)")
        UserDefaults.standard.set(clientId, forKey: "persistent_client_id")
    }
    
    private func setupSession() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 0
        config.waitsForConnectivity = true // ✅ NEW: Better handling of network changes
        session = URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }
    
    // MARK: - Connection Management
    func connect() {
        disconnect()
        
        guard let url = URL(string: wsURL) else {
            print("❌ Invalid WebSocket URL")
            return
        }
        
        print("🔌 Connecting with persistent client ID: \(clientId)")
        connectionStatus = "Connecting..."
        
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        isConnected = true
        reconnectAttempts = 0
        connectionStatus = "Connected - Monitoring alerts"
        lastMessageTime = Date() // ✅ Reset message timer
        
        startReceiving()
        startPingPong()
        startAckFlusher()
        startStatsLogging()
        startHealthCheck() // ✅ NEW: Monitor connection health
        
        // ✅ CRITICAL: Send subscription with reset flag for fresh start
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.sendSubscriptionV2(reset: true)
        }
        
        print("✅ WebSocket connected")
    }
    
    func disconnect() {
        stopHealthCheck() // ✅ Stop health monitoring
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        connectionStatus = "Disconnected"
        
        stopPingPong()
        stopAckFlusher()
        stopCatchUpMonitoring()
        
        print("🔌 WebSocket disconnected")
    }
    
    // MARK: - Health Check
    private func startHealthCheck() {
        stopHealthCheck()
        
        DispatchQueue.main.async { [weak self] in
            self?.healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
                self?.checkConnectionHealth()
            }
        }
    }
    
    private func stopHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }
    
    private func checkConnectionHealth() {
        let timeSinceLastMessage = Date().timeIntervalSince(lastMessageTime)
        
        // If no messages for 60 seconds and we expect messages, reconnect
        if timeSinceLastMessage > 60 && !SubscriptionManager.shared.subscribedChannels.isEmpty {
            print("⚠️ No messages received for \(Int(timeSinceLastMessage))s, reconnecting...")
            DispatchQueue.main.async {
                self.reconnect()
            }
        }
    }
    
    // MARK: - Message Receiving
    private func startReceiving() {
        receiveMessage()
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                self.lastMessageTime = Date() // ✅ Update last message time
                self.missedPongs = 0 // ✅ Reset missed pong counter
                self.handleMessage(message)
                self.receiveMessage() // Continue receiving
                
            case .failure(let error):
                print("❌ WebSocket error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isConnected = false
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
            bufferLock.lock()
            eventBuffer.append(text)
            bufferLock.unlock()
            
            processingQueue.async { [weak self] in
                self?.processEvent(text)
            }
            
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                receivedCount += 1
                bufferLock.lock()
                eventBuffer.append(text)
                bufferLock.unlock()
                
                processingQueue.async { [weak self] in
                    self?.processEvent(text)
                }
            }
            
        @unknown default:
            break
        }
    }
    
    // MARK: - Event Processing
    private func processEvent(_ text: String) {
        // Skip subscription confirmations
        if text.contains("\"status\":\"subscribed\"") {
            print("✅ Subscription confirmed")
            return
        }
        
        // Skip error messages
        if text.contains("\"error\"") {
            DispatchQueue.main.async {
                self.errorCount += 1
            }
            return
        }
        
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventId = json["id"] as? String,
              let area = json["area"] as? String,
              let type = json["type"] as? String else {
            DispatchQueue.main.async {
                self.droppedCount += 1
            }
            return
        }
        
        let channelId = "\(area)_\(type)"
        let eventData = json["data"] as? [String: Any] ?? [:]
        let requireAck = eventData["_requireAck"] as? Bool ?? true
        
        // Check if subscribed
        guard SubscriptionManager.shared.isSubscribed(channelId: channelId) else {
            DispatchQueue.main.async {
                self.droppedCount += 1
            }
            if requireAck {
                sendAck(eventId: eventId)
            }
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
        
        // Record event in sync state
        let isNew = ChannelSyncState.shared.recordEventReceived(
            channelId: channelId,
            eventId: eventId,
            timestamp: timestamp,
            seq: sequence
        )
        
        // Duplicate check
        if !isNew && sequence > 0 {
            DispatchQueue.main.async {
                self.droppedCount += 1
            }
            if requireAck {
                sendAck(eventId: eventId)
            }
            return
        }
        
        // Convert to Event object
        guard let event = parseEvent(json: json) else {
            DispatchQueue.main.async {
                self.droppedCount += 1
            }
            return
        }
        
        // Add to subscription manager
        let added = SubscriptionManager.shared.addEvent(event: event)
        
        if added {
            DispatchQueue.main.async {
                self.processedCount += 1
                print("✅ Event processed: \(event.typeDisplay) at \(event.location)")
            }
            
            // Post notification for UI update
            NotificationCenter.default.post(
                name: .newEventReceived,
                object: nil,
                userInfo: ["event": event, "channelId": channelId]
            )
        } else {
            DispatchQueue.main.async {
                self.droppedCount += 1
            }
        }
        
        // Send ACK
        if requireAck {
            sendAck(eventId: eventId)
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
        
        let acksToSend = Array(pendingAcks.prefix(50))
        pendingAcks.removeFirst(min(50, pendingAcks.count))
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
                    print("✅ Sent ACK for \(acksToSend.count) events")
                } else {
                    print("❌ Failed to send ACK, re-queuing")
                    self?.ackLock.lock()
                    self?.pendingAcks.insert(contentsOf: acksToSend, at: 0)
                    self?.ackLock.unlock()
                }
            }
        }
    }
    
    private func startAckFlusher() {
        DispatchQueue.main.async { [weak self] in
            self?.ackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
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
    func sendSubscriptionV2(reset: Bool = false) {
        guard isConnected else { return }
        
        let subscriptions = SubscriptionManager.shared.getSubscriptions()
        guard !subscriptions.isEmpty else { return }
        
        let filters = subscriptions.map { sub in
            return [
                "area": sub.area,
                "eventType": sub.eventType
            ]
        }
        
        // Enable catch-up mode
        subscriptions.forEach { sub in
            let channelId = "\(sub.area)_\(sub.eventType)"
            ChannelSyncState.shared.enableCatchUpMode(channelId: channelId)
            catchUpChannels.insert(channelId)
        }
        
        // ✅ CRITICAL: Always use resetConsumers=true for first connection
        var request: [String: Any] = [
            "clientId": clientId,
            "filters": filters,
            "resetConsumers": reset // ✅ NEW: Send reset flag
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: request),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            
            print("""
            ✅ Sending subscription:
            - Filters: \(filters.count)
            - Reset: \(reset)
            - Client ID: \(clientId)
            """)
            
            send(message: jsonString) { [weak self] success in
                if success {
                    print("✅ Subscription sent successfully")
                    self?.startCatchUpMonitoring()
                } else {
                    print("❌ Failed to send subscription")
                }
            }
        }
    }
    
    func updateSubscriptions() {
        sendSubscriptionV2(reset: false)
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
                        print("✅ Catch-up complete for \(channelId) (\(progress) events)")
                    } else {
                        allComplete = false
                    }
                } else {
                    allComplete = false
                }
            }
        }
        
        if allComplete {
            print("🎉 ALL CHANNELS CAUGHT UP")
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
        missedPongs = 0
    }
    
    private func sendPing() {
        webSocketTask?.sendPing { [weak self] error in
            if let error = error {
                print("❌ Ping failed: \(error.localizedDescription)")
                self?.missedPongs += 1
                
                if let missedPongs = self?.missedPongs, missedPongs >= self?.maxMissedPongs ?? 3 {
                    print("⚠️ Too many missed pongs, reconnecting...")
                    DispatchQueue.main.async {
                        self?.reconnect()
                    }
                }
            } else {
                self?.missedPongs = 0
            }
        }
    }
    
    // MARK: - Reconnection
    private func reconnect() {
        print("🔄 Reconnecting...")
        disconnect()
        connect()
    }
    
    private func scheduleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            connectionStatus = "Connection failed - Tap to retry"
            return
        }
        
        reconnectAttempts += 1
        let delay = reconnectDelay * Double(min(reconnectAttempts, 12))
        
        print("🔄 Reconnecting in \(delay)s (attempt \(reconnectAttempts))")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }
    
    // MARK: - Message Sending
    private func send(message: String, completion: ((Bool) -> Void)? = nil) {
        let wsMessage = URLSessionWebSocketTask.Message.string(message)
        webSocketTask?.send(wsMessage) { error in
            if let error = error {
                print("❌ Failed to send message: \(error.localizedDescription)")
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
        
        print("""
        📊 STATS: received=\(receivedCount), processed=\(processedCount), 
        acked=\(ackedCount), dropped=\(droppedCount), errors=\(errorCount), 
        pendingAcks=\(pendingAcks.count)
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