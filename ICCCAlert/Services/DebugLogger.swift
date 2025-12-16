import Foundation

class DebugLogger {
    static let shared = DebugLogger()
    
    private let fileManager = FileManager.default
    private let logFileName = "iccc_debug.txt"
    private var logFileURL: URL?
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.iccc.debuglogger", qos: .utility)
    
    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        setupLogFile()
    }
    
    private func setupLogFile() {
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Failed to get documents directory")
            return
        }
        
        logFileURL = documentsDirectory.appendingPathComponent(logFileName)
        
        // Create new log file
        let header = """
        ================================
        ICCC Alert App Debug Log
        Started: \(dateFormatter.string(from: Date()))
        ================================
        
        """
        
        try? header.write(to: logFileURL!, atomically: true, encoding: .utf8)
        
        print("✅ Debug log file created at: \(logFileURL!.path)")
        log("SYSTEM", "Debug logger initialized")
    }
    
    func log(_ tag: String, _ message: String) {
        queue.async { [weak self] in
            guard let self = self, let url = self.logFileURL else { return }
            
            let timestamp = self.dateFormatter.string(from: Date())
            let logLine = "[\(timestamp)] [\(tag)] \(message)\n"
            
            // Also print to console
            print(logLine.trimmingCharacters(in: .whitespacesAndNewlines))
            
            // Write to file
            if let data = logLine.data(using: .utf8) {
                if let fileHandle = try? FileHandle(forWritingTo: url) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }
    
    func logEvent(_ event: Event, action: String) {
        let message = """
        \(action)
        - ID: \(event.id ?? "nil")
        - Area: \(event.area ?? "nil")
        - Type: \(event.type ?? "nil")
        - Timestamp: \(event.timestamp)
        - Location: \(event.location)
        - ChannelID: \(event.channelName ?? "nil")
        """
        log("EVENT", message)
    }
    
    func logSubscription(_ channel: Channel, action: String) {
        let message = """
        \(action)
        - ID: \(channel.id)
        - Area: \(channel.area)
        - Type: \(channel.eventType)
        - Subscribed: \(channel.isSubscribed)
        """
        log("SUBSCRIPTION", message)
    }
    
    func logWebSocket(_ message: String) {
        log("WEBSOCKET", message)
    }
    
    func logError(_ tag: String, _ message: String) {
        log("ERROR-\(tag)", message)
    }
    
    func getLogFileURL() -> URL? {
        return logFileURL
    }
    
    func getLogContents() -> String {
        guard let url = logFileURL,
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "No logs available"
        }
        return contents
    }
    
    func clearLogs() {
        guard let url = logFileURL else { return }
        try? FileManager.default.removeItem(at: url)
        setupLogFile()
        log("SYSTEM", "Logs cleared")
    }
    
    func shareLogs() -> URL? {
        return logFileURL
    }
}

// MARK: - Convenience Extensions

extension DebugLogger {
    func logChannelEvents() {
        let manager = SubscriptionManager.shared
        let channels = manager.subscribedChannels
        
        log("DEBUG", "=== CHANNEL EVENTS DUMP ===")
        log("DEBUG", "Total subscribed channels: \(channels.count)")
        
        for channel in channels {
            let events = manager.getEvents(channelId: channel.id)
            let unread = manager.getUnreadCount(channelId: channel.id)
            
            log("DEBUG", """
            Channel: \(channel.id)
            - Area: \(channel.areaDisplay)
            - Type: \(channel.eventTypeDisplay)
            - Events: \(events.count)
            - Unread: \(unread)
            - Is Muted: \(channel.isMuted)
            """)
            
            if events.isEmpty {
                log("DEBUG", "  ⚠️ NO EVENTS IN THIS CHANNEL!")
            } else {
                log("DEBUG", "  Last event: \(events.first?.id ?? "nil") at \(events.first?.timestamp ?? 0)")
            }
        }
        
        log("DEBUG", "=== END CHANNEL EVENTS DUMP ===")
    }
    
    func logWebSocketStatus() {
        let ws = WebSocketService.shared
        log("DEBUG", """
        === WEBSOCKET STATUS ===
        - Connected: \(ws.isConnected)
        - Status: \(ws.connectionStatus)
        - Received: \(ws.receivedCount)
        - Processed: \(ws.processedCount)
        - Dropped: \(ws.droppedCount)
        - Acked: \(ws.ackedCount)
        === END WEBSOCKET STATUS ===
        """)
    }
}