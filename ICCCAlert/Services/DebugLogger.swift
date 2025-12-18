import Foundation

class DebugLogger {
    static let shared = DebugLogger()
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    
    private var logs: [String] = []
    private let maxLogs = 1000
    
    private init() {}
    
    func log(_ category: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let logMessage = "[\(timestamp)] [\(category)] \(message)"
        
        logs.append(logMessage)
        
        // Keep only recent logs
        if logs.count > maxLogs {
            logs.removeFirst(logs.count - maxLogs)
        }
        
        print(logMessage)
    }
    
    func logConnection(_ status: String, _ details: String = "") {
        log("CONNECTION", "\(status) \(details)")
    }
    
    func logEvent(_ action: String, _ event: Event) {
        // ✅ FIXED: Use typeDisplay instead of title
        log("EVENT", "\(action): \(event.id ?? "unknown") - \(event.typeDisplay ?? event.type ?? "unknown")")
    }
    
    // ✅ FIXED: Removed direct access to private properties
    func logWebSocketStats() {
        // Stats are now logged directly in WebSocketService
        log("STATS", "Check WebSocketService console output")
    }
    
    func logSubscription(_ channel: String, _ action: String) {
        log("SUBSCRIPTION", "\(action): \(channel)")
    }
    
    // ✅ FIXED: Use proper method name
    func logStorage() {
        let sm = SubscriptionManager.shared
        log("STORAGE", "Total events: \(sm.getTotalEventCount())")
        
        for channel in sm.subscribedChannels {
            // ✅ FIXED: Get events and count them
            let events = sm.getEvents(channelId: channel.id)
            let count = events.count
            let unread = sm.getUnreadCount(channelId: channel.id)
            log("STORAGE", "  \(channel.id): \(count) events, \(unread) unread")
        }
    }
    
    func getLogs() -> [String] {
        return logs
    }
    
    func clearLogs() {
        logs.removeAll()
    }
    
    func exportLogs() -> String {
        return logs.joined(separator: "\n")
    }
}