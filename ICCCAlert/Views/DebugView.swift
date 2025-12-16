import SwiftUI

struct DebugView: View {
    @StateObject private var webSocketService = WebSocketService.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var logs: [String] = []
    @State private var autoRefresh = true
    
    var body: some View {
        NavigationView {
            List {
                // Connection Section
                Section(header: Text("WebSocket Status")) {
                    HStack {
                        Text("Connected")
                        Spacer()
                        Circle()
                            .fill(webSocketService.isConnected ? Color.green : Color.red)
                            .frame(width: 12, height: 12)
                        Text(webSocketService.isConnected ? "Yes" : "No")
                            .foregroundColor(webSocketService.isConnected ? .green : .red)
                    }
                    
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(webSocketService.connectionStatus)
                            .foregroundColor(.secondary)
                    }
                    
                    Button(webSocketService.isConnected ? "Disconnect" : "Connect") {
                        if webSocketService.isConnected {
                            webSocketService.disconnect()
                        } else {
                            webSocketService.connect()
                        }
                    }
                }
                
                // Event Stats
                Section(header: Text("Event Statistics")) {
                    StatRow(label: "Received", value: "\(webSocketService.receivedCount)")
                    StatRow(label: "Processed", value: "\(webSocketService.processedCount)")
                    StatRow(label: "Dropped", value: "\(webSocketService.droppedCount)")
                    StatRow(label: "Errors", value: "\(webSocketService.errorCount)")
                    StatRow(label: "ACKed", value: "\(webSocketService.ackedCount)")
                }
                
                // Subscription Stats
                Section(header: Text("Subscriptions")) {
                    StatRow(label: "Channels", value: "\(subscriptionManager.subscribedChannels.count)")
                    StatRow(label: "Total Events", value: "\(subscriptionManager.getTotalEventCount())")
                    
                    ForEach(subscriptionManager.subscribedChannels) { channel in
                        let eventCount = subscriptionManager.getEventCount(channelId: channel.id)
                        let unreadCount = subscriptionManager.getUnreadCount(channelId: channel.id)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(channel.areaDisplay) - \(channel.eventTypeDisplay)")
                                .font(.subheadline)
                            HStack {
                                Text("Events: \(eventCount)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("Unread: \(unreadCount)")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                // Sync State
                Section(header: Text("Sync State")) {
                    let states = ChannelSyncState.shared.getAllSyncStates()
                    StatRow(label: "Synced Channels", value: "\(states.count)")
                    
                    ForEach(Array(states.keys.sorted()), id: \.self) { channelId in
                        if let state = states[channelId] {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(channelId)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                HStack {
                                    Text("Seq: \(state.highestSeq)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("Total: \(state.totalReceived)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                
                // Actions
                Section(header: Text("Actions")) {
                    Button("Force Refresh") {
                        subscriptionManager.forceSave()
                        ChannelSyncState.shared.forceSave()
                    }
                    
                    Button("Clear All Data") {
                        clearAllData()
                    }
                    .foregroundColor(.red)
                    
                    Button("Test Notification") {
                        testNotification()
                    }
                }
                
                // Logs
                Section(header: HStack {
                    Text("Recent Logs")
                    Spacer()
                    Toggle("Auto Refresh", isOn: $autoRefresh)
                        .labelsHidden()
                }) {
                    ForEach(logs.suffix(20).reversed(), id: \.self) { log in
                        Text(log)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Debug Info")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Export Logs") {
                        exportLogs()
                    }
                }
            }
        }
        .onAppear {
            loadLogs()
            if autoRefresh {
                startAutoRefresh()
            }
        }
    }
    
    private func loadLogs() {
        // Get logs from DebugLogger
        logs = DebugLogger.shared.getAllLogs()
    }
    
    private func startAutoRefresh() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            if autoRefresh {
                loadLogs()
            }
        }
    }
    
    private func clearAllData() {
        // Clear all stored data
        UserDefaults.standard.removeObject(forKey: "subscribed_channels")
        UserDefaults.standard.removeObject(forKey: "channel_events")
        UserDefaults.standard.removeObject(forKey: "unread_counts")
        
        ChannelSyncState.shared.clearAll()
        
        // Reconnect
        webSocketService.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            webSocketService.connect()
        }
    }
    
    private func testNotification() {
        NotificationCenter.default.post(
            name: .newEventReceived,
            object: nil,
            userInfo: [
                "channelId": "test_channel",
                "event": Event(
                    id: "test_\(UUID().uuidString)",
                    timestamp: Int64(Date().timeIntervalSince1970),
                    source: "test",
                    area: "test",
                    areaDisplay: "Test Area",
                    type: "cd",
                    typeDisplay: "Test Event",
                    groupId: nil,
                    vehicleNumber: nil,
                    vehicleTransporter: nil,
                    data: ["location": AnyCodable("Test Location")],
                    isRead: false
                )
            ]
        )
    }
    
    private func exportLogs() {
        let logsText = logs.joined(separator: "\n")
        let activityVC = UIActivityViewController(
            activityItems: [logsText],
            applicationActivities: nil
        )
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootVC = window.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }
}

struct StatRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundColor(.blue)
        }
    }
}

// Debug Logger Helper
class DebugLogger {
    static let shared = DebugLogger()
    
    private var logs: [String] = []
    private let maxLogs = 500
    private let lock = NSLock()
    
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