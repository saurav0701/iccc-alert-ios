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
 
    private let eventQueue = DispatchQueue(label: "com.iccc.eventProcessing", qos: .userInitiated, attributes: .concurrent)
    private let ackQueue = DispatchQueue(label: "com.iccc.ackProcessing", qos: .utility)
    private let maxConcurrentProcessors = ProcessInfo.processInfo.processorCount.clamped(to: 2...4)
    private var activeProcessors = 0
    private let processorLock = NSLock()

    private var pendingAcks: [String] = []
    private let ackLock = NSLock()
    private let maxAckBatchSize = 50
    private var ackFlushTimer: Timer?

    private var receivedCount = 0
    private var processedCount = 0
    private var droppedCount = 0
    private var ackedCount = 0

    private var lastProcessedTimestamp: TimeInterval = 0
    private var catchUpMode = false
    private let catchUpThreshold = 10
    
    // ✅ NEW: Connection state management
    private enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case reconnecting
    }
    private var connectionState: ConnectionState = .disconnected
    private let connectionLock = NSLock()
    
    // ✅ NEW: Reconnection backoff
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var reconnectTimer: Timer?
    
    // ✅ NEW: Subscription queue
    private var subscriptionQueue: DispatchQueue = DispatchQueue(label: "com.iccc.subscriptionQueue")
    private var isSubscribing = false
    
    // ✅ NEW: Health check
    private var missedPingCount = 0
    private let maxMissedPings = 3
    
    private var clientId: String {
        if let uuid = UIDevice.current.identifierForVendor?.uuidString {
            return "ios-\(String(uuid.prefix(8)))"
        }
        return "ios-unknown"
    }
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true // ✅ NEW: Wait for network
        session = URLSession(configuration: config)
        
        startAckFlusher()
        startHealthMonitor()
    }

    private func startHealthMonitor() {
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            let now = Date().timeIntervalSince1970
            
            // Check if processing is stalled
            if self.lastProcessedTimestamp > 0 && (now - self.lastProcessedTimestamp) > 30 {
                DebugLogger.shared.log("⚠️ Processing stalled for 30s", emoji: "🔄", color: .orange)
                
                // Only reconnect if we're supposed to be connected
                if self.connectionState == .connected {
                    self.handleConnectionIssue(reason: "Processing stalled")
                }
            }
        }
    }
    
    // ✅ IMPROVED: Connection with state management
    func connect() {
        connectionLock.lock()
        
        // Prevent multiple simultaneous connection attempts
        guard connectionState == .disconnected || connectionState == .reconnecting else {
            DebugLogger.shared.log("Already connecting/connected", emoji: "⚠️", color: .orange)
            connectionLock.unlock()
            return
        }
        
        connectionState = .connecting
        connectionLock.unlock()
        
        guard let url = URL(string: "\(baseURL)/ws") else {
            DebugLogger.shared.log("Invalid URL", emoji: "❌", color: .red)
            connectionState = .disconnected
            return
        }
        
        DebugLogger.shared.log("Connecting... clientId=\(clientId)", emoji: "🔌", color: .blue)
        
        // Clean up existing connection
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        receiveMessage()
        
        // ✅ IMPROVED: Better connection verification
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if self.webSocketTask?.state == .running {
                self.connectionLock.lock()
                self.connectionState = .connected
                self.connectionLock.unlock()
                
                self.isConnected = true
                self.connectionStatus = "Connected"
                self.hasSubscribed = false
                self.reconnectAttempts = 0
                self.missedPingCount = 0
                
                DebugLogger.shared.log("✅ Connected successfully", emoji: "✅", color: .green)
                
                self.startPing()
                
                // ✅ IMPROVED: Delayed subscription with state check
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if self.connectionState == .connected {
                        self.sendSubscriptionV2()
                    }
                }
            } else {
                DebugLogger.shared.log("Connection failed", emoji: "❌", color: .red)
                self.handleConnectionFailure()
            }
        }
    }
    
    func disconnect() {
        connectionLock.lock()
        connectionState = .disconnected
        connectionLock.unlock()
        
        // Cancel reconnect timer
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        
        flushAcksSync()
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        hasSubscribed = false
        pingTimer?.invalidate()
        ackFlushTimer?.invalidate()
        
        DebugLogger.shared.log("Disconnected", emoji: "🔌", color: .gray)
    }
    
    // ✅ NEW: Handle connection issues intelligently
    private func handleConnectionIssue(reason: String) {
        connectionLock.lock()
        let currentState = connectionState
        connectionLock.unlock()
        
        guard currentState == .connected else {
            DebugLogger.shared.log("Ignoring connection issue - not connected", emoji: "⏭️", color: .gray)
            return
        }
        
        DebugLogger.shared.log("Connection issue: \(reason)", emoji: "⚠️", color: .orange)
        reconnectWithBackoff()
    }
    
    // ✅ NEW: Handle connection failure
    private func handleConnectionFailure() {
        connectionLock.lock()
        connectionState = .disconnected
        connectionLock.unlock()
        
        isConnected = false
        reconnectWithBackoff()
    }
    
    // ✅ IMPROVED: Reconnect with exponential backoff
    private func reconnectWithBackoff() {
        connectionLock.lock()
        
        guard connectionState != .reconnecting else {
            DebugLogger.shared.log("Already reconnecting", emoji: "⏭️", color: .gray)
            connectionLock.unlock()
            return
        }
        
        connectionState = .reconnecting
        connectionLock.unlock()
        
        reconnectAttempts += 1
        
        // Calculate backoff delay: 2s, 4s, 8s, 16s, 32s
        let delay = min(pow(2.0, Double(reconnectAttempts - 1)), 32.0)
        
        DebugLogger.shared.log("Reconnecting in \(delay)s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))", emoji: "🔄", color: .orange)
        
        // Cancel existing timer
        reconnectTimer?.invalidate()
        
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            
            self.connectionLock.lock()
            self.connectionState = .disconnected
            self.connectionLock.unlock()
            
            self.connect()
        }
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                // ✅ Reset missed ping counter on successful message
                self.missedPingCount = 0
                
                switch message {
                case .string(let text):
                    self.receivedCount += 1
                    self.lastProcessedTimestamp = Date().timeIntervalSince1970

                    if self.catchUpMode {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    
                    self.eventQueue.async {
                        self.handleMessage(text)
                    }
                    
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.receivedCount += 1
                        self.lastProcessedTimestamp = Date().timeIntervalSince1970
                        
                        if self.catchUpMode {
                            Thread.sleep(forTimeInterval: 0.01)
                        }
                        
                        self.eventQueue.async {
                            self.handleMessage(text)
                        }
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()
                
            case .failure(let error):
                DebugLogger.shared.log("WebSocket error: \(error.localizedDescription)", emoji: "❌", color: .red)
                
                self.connectionLock.lock()
                let wasConnected = self.connectionState == .connected
                self.connectionLock.unlock()
                
                self.isConnected = false
                
                // ✅ Only reconnect if we were actually connected
                if wasConnected && self.webSocketTask?.state != .canceling {
                    self.handleConnectionIssue(reason: "Receive error")
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        autoreleasepool {
            do {
                try _handleMessageInternal(text)
            } catch {
                DebugLogger.shared.log("Error handling message: \(error)", emoji: "❌", color: .red)
                droppedCount += 1
            }
        }
    }
    
    private func _handleMessageInternal(_ text: String) throws {
        if text.contains("\"status\":\"subscribed\"") {
            DebugLogger.shared.log("✅ Subscription confirmed", emoji: "✅", color: .green)
            pendingSubscriptionUpdate = false
            isSubscribing = false
            return
        }
  
        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: "WebSocket", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert to data"])
        }
        
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

                DispatchQueue.main.async {
                    NotificationManager.shared.sendEventNotification(event: event, channel: tempChannel)
                }
            }

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

        if processedCount % 100 == 0 {
            let stats = "received=\(receivedCount), processed=\(processedCount), dropped=\(droppedCount), acked=\(ackedCount)"
            DebugLogger.shared.log("📊 STATS: \(stats)", emoji: "📊", color: .blue)
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

    // ✅ IMPROVED: Subscription with better error handling
    func sendSubscriptionV2() {
        // Check connection state
        connectionLock.lock()
        let currentState = connectionState
        connectionLock.unlock()
        
        guard currentState == .connected else {
            DebugLogger.shared.log("Cannot subscribe - not connected (state: \(currentState))", emoji: "⚠️", color: .orange)
            pendingSubscriptionUpdate = true
            return
        }
        
        guard webSocketTask?.state == .running else {
            DebugLogger.shared.log("Cannot subscribe - websocket not running", emoji: "⚠️", color: .orange)
            pendingSubscriptionUpdate = true
            return
        }
        
        // ✅ Prevent concurrent subscriptions
        guard !isSubscribing else {
            DebugLogger.shared.log("Subscription already in progress", emoji: "⏭️", color: .gray)
            return
        }
        
        let now = Date().timeIntervalSince1970
        
        // ✅ Prevent duplicate subscriptions within 3 seconds
        if hasSubscribed && (now - lastSubscriptionTime) < 3 {
            DebugLogger.shared.log("Skipping duplicate subscription (last: \(Int(now - lastSubscriptionTime))s ago)", emoji: "⏭️", color: .gray)
            return
        }
        
        let subscriptions = SubscriptionManager.shared.subscribedChannels
        guard !subscriptions.isEmpty else { return }
        
        isSubscribing = true
        
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
            isSubscribing = false
            return
        }
        
        let mode = resetConsumers ? "RESET" : "RESUME"
        DebugLogger.shared.log("Sending subscription (\(mode)): \(subscriptions.count) channels", emoji: "📤", color: .blue)
        
        // Enter catch-up mode if resuming
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
        
        // ✅ IMPROVED: Better error handling - don't reconnect on subscription failure
        webSocketTask?.send(.string(str)) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                DebugLogger.shared.log("❌ Subscription send failed: \(error.localizedDescription)", emoji: "❌", color: .red)
                self.isSubscribing = false
                
                // ✅ Don't reconnect immediately - check connection state
                self.connectionLock.lock()
                let currentState = self.connectionState
                self.connectionLock.unlock()
                
                if currentState == .connected {
                    // Connection is fine, just retry subscription after delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if self.connectionState == .connected {
                            self.sendSubscriptionV2()
                        }
                    }
                }
            } else {
                self.hasSubscribed = true
                self.lastSubscriptionTime = now
                DebugLogger.shared.log("✅ Subscription sent (reset=\(resetConsumers))", emoji: "✅", color: .green)
                
                // ✅ Set timeout for subscription confirmation
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if self.isSubscribing {
                        DebugLogger.shared.log("⚠️ Subscription confirmation timeout", emoji: "⚠️", color: .orange)
                        self.isSubscribing = false
                    }
                }
            }
        }
    }
    
    // ✅ IMPROVED: Better ping with health check
    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            self.connectionLock.lock()
            let currentState = self.connectionState
            self.connectionLock.unlock()
            
            guard currentState == .connected else {
                DebugLogger.shared.log("Skipping ping - not connected", emoji: "⏭️", color: .gray)
                return
            }
            
            if self.webSocketTask?.state == .running {
                self.webSocketTask?.sendPing { error in
                    if let error = error {
                        self.missedPingCount += 1
                        DebugLogger.shared.log("Ping failed (\(self.missedPingCount)/\(self.maxMissedPings)): \(error.localizedDescription)", emoji: "❌", color: .red)
                        
                        // ✅ Only reconnect after multiple failures
                        if self.missedPingCount >= self.maxMissedPings {
                            self.handleConnectionIssue(reason: "Multiple ping failures")
                        }
                    } else {
                        // Reset counter on successful ping
                        if self.missedPingCount > 0 {
                            DebugLogger.shared.log("Ping recovered", emoji: "✅", color: .green)
                        }
                        self.missedPingCount = 0
                    }
                }
            } else {
                DebugLogger.shared.log("Connection lost during ping check", emoji: "🔄", color: .orange)
                self.handleConnectionIssue(reason: "Connection state changed")
            }
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