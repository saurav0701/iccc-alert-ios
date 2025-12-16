import Foundation
import Combine
import UIKit
import UserNotifications

class WebSocketService: ObservableObject {
    static let shared = WebSocketService()
    
    // MARK: - Published Properties for UI
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
    
    // ✅ CRITICAL: Serial queue ONLY - absolutely no parallel processing
    private let serialQueue = DispatchQueue(label: "com.iccc.websocket.serial", qos: .userInitiated)
    
    // ✅ OPTIMIZED: Use concurrent queues for actual event processing (like Android's thread pool)
    private let processingQueue = DispatchQueue(
        label: "com.iccc.websocket.processing",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let numProcessors: Int
    private var processingTasks: [DispatchSourceTimer] = []
    
    // ✅ CRITICAL: Use proper concurrent queues, not arrays
    private let eventQueue = DispatchQueue(label: "com.iccc.websocket.events")
    private var queuedEvents: [String] = []
    private var liveEventCount = 0
    
    // ✅ Processing state tracking
    private var isReceiving = false
    private var isProcessorActive = false
    
    // ACK batching
    private var pendingAcks: [String] = []
    private let ackBatchSize = 100
    private var ackTimer: DispatchSourceTimer?
    
    // Ping/Pong
    private var pingTimer: DispatchSourceTimer?
    private let pingInterval: TimeInterval = 30.0
    
    // ✅ Catch-up monitoring
    private var catchUpChannels: Set<String> = []
    private var catchUpTimer: DispatchSourceTimer?
    private let catchUpCheckInterval: TimeInterval = 5.0
    private var consecutiveEmptyChecks: [String: Int] = [:]
    private let stableEmptyThreshold = 3
    
    // Connection state tracking
    private var lastConnectionTime: Date?
    private var hasSubscribed = false
    private var lastSubscriptionTime: TimeInterval = 0
    
    private var cancellables = Set<AnyCancellable>()
    private let logger = DebugLogger.shared
    
    // ✅ Background task for processing
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    // MARK: - Initialization
    private init() {
        // Calculate optimal number of processors (4-8 like Android)
        numProcessors = max(4, min(DispatchQueue.concurrentPerform(iterations: 0, execute: { _ in }), 8))
        
        logger.log("INIT", "WebSocketService initializing with \(numProcessors) processors...")
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
            self.isReceiving = true
            self.reconnectAttempts = 0
            self.lastConnectionTime = Date()
            
            DispatchQueue.main.async {
                self.connectionStatus = "Connected - Monitoring alerts"
            }
            
            self.logger.logWebSocket("✅ WebSocket connected, starting services...")
            
            self.startReceiving()
            self.startEventProcessors()
            self.startPingPong()
            self.startAckFlusher()
            self.startStatsLogging()
            
            // ✅ Send subscription after connection is established
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.sendSubscriptionV2()
            }
        }
    }
    
    func disconnect() {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.logger.logWebSocket("🔌 Disconnecting...")
            self.isReceiving = false
            self.webSocketTask?.cancel(with: .goingAway, reason: nil)
            self.webSocketTask = nil
            self.isConnected = false
            self.hasSubscribed = false
            
            DispatchQueue.main.async {
                self.connectionStatus = "Disconnected"
            }
            
            self.stopEventProcessors()
            self.stopPingPong()
            self.stopAckFlusher()
            self.stopCatchUpMonitoring()
            
            self.logger.logWebSocket("✅ WebSocket disconnected")
        }
    }
    
    // ✅ CRITICAL: Continuous receiver loop (non-blocking)
    private func startReceiving() {
        serialQueue.async { [weak self] in
            self?.receiveMessage()
        }
    }
    
    private func receiveMessage() {
        guard isReceiving else { return }
        
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                self.handleMessage(message)
                // Continue receiving immediately
                self.receiveMessage()
                
            case .failure(let error):
                self.logger.logError("WS_RECEIVE", "❌ WebSocket error: \(error.localizedDescription)")
                
                self.serialQueue.async {
                    self.isConnected = false
                    self.isReceiving = false
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
        
        // ✅ Queue event for processing
        eventQueue.async { [weak self] in
            guard let self = self else { return }
            self.queuedEvents.append(messageText)
        }
    }
    
    // ✅ CRITICAL: Start multiple event processors (like Android's thread pool)
    private func startEventProcessors() {
        stopEventProcessors()
        
        // ✅ Start one processor per optimal CPU core
        for i in 0..<numProcessors {
            let timer = DispatchSource.makeTimerSource(queue: processingQueue)
            timer.schedule(deadline: .now() + Double(i) * 0.001, repeating: 0.01)
            timer.setEventHandler { [weak self] in
                self?.processEventBatch(processorId: i)
            }
            timer.resume()
            processingTasks.append(timer)
        }
        
        logger.log("PROCESSORS", "✅ Started \(numProcessors) event processors")
    }
    
    private func stopEventProcessors() {
        processingTasks.forEach { $0.cancel() }
        processingTasks.removeAll()
    }
    
    // ✅ CRITICAL: Process one event at a time per processor (no blocking)
    private func processEventBatch(processorId: Int) {
        eventQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Get ONE event from queue
            guard !self.queuedEvents.isEmpty else { return }
            let messageText = self.queuedEvents.removeFirst()
            
            // Process it
            self.processingQueue.async {
                self.processEvent(messageText)
            }
        }
    }
    
    // ✅ CRITICAL: Streamlined event processing - ZERO blocking
    private func processEvent(_ text: String) {
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
        
        // Parse JSON (on processing queue, not main)
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
        let timestamp = json["timestamp"] as? Int64 ?? 0
        
        // ✅ Check subscription
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
        
        // ✅ CRITICAL: Add to storage (FAST - no blocking)
        let added = SubscriptionManager.shared.addEvent(event: event)
        
        if added {
            DispatchQueue.main.async { [weak self] in
                self?.processedCount += 1
            }
            
            // ✅ Check if in catch-up mode
            let inCatchUp = ChannelSyncState.shared.isInCatchUpMode(channelId: channelId)
            
            // Notify UI (always on main thread)
            DispatchQueue.main.async { [weak self] in
                self?.broadcastEvent(event, channelId: channelId)
                
                // Only send notification if live and notifications enabled
                if !inCatchUp && DebugLogger.shared.areNotificationsEnabled() {
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
    
    // ✅ CRITICAL: Batch ACKs properly
    private func flushAcks() {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.pendingAcks.isEmpty else { return }
            guard self.isConnected, self.webSocketTask != nil else { return }
            
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
                        if acksToSend.count > 50 {
                            self?.logger.log("ACK", "✅ Sent BULK ACK for \(acksToSend.count) events")
                        }
                    } else {
                        self?.logger.logError("ACK", "❌ Failed to send ACK, re-queuing \(acksToSend.count) events")
                        self?.serialQueue.async {
                            self?.pendingAcks.insert(contentsOf: acksToSend, at: 0)
                        }
                    }
                }
            }
        }
    }
    
    private func startAckFlusher() {
        stopAckFlusher()
        
        let timer = DispatchSource.makeTimerSource(queue: serialQueue)
        timer.schedule(deadline: .now(), repeating: 0.1)
        timer.setEventHandler { [weak self] in
            self?.flushAcks()
        }
        timer.resume()
        ackTimer = timer
    }
    
    private func stopAckFlusher() {
        ackTimer?.cancel()
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
            
            self.logger.log("SUBSCRIPTION", "📤 Subscribing to \(subscriptions.count) channels")
            
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
            
            self.logger.log("SUBSCRIPTION", "Mode: \(resetConsumers ? "RESET" : "RESUME")")
            if resetConsumers {
                self.logger.log("SUBSCRIPTION", "⚠️ RESET MODE - Will delete old consumers")
            } else {
                self.logger.log("SUBSCRIPTION", "✅ RESUME MODE - \(syncState.count) channels with state")
            }
            
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
        
        let timer = DispatchSource.makeTimerSource(queue: serialQueue)
        timer.schedule(deadline: .now(), repeating: catchUpCheckInterval)
        timer.setEventHandler { [weak self] in
            self?.checkCatchUpProgress()
        }
        timer.resume()
        catchUpTimer = timer
    }
    
    private func stopCatchUpMonitoring() {
        catchUpTimer?.cancel()
        catchUpTimer = nil
    }
    
    // ✅ CRITICAL: Proper catch-up detection
    private func checkCatchUpProgress() {
        var allComplete = true
        
        for channelId in catchUpChannels {
            if ChannelSyncState.shared.isInCatchUpMode(channelId: channelId) {
                let progress = ChannelSyncState.shared.getCatchUpProgress(channelId: channelId)
                
                let queueEmpty = eventQueue.sync { queuedEvents.isEmpty }
                let notProcessing = !isProcessorActive
                
                if progress > 0 && queueEmpty && notProcessing {
                    let count = (consecutiveEmptyChecks[channelId] ?? 0) + 1
                    consecutiveEmptyChecks[channelId] = count
                    
                    if count >= stableEmptyThreshold {
                        ChannelSyncState.shared.disableCatchUpMode(channelId: channelId)
                        catchUpChannels.remove(channelId)
                        consecutiveEmptyChecks.removeValue(forKey: channelId)
                        logger.log("CATCHUP", "✅ Complete for \(channelId) (\(progress) events)")
                        
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .catchUpComplete, object: nil)
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
        }
    }
    
    // MARK: - Ping/Pong
    private func startPingPong() {
        stopPingPong()
        
        let timer = DispatchSource.makeTimerSource(queue: serialQueue)
        timer.schedule(deadline: .now(), repeating: pingInterval)
        timer.setEventHandler { [weak self] in
            self?.sendPing()
        }
        timer.resume()
        pingTimer = timer
    }
    
    private func stopPingPong() {
        pingTimer?.cancel()
        pingTimer = nil
    }
    
    private func sendPing() {
        webSocketTask?.sendPing { [weak self] error in
            if let error = error {
                self?.logger.logError("PING", "❌ Ping failed: \(error.localizedDescription)")
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
            
            self.logger.log("RECONNECT", "Reconnecting in \(Int(delay))s (attempt \(self.reconnectAttempts))")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.connect()
            }
        }
    }
    
    // MARK: - Message Sending
    private func send(message: String, completion: ((Bool) -> Void)? = nil) {
        let wsMessage = URLSessionWebSocketTask.Message.string(message)
        webSocketTask?.send(wsMessage) { [weak self] error in
            if let error = error {
                self?.logger.logError("SEND", "❌ Failed: \(error.localizedDescription)")
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
            
            let queueCount = self.eventQueue.sync { self.queuedEvents.count }
            let pendingAckCount = self.pendingAcks.count
            
            self.logger.log("STATS", """
                📊 Received: \(self.receivedCount), Queue: \(queueCount),
                Processed: \(self.processedCount), Dropped: \(self.droppedCount),
                ACKed: \(self.ackedCount), Errors: \(self.errorCount),
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