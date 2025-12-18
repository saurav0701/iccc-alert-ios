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
                    DebugStatRow(label: "Received", value: "\(webSocketService.receivedCount)")
                    DebugStatRow(label: "Processed", value: "\(webSocketService.processedCount)")
                    DebugStatRow(label: "Dropped", value: "\(webSocketService.droppedCount)")
                    DebugStatRow(label: "Errors", value: "\(webSocketService.errorCount)")
                    DebugStatRow(label: "ACKed", value: "\(webSocketService.ackedCount)")
                }
                
                // Subscription Stats
                Section(header: Text("Subscriptions")) {
                    DebugStatRow(label: "Channels", value: "\(subscriptionManager.subscribedChannels.count)")
                    DebugStatRow(label: "Total Events", value: "\(subscriptionManager.getTotalEventCount())")
                    
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
                    DebugStatRow(label: "Synced Channels", value: "\(states.count)")
                    
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
        UserDefaults.standard.removeObject(forKey: "subscribed_channels")
        UserDefaults.standard.removeObject(forKey: "channel_events")
        UserDefaults.standard.removeObject(forKey: "unread_counts")
        
        ChannelSyncState.shared.clearAll()
        
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

// Renamed to avoid conflict
struct DebugStatRow: View {
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