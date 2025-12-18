import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authManager: AuthManager
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @State private var showingLogout = false
    @State private var syncStats: [String: Any] = [:]
    
    var body: some View {
        NavigationView {
            List {
                accountSection
                connectionSection
                subscriptionsSection
                syncStatusSection
                storageSection
                appInfoSection
            }
            .navigationTitle("Settings")
            .alert(isPresented: $showingLogout) {
                Alert(
                    title: Text("Logout"),
                    message: Text("Are you sure you want to logout?"),
                    primaryButton: .cancel(),
                    secondaryButton: .destructive(Text("Logout")) {
                        logout()
                    }
                )
            }
            .onAppear {
                loadSyncStats()
            }
        }
    }
    
    // MARK: - Account Section
    
    private var accountSection: some View {
        Section(header: Text("Account")) {
            if let user = authManager.currentUser {
                userInfoRow(title: "Name", value: user.name)
                userInfoRow(title: "Phone", value: user.phone)
                userInfoRow(title: "Organization", value: user.organisation)
            }
            
            logoutButton
        }
    }
    
    private func userInfoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
    }
    
    private var logoutButton: some View {
        Button(action: { showingLogout = true }) {
            HStack {
                Image(systemName: "arrow.right.square")
                    .foregroundColor(.red)
                Text("Logout")
                    .foregroundColor(.red)
            }
        }
    }
    
    // MARK: - Connection Section
    
    private var connectionSection: some View {
        Section(header: Text("Connection")) {
            connectionStatusRow
            reconnectButton
        }
    }
    
    private var connectionStatusRow: some View {
        HStack {
            Circle()
                .fill(webSocketService.isConnected ? Color.green : Color.red)
                .frame(width: 12, height: 12)
            Text(webSocketService.connectionStatus)
            Spacer()
        }
    }
    
    private var reconnectButton: some View {
        Button("Force Reconnect") {
            webSocketService.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                webSocketService.connect()
            }
        }
    }
    
    // MARK: - Subscriptions Section
    
    private var subscriptionsSection: some View {
        Section(header: Text("Subscriptions")) {
            statsRow(title: "Active Channels", value: "\(subscriptionManager.subscribedChannels.count)")
            statsRow(title: "Total Events", value: "\(subscriptionManager.getTotalEventCount())")
        }
    }
    
    private func statsRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Sync Status Section
    
    private var syncStatusSection: some View {
        Section(header: Text("Sync Status")) {
            Group {
                if let channelCount = syncStats["channelCount"] as? Int {
                    statsRow(title: "Synced Channels", value: "\(channelCount)")
                }
                
                if let totalEvents = syncStats["totalEvents"] as? Int64 {
                    statsRow(title: "Total Received", value: "\(totalEvents)")
                }
            }
            
            channelStatsView
            
            Button("Refresh Stats") {
                loadSyncStats()
            }
        }
    }
    
    private var channelStatsView: some View {
        Group {
            if let channels = syncStats["channels"] as? [[String: Any]] {
                ForEach(Array(channels.prefix(5).enumerated()), id: \.offset) { index, channel in
                    channelStatRow(channel: channel)
                }
            }
        }
    }
    
    private func channelStatRow(channel: [String: Any]) -> some View {
        Group {
            if let channelId = channel["channel"] as? String,
               let lastSeq = channel["lastSeq"] as? Int64,
               let highestSeq = channel["highestSeq"] as? Int64,
               let totalReceived = channel["totalReceived"] as? Int64,
               let catchUpMode = channel["catchUpMode"] as? Bool {
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(channelId)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    sequenceInfoRow(lastSeq: lastSeq, highestSeq: highestSeq)
                    statusInfoRow(totalReceived: totalReceived, catchUpMode: catchUpMode)
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    private func sequenceInfoRow(lastSeq: Int64, highestSeq: Int64) -> some View {
        HStack {
            Text("Last Seq: \(lastSeq)")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text("Highest: \(highestSeq)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private func statusInfoRow(totalReceived: Int64, catchUpMode: Bool) -> some View {
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
    
    // MARK: - Storage Section
    
    private var storageSection: some View {
        Section(header: Text("Storage")) {
            Button("Clear All Data") {
                clearAllData()
            }
            .foregroundColor(.red)
        }
    }
    
    // MARK: - App Info Section
    
    private var appInfoSection: some View {
        Section(header: Text("App Info")) {
            statsRow(title: "Version", value: "1.0.0")
            
            HStack {
                Text("Client ID")
                Spacer()
                Text(deviceId)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Helper Properties
    
    private var deviceId: String {
        if let uuid = UIDevice.current.identifierForVendor?.uuidString {
            return "ios-\(uuid.prefix(8))"
        }
        return "unknown"
    }
    
    // MARK: - Actions
    
    private func loadSyncStats() {
        // ✅ FIX 2: Use background queue to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async {
            let stats = ChannelSyncState.shared.getStats()
            
            DispatchQueue.main.async {
                self.syncStats = stats
            }
        }
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
        
        // Reload stats
        loadSyncStats()
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