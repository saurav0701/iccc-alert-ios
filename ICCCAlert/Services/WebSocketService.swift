import Foundation
import Combine
import UIKit

class WebSocketService: ObservableObject {
    static let shared = WebSocketService()
    
    @Published var isConnected = false
    @Published var connectionStatus = "Disconnected"
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reconnectTimer: Timer?
    private var pingTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = Int.max
    
    private let baseURL = "ws://192.168.29.70:19999" // CCL

    
    private var wsURL: String {
        return "\(baseURL)/ws"
    }
    
    // Event processing
    private let eventQueue = DispatchQueue(label: "com.iccc.eventQueue", attributes: .concurrent)
    private let ackQueue = DispatchQueue(label: "com.iccc.ackQueue")
    private var pendingAcks: [String] = []
    private let ackBatchSize = 50
    private var ackTimer: Timer?
    
    // Statistics
    private var receivedCount = 0
    private var processedCount = 0
    private var droppedCount = 0
    private var ackedCount = 0
    private var errorCount = 0
    
    // Catch-up monitoring
    private var catchUpTimer: Timer?
    private var consecutiveEmptyChecks: [String: Int] = [:]
    private let stableEmptyThreshold = 3
    
    // Client ID
    private var clientId: String {
        return getDeviceId()
    }
    
    // Subscription state
    private var hasSubscribed = false
    private var lastSubscriptionTime: TimeInterval = 0
    
    private init() {
        setupSession()
    }
    
    private func setupSession() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }
    
    // MARK: - Public Methods
    
    func connect() {
        guard webSocketTask == nil else {
            print("⚠️ WebSocket already exists")
            return
        }
        
        guard let url = URL(string: wsURL) else {
            print("❌ Invalid WebSocket URL")
            return
        }
        
        DispatchQueue.main.async {
            self.connectionStatus = "Connecting..."
        }
        
        print("🔌 Connecting to: \(wsURL)")
        print("📱 Client ID: \(clientId)")
        
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        receiveMessage()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if self.webSocketTask?.state == .running {
                self.handleConnectionSuccess()
            }
        }
    }
    
    func disconnect() {
        print("🔌 Disconnecting WebSocket")
        
        stopTimers()
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionStatus = "Disconnected"
        }
    }
    
    // MARK: - Connection Handling
    
    private func handleConnectionSuccess() {
        print("✅ WebSocket connected")
        
        DispatchQueue.main.async {
            self.isConnected = true
            self.connectionStatus = "Connected"
            self.reconnectAttempts = 0
            self.hasSubscribed = false
        }
        
        startPingTimer()
        
        // Send subscription after connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.sendSubscriptionV2()
        }
        
        startStatsTimer()
    }
    
    private func handleConnectionFailure(error: Error?) {
        print("❌ WebSocket connection failed: \(error?.localizedDescription ?? "Unknown error")")
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionStatus = "Disconnected"
            self.hasSubscribed = false
        }
        
        webSocketTask = nil
        stopTimers()
        
        scheduleReconnect()
    }
    
    private func scheduleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            DispatchQueue.main.async {
                self.connectionStatus = "Connection failed"
            }
            return
        }
        
        reconnectAttempts += 1
        let delay = min(Double(reconnectAttempts) * 5.0, 60.0)
        
        print("🔄 Reconnecting in \(delay)s (attempt \(reconnectAttempts))")
        
        DispatchQueue.main.async {
            self.connectionStatus = "Reconnecting in \(Int(delay))s..."
        }
        
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.connect()
        }
    }
    
    // MARK: - Message Handling
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                
                // Continue receiving
                self.receiveMessage()
                
            case .failure(let error):
                print("❌ WebSocket receive error: \(error.localizedDescription)")
                self.handleConnectionFailure(error: error)
            }
        }
    }
    
    private func handleMessage(_ text: String) {
        receivedCount += 1
        
        // Process on background queue
        eventQueue.async {
            self.processMessage(text)
        }
    }
    
    private func processMessage(_ text: String) {
        // Skip subscription confirmations
        if text.contains("\"status\":\"subscribed\"") {
            return
        }
        
        // Handle errors
        if text.contains("\"error\"") {
            errorCount += 1
            print("⚠️ Server error: \(text)")
            return
        }
        
        // Parse event
        guard let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(Event.self, from: data) else {
            errorCount += 1
            return
        }
        
        guard let eventId = event.id,
              let area = event.area,
              let type = event.type else {
            droppedCount += 1
            return
        }
        
        let channelId = "\(area)_\(type)"
        
        // Check subscription
        guard SubscriptionManager.shared.isSubscribed(channelId: channelId) else {
            droppedCount += 1
            sendAck(eventId: eventId)
            return
        }
        
        // Get sequence number
        let seq = event.data?["_seq"] as? Int64 ?? 0
        
        // Record in sync state
        let isNew = ChannelSyncState.shared.recordEventReceived(
            channelId: channelId,
            eventId: eventId,
            timestamp: event.timestamp,
            seq: seq
        )
        
        if !isNew && seq > 0 {
            droppedCount += 1
            sendAck(eventId: eventId)
            return
        }
        
        // Add event to storage
        let added = SubscriptionManager.shared.addEvent(event)
        
        if added {
            processedCount += 1
            
            // Notify UI
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .newEventReceived,
                    object: nil,
                    userInfo: ["eventId": eventId, "channelId": channelId]
                )
            }
        } else {
            droppedCount += 1
        }
        
        // Always ACK
        sendAck(eventId: eventId)
    }
    
    // MARK: - ACK Handling
    
    private func sendAck(eventId: String) {
        ackQueue.async {
            self.pendingAcks.append(eventId)
            
            if self.pendingAcks.count >= self.ackBatchSize {
                self.flushAcks()
            }
        }
    }
    
    private func flushAcks() {
        guard isConnected, !pendingAcks.isEmpty else { return }
        
        let acksToSend = Array(pendingAcks.prefix(100))
        pendingAcks.removeFirst(min(acksToSend.count, pendingAcks.count))
        
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
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: ackMessage),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("❌ Failed to serialize ACK")
            // Re-queue ACKs
            ackQueue.async {
                self.pendingAcks.insert(contentsOf: acksToSend, at: 0)
            }
            return
        }
        
        let message = URLSessionWebSocketTask.Message.string(jsonString)
        
        webSocketTask?.send(message) { [weak self] error in
            if let error = error {
                print("❌ Failed to send ACK: \(error.localizedDescription)")
                // Re-queue ACKs
                self?.ackQueue.async {
                    self?.pendingAcks.insert(contentsOf: acksToSend, at: 0)
                }
            } else {
                self?.ackedCount += acksToSend.count
                
                if acksToSend.count > 50 {
                    print("✅ Sent BULK ACK for \(acksToSend.count) events")
                }
            }
        }
    }
    
    // MARK: - Subscription
    
    func sendSubscriptionV2() {
        guard isConnected else {
            print("⚠️ Cannot subscribe - not connected")
            return
        }
        
        let now = Date().timeIntervalSince1970
        if hasSubscribed && (now - lastSubscriptionTime) < 5.0 {
            print("⚠️ Skipping duplicate subscription")
            return
        }
        
        let subscriptions = SubscriptionManager.shared.subscribedChannels
        
        guard !subscriptions.isEmpty else {
            print("⚠️ No subscriptions to send")
            return
        }
        
        // Enable catch-up mode for all channels
        for channel in subscriptions {
            ChannelSyncState.shared.enableCatchUpMode(channelId: channel.id)
        }
        
        // Build filters
        let filters = subscriptions.map { channel -> [String: String] in
            return [
                "area": channel.area,
                "eventType": channel.eventType
            ]
        }
        
        // Build sync state
        var syncState: [String: [String: Any]] = [:]
        var hasSyncState = false
        
        for channel in subscriptions {
    if let info = ChannelSyncState.shared.getSyncInfo(channelId: channel.id) {
        hasSyncState = true
        syncState[channel.id] = [
            "lastEventId": info.lastEventId ?? "",
            "lastTimestamp": info.lastEventTimestamp,  // ✅ FIXED: Changed from lastTimestamp
            "lastSeq": info.highestSeq
        ]
    }
}
        
        let resetConsumers = !hasSyncState
        
        var request: [String: Any] = [
            "clientId": clientId,
            "filters": filters,
            "resetConsumers": resetConsumers
        ]
        
        if !syncState.isEmpty {
            request["syncState"] = syncState
        }
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: request),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("❌ Failed to serialize subscription")
            return
        }
        
        print("📤 Subscription: \(jsonString)")
        
        if resetConsumers {
            print("⚠️ RESET MODE: Will delete old consumers and start fresh")
        } else {
            print("✅ RESUME MODE: Will resume from last known sequences")
        }
        
        let message = URLSessionWebSocketTask.Message.string(jsonString)
        
        webSocketTask?.send(message) { [weak self] error in
            if let error = error {
                print("❌ Failed to send subscription: \(error.localizedDescription)")
            } else {
                self?.hasSubscribed = true
                self?.lastSubscriptionTime = now
                print("✅ Subscription sent successfully")
                self?.startCatchUpMonitoring()
            }
        }
    }
    
    // MARK: - Catch-up Monitoring
    
    private func startCatchUpMonitoring() {
        catchUpTimer?.invalidate()
        
        catchUpTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkCatchUpProgress()
        }
    }
    
    private func checkCatchUpProgress() {
        guard isConnected else {
            catchUpTimer?.invalidate()
            return
        }
        
        let subscriptions = SubscriptionManager.shared.subscribedChannels
        var allComplete = true
        var activeCatchUps = 0
        
        for channel in subscriptions {
            if ChannelSyncState.shared.isInCatchUpMode(channelId: channel.id) {
                activeCatchUps += 1
                let progress = ChannelSyncState.shared.getCatchUpProgress(channelId: channel.id)
                
                if progress > 0 && pendingAcks.isEmpty {
                    let count = consecutiveEmptyChecks[channel.id] ?? 0
                    consecutiveEmptyChecks[channel.id] = count + 1
                    
                    if count + 1 >= stableEmptyThreshold {
                        ChannelSyncState.shared.disableCatchUpMode(channelId: channel.id)
                        consecutiveEmptyChecks.removeValue(forKey: channel.id)
                        print("✅ Catch-up complete for \(channel.id) (\(progress) events)")
                    } else {
                        allComplete = false
                    }
                } else {
                    consecutiveEmptyChecks[channel.id] = 0
                    allComplete = false
                }
            }
        }
        
        if activeCatchUps > 0 && allComplete {
            print("🎉 ALL CHANNELS CAUGHT UP")
            consecutiveEmptyChecks.removeAll()
            catchUpTimer?.invalidate()
        }
    }
    
    // MARK: - Timers
    
    private func startPingTimer() {
        pingTimer?.invalidate()
        
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }
    
    private func sendPing() {
        webSocketTask?.sendPing { error in
            if let error = error {
                print("⚠️ Ping failed: \(error.localizedDescription)")
            }
        }
    }
    
    private func startStatsTimer() {
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isConnected else { return }
            
            print("📊 STATS: received=\(self.receivedCount), processed=\(self.processedCount), acked=\(self.ackedCount), dropped=\(self.droppedCount), errors=\(self.errorCount), pendingAcks=\(self.pendingAcks.count)")
        }
    }
    
    private func startAckTimer() {
        ackTimer?.invalidate()
        
        ackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.ackQueue.async {
                if !(self?.pendingAcks.isEmpty ?? true) {
                    self?.flushAcks()
                }
            }
        }
    }
    
    private func stopTimers() {
        reconnectTimer?.invalidate()
        pingTimer?.invalidate()
        catchUpTimer?.invalidate()
        ackTimer?.invalidate()
        
        reconnectTimer = nil
        pingTimer = nil
        catchUpTimer = nil
        ackTimer = nil
    }
    
    // MARK: - Utilities
    
    private func getDeviceId() -> String {
        if let uuid = UIDevice.current.identifierForVendor?.uuidString {
            let shortId = String(uuid.prefix(8))
            return "ios-\(shortId)"
        }
        return "ios-unknown"
    }
    
    deinit {
        disconnect()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let newEventReceived = Notification.Name("newEventReceived")
}