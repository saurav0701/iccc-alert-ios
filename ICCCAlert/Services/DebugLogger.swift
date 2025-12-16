import Foundation

class DebugLogger {
    static let shared = DebugLogger()
    
    private var logs: [String] = []
    private let maxLogs = 500
    private let lock = NSLock()
    
    private init() {
        log("INIT", "DebugLogger initialized")
    }
    
    func log(_ category: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logMessage = "[\(timestamp)] [\(category)] \(message)"
        
        logs.append(logMessage)
        
        if logs.count > maxLogs {
            logs.removeFirst(logs.count - maxLogs)
        }
        
        print(logMessage)
    }
    
    func logError(_ category: String, _ message: String) {
        log(category, "❌ \(message)")
    }
    
    func logWebSocket(_ message: String) {
        log("WS", message)
    }
    
    func logEvent(_ event: Event, action: String) {
        log("EVENT", "\(action): \(event.id ?? "unknown") - \(event.title)")
    }
    
    func logWebSocketStatus() {
        let ws = WebSocketService.shared
        log("STATUS", """
            Connected: \(ws.isConnected)
            Received: \(ws.receivedCount)
            Processed: \(ws.processedCount)
            Dropped: \(ws.droppedCount)
            """)
    }
    
    func logChannelEvents() {
        let sm = SubscriptionManager.shared
        log("CHANNELS", "Total events stored: \(sm.getTotalEventCount())")
        
        for channel in sm.subscribedChannels {
            let count = sm.getEventCount(channelId: channel.id)
            log("CHANNEL", "\(channel.id): \(count) events")
        }
    }
    
    func getAllLogs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return logs
    }
    
    func clearLogs() {
        lock.lock()
        defer { lock.unlock() }
        logs.removeAll()
    }
}