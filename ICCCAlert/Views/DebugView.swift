import SwiftUI

struct DebugView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @State private var refreshTrigger = UUID()
    
    var body: some View {
        NavigationView {
            List {
                // WebSocket Status
                Section(header: Text("Connection")) {
                    HStack {
                        Circle()
                            .fill(webSocketService.isConnected ? Color.green : Color.red)
                            .frame(width: 12, height: 12)
                        Text(webSocketService.isConnected ? "Connected" : "Disconnected")
                    }
                    
                    Button("Reconnect") {
                        webSocketService.disconnect()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            webSocketService.connect()
                        }
                    }
                    
                    Button("Send Subscription") {
                        webSocketService.sendSubscriptionV2()
                    }
                }
                
                // Subscriptions
                Section(header: Text("Subscriptions (\(subscriptionManager.subscribedChannels.count))")) {
                    ForEach(subscriptionManager.subscribedChannels) { channel in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(channel.id)
                                .font(.headline)
                            Text("\(channel.areaDisplay) - \(channel.eventTypeDisplay)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack {
                                Text("Events: \(subscriptionManager.getEvents(channelId: channel.id).count)")
                                    .font(.caption)
                                Spacer()
                                Text("Unread: \(subscriptionManager.getUnreadCount(channelId: channel.id))")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
                
                // Events
                Section(header: Text("All Events (\(subscriptionManager.getTotalEventCount()))")) {
                    ForEach(subscriptionManager.subscribedChannels) { channel in
                        let events = subscriptionManager.getEvents(channelId: channel.id)
                        if !events.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(channel.id)
                                    .font(.system(size: 14, weight: .bold))
                                
                                ForEach(events.prefix(3)) { event in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.id ?? "no-id")
                                            .font(.system(size: 12))
                                        Text(event.location)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(6)
                                    .background(Color(.systemGray6))
                                    .cornerRadius(4)
                                }
                            }
                        }
                    }
                }
                
                // Actions
                Section(header: Text("Actions")) {
                    Button("Force Save") {
                        subscriptionManager.forceSave()
                        ChannelSyncState.shared.forceSave()
                    }
                    
                    Button("Clear Sync State") {
                        ChannelSyncState.shared.clearAll()
                    }
                    .foregroundColor(.orange)
                }
            }
            .navigationTitle("Debug")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { refreshTrigger = UUID() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .id(refreshTrigger)
        }
    }
}