import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authManager: AuthManager
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @State private var showingLogout = false
    @State private var syncStats: [String: Any] = [:]
    @State private var refreshTrigger = UUID()
    
    var body: some View {
        NavigationView {
            List {
                // User Section
                Section(header: Text("Account")) {
                    if let user = authManager.currentUser {
                        HStack {
                            Text("Name")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(user.name)
                        }
                        
                        HStack {
                            Text("Phone")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(user.phone)
                        }
                        
                        HStack {
                            Text("Organization")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(user.organisation)
                        }
                    }
                    
                    Button(action: { showingLogout = true }) {
                        HStack {
                            Image(systemName: "arrow.right.square")
                                .foregroundColor(.red)
                            Text("Logout")
                                .foregroundColor(.red)
                        }
                    }
                }
                
                // Connection Status
                Section(header: Text("Connection")) {
                    HStack {
                        Circle()
                            .fill(webSocketService.isConnected ? Color.green : Color.red)
                            .frame(width: 12, height: 12)
                        Text(webSocketService.connectionStatus)
                        Spacer()
                    }
                    
                    Button("Force Reconnect") {
                        webSocketService.disconnect()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
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
                }
                
                // ✅ NEW: Sync Status Section
                Section(header: Text("Sync Status")) {
                    if let channelCount = syncStats["channelCount"] as? Int {
                        HStack {
                            Text("Synced Channels")
                            Spacer()
                            Text("\(channelCount)")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if let totalEvents = syncStats["totalEvents"] as? Int64 {
                        HStack {
                            Text("Total Received")
                            Spacer()
                            Text("\(totalEvents)")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Show per-channel stats
                    if let channels = syncStats["channels"] as? [[String: Any]] {
                        ForEach(channels.prefix(5), id: \.self as NSDictionary) { channel in
                            if let channelId = channel["channel"] as? String,
                               let lastSeq = channel["lastSeq"] as? Int64,
                               let highestSeq = channel["highestSeq"] as? Int64,
                               let totalReceived = channel["totalReceived"] as? Int64,
                               let catchUpMode = channel["catchUpMode"] as? Bool {
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(channelId)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    
                                    HStack {
                                        Text("Last Seq: \(lastSeq)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text("Highest: \(highestSeq)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    HStack {
                                        Text("Total: \(totalReceived)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        if catchUpMode {
                                            Text("CATCHING UP")
                                                .font(.caption)
                                                .fontWeight(.bold)
                                                .foregroundColor(.orange)
                                        } else {
                                            Text("LIVE")
                                                .font(.caption)
                                                .fontWeight(.bold)
                                                .foregroundColor(.green)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    
                    Button("Refresh Stats") {
                        loadSyncStats()
                    }
                }
                
                // Storage
                Section(header: Text("Storage")) {
                    Button("Clear All Data") {
                        clearAllData()
                    }
                    .foregroundColor(.red)
                }
                
                // App Info
                Section(header: Text("App Info")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Client ID")
                        Spacer()
                        Text(deviceId)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Logout", isPresented: $showingLogout) {
                Button("Cancel", role: .cancel) { }
                Button("Logout", role: .destructive) {
                    logout()
                }
            } message: {
                Text("Are you sure you want to logout?")
            }
            .onAppear {
                loadSyncStats()
            }
            .id(refreshTrigger)
        }
    }
    
    private var deviceId: String {
        if let uuid = UIDevice.current.identifierForVendor?.uuidString {
            return "ios-\(uuid.prefix(8))"
        }
        return "unknown"
    }
    
    private func loadSyncStats() {
        syncStats = ChannelSyncState.shared.getStats()
        refreshTrigger = UUID()
    }
    
    private func clearAllData() {
        // Clear subscriptions
        for channel in subscriptionManager.subscribedChannels {
            subscriptionManager.unsubscribe(channelId: channel.id)
        }
        
        // Clear sync state
        ChannelSyncState.shared.clearAll()
        
        // Force save
        subscriptionManager.forceSave()
        
        refreshTrigger = UUID()
    }
    
    private func logout() {
        // Save state before logout
        subscriptionManager.forceSave()
        ChannelSyncState.shared.forceSave()
        
        // Disconnect WebSocket
        webSocketService.disconnect()
        
        // Logout
        authManager.logout { success in
            if success {
                print("✅ Logged out successfully")
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(AuthManager.shared)
    }
}