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
    
    private let baseURL = "ws://192.168.29.70:19999"
    
    private var clientId: String {
        if let uuid = UIDevice.current.identifierForVendor?.uuidString {
            return "ios-\(String(uuid.prefix(8)))"
        }
        return "ios-unknown"
    }
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }
    
    func connect() {
        guard webSocketTask == nil else {
            DebugLogger.shared.log("WebSocket already exists", emoji: "⚠️", color: .orange)
            return
        }
        
        guard let url = URL(string: "\(baseURL)/ws") else {
            DebugLogger.shared.log("Invalid URL", emoji: "❌", color: .red)
            return
        }
        
        DebugLogger.shared.log("Connecting... clientId=\(clientId)", emoji: "🔌", color: .blue)
        
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        receiveMessage()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if self.webSocketTask?.state == .running {
                self.isConnected = true
                self.connectionStatus = "Connected"
                DebugLogger.shared.log("Connected successfully", emoji: "✅", color: .green)
                self.startPing()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.sendSubscription()
                }
            } else {
                DebugLogger.shared.log("Connection failed", emoji: "❌", color: .red)
            }
        }
    }
    
    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        pingTimer?.invalidate()
        DebugLogger.shared.log("Disconnected", emoji: "🔌", color: .gray)
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    DebugLogger.shared.log("Received: \(text.prefix(100))...", emoji: "📥", color: .blue)
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        DebugLogger.shared.log("Received: \(text.prefix(100))...", emoji: "📥", color: .blue)
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()
                
            case .failure(let error):
                DebugLogger.shared.log("WebSocket error: \(error.localizedDescription)", emoji: "❌", color: .red)
                self.isConnected = false
            }
        }
    }
    
    private func handleMessage(_ text: String) {
        // Skip confirmations
        if text.contains("\"status\":\"subscribed\"") {
            DebugLogger.shared.log("Subscription confirmed", emoji: "✅", color: .green)
            return
        }
        
        // Parse event
        guard let data = text.data(using: .utf8) else {
            DebugLogger.shared.log("Failed to convert to data", emoji: "❌", color: .red)
            return
        }
        
        guard let event = try? JSONDecoder().decode(Event.self, from: data) else {
            DebugLogger.shared.log("Failed to decode JSON", emoji: "❌", color: .red)
            return
        }
        
        guard let eventId = event.id,
              let area = event.area,
              let type = event.type else {
            DebugLogger.shared.log("Event missing required fields", emoji: "❌", color: .red)
            return
        }
        
        let channelId = "\(area)_\(type)"
        DebugLogger.shared.log("Event received: \(channelId) - \(eventId)", emoji: "🔔", color: .purple)
        
        // Check if subscribed
        if !SubscriptionManager.shared.isSubscribed(channelId: channelId) {
            DebugLogger.shared.log("Not subscribed to \(channelId)", emoji: "⏭️", color: .orange)
            sendAck(eventId: eventId)
            return
        }
        
        DebugLogger.shared.log("Subscribed to \(channelId), adding event", emoji: "✅", color: .green)
        
        // Add event
        let added = SubscriptionManager.shared.addEvent(event)
        
        if added {
            DebugLogger.shared.log("Event added successfully", emoji: "💾", color: .green)
            
            // Notify UI
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .newEventReceived,
                    object: nil,
                    userInfo: ["channelId": channelId, "eventId": eventId]
                )
                DebugLogger.shared.log("UI notification posted", emoji: "📢", color: .blue)
            }
        } else {
            DebugLogger.shared.log("Event rejected (duplicate)", emoji: "⏭️", color: .orange)
        }
        
        sendAck(eventId: eventId)
    }
    
    private func sendAck(eventId: String) {
        let msg: [String: Any] = [
            "type": "ack",
            "eventId": eventId,
            "clientId": clientId
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }
        
        webSocketTask?.send(.string(str)) { error in
            if let error = error {
                DebugLogger.shared.log("ACK failed: \(error.localizedDescription)", emoji: "❌", color: .red)
            }
        }
    }
    
    private func sendSubscription() {
        let subscriptions = SubscriptionManager.shared.subscribedChannels
        
        guard !subscriptions.isEmpty else {
            DebugLogger.shared.log("No subscriptions to send", emoji: "⚠️", color: .orange)
            return
        }
        
        let filters = subscriptions.map { channel -> [String: String] in
            return ["area": channel.area, "eventType": channel.eventType]
        }
        
        let request: [String: Any] = [
            "clientId": clientId,
            "filters": filters,
            "resetConsumers": true
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let str = String(data: data, encoding: .utf8) else {
            DebugLogger.shared.log("Failed to serialize subscription", emoji: "❌", color: .red)
            return
        }
        
        DebugLogger.shared.log("Sending subscription: \(subscriptions.count) channels", emoji: "📤", color: .blue)
        
        webSocketTask?.send(.string(str)) { error in
            if let error = error {
                DebugLogger.shared.log("Subscription failed: \(error.localizedDescription)", emoji: "❌", color: .red)
            } else {
                DebugLogger.shared.log("Subscription sent successfully", emoji: "✅", color: .green)
            }
        }
    }
    
    func sendSubscriptionV2() {
        sendSubscription()
    }
    
    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.webSocketTask?.sendPing { _ in }
        }
    }
}

extension Notification.Name {
    static let newEventReceived = Notification.Name("newEventReceived")
}