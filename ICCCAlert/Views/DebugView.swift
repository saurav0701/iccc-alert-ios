import SwiftUI

struct DebugView: View {
    @StateObject private var webSocketService = WebSocketService.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    
    @State private var refreshTrigger = UUID()
    
    var syncStats: [String: Any] {
        ChannelSyncState.shared.getStats()
    }
    
    var body: some View {
        NavigationView {
            List {
                // Connection Status
                Section(header: Text("Connection")) {
                    HStack {
                        Circle()
                            .fill(webSocketService.isConnected ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        
                        Text("Status")
                        Spacer()
                        Text(webSocketService.connectionStatus)
                            .foregroundColor(.secondary)
                    }
                    
                    Button("Reconnect") {
                        webSocketService.disconnect()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            webSocketService.connect()
                        }
                    }
                }
                
                // Subscriptions
                Section(header: Text("Subscriptions")) {
                    HStack {
                        Text("Active Channels")
                        Spacer()
                        Text("\(subscriptionManager.subscribedChannels.count)")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Total Events")
                        Spacer()
                        Text("\(subscriptionManager.getTotalEventCount())")
                            .foregroundColor(.secondary)
                    }
                    
                    Button("Force Update") {
                        webSocketService.sendSubscriptionV2()
                    }
                }
                
                // Sync State
                Section(header: Text("Synchronization")) {
                    if let channelCount = syncStats["channelCount"] as? Int,
                       let totalEvents = syncStats["totalEvents"] as? Int64 {
                        HStack {
                            Text("Synced Channels")
                            Spacer()
                            Text("\(channelCount)")
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Text("Total Received")
                            Spacer()
                            Text("\(totalEvents)")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if let channels = syncStats["channels"] as? [[String: Any]] {
                        ForEach(channels.indices, id: \.self) { index in
                            let channel = channels[index]
                            if let channelId = channel["channel"] as? String,
                               let highestSeq = channel["highestSeq"] as? Int64,
                               let totalReceived = channel["totalReceived"] as? Int64 {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(channelId)
                                        .font(.caption)
                                    Text("Seq: \(highestSeq) | Events: \(totalReceived)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                
                // Actions
                Section(header: Text("Actions")) {
                    Button("Clear All Data") {
                        clearAllData()
                    }
                    .foregroundColor(.red)
                    
                    Button("Force Save") {
                        subscriptionManager.forceSave()
                        ChannelSyncState.shared.forceSave()
                    }
                    
                    Button("Refresh") {
                        refreshTrigger = UUID()
                    }
                }
            }
            .navigationTitle("Debug")
            .id(refreshTrigger)
        }
    }
    
    private func clearAllData() {
        // Unsubscribe from all
        for channel in subscriptionManager.subscribedChannels {
            subscriptionManager.unsubscribe(channelId: channel.id)
        }
        
        // Clear sync state
        ChannelSyncState.shared.clearAll()
        
        // Force save
        subscriptionManager.forceSave()
        
        // Reconnect
        webSocketService.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            webSocketService.connect()
        }
        
        refreshTrigger = UUID()
    }
}