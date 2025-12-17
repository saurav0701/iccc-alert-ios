import SwiftUI

struct DebugView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    
    var body: some View {
        NavigationView {
            List {
                // WebSocket Status
                Section(header: Text("WebSocket Status")) {
                    statusRow(label: "Connected", value: webSocketService.isConnected ? "Yes" : "No")
                    statusRow(label: "Status", value: webSocketService.connectionStatus)
                    statusRow(label: "Received", value: "\(webSocketService.receivedCount)")
                    statusRow(label: "Processed", value: "\(webSocketService.processedCount)")
                    statusRow(label: "Dropped", value: "\(webSocketService.droppedCount)")
                    statusRow(label: "ACKed", value: "\(webSocketService.ackedCount)")
                }
                
                // Subscriptions
                Section(header: Text("Subscriptions")) {
                    ForEach(subscriptionManager.subscribedChannels) { channel in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(channel.areaDisplay) - \(channel.eventTypeDisplay)")
                                .font(.headline)
                            HStack {
                                Text("Events: \(subscriptionManager.getEventCount(channelId: channel.id))")
                                    .font(.caption)
                                Spacer()
                                Text("Unread: \(subscriptionManager.getUnreadCount(channelId: channel.id))")
                                    .font(.caption)
                            }
                            .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                // Sync State
                Section(header: Text("Sync State")) {
                    let syncStates = ChannelSyncState.shared.getAllSyncStates()
                    ForEach(Array(syncStates.keys.sorted()), id: \.self) { channelId in
                        if let info = syncStates[channelId] {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(channelId)
                                    .font(.headline)
                                Text("Last Seq: \(info.lastEventSeq)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("Highest Seq: \(info.highestSeq)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("Total: \(info.totalReceived)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                
                // Actions
                Section(header: Text("Actions")) {
                    Button("Force Reconnect") {
                        webSocketService.disconnect()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            webSocketService.connect()
                        }
                    }
                    
                    Button("Clear All Data") {
                        ChannelSyncState.shared.clearAll()
                        subscriptionManager.forceSave()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Debug Info")
        }
    }
    
    private func statusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}