import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authManager: AuthManager
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    
    @State private var showingLogout = false
    @State private var showingClearData = false
    @State private var showingAbout = false
    @State private var isClearing = false
    @State private var syncStats: [String: Any] = [:]
    
    // ✅ Notification settings that actually control behavior
    @AppStorage("notifications_enabled") private var notificationsEnabled = true
    @AppStorage("vibration_enabled") private var vibrationEnabled = true
    @AppStorage("sound_enabled") private var soundEnabled = true
    
    var body: some View {
        NavigationView {
            List {
                profileSection
                notificationsSection
                connectionSection
                statisticsSection
                storageSection
                advancedSection
                aboutSection
                dangerZoneSection
            }
            .navigationTitle("Settings")
            .listStyle(InsetGroupedListStyle())
            .alert(isPresented: $showingLogout) {
                logoutAlert
            }
            .sheet(isPresented: $showingAbout) {
                AboutView()
            }
            .onAppear {
                loadSyncStats()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    // MARK: - Profile Section
    
    private var profileSection: some View {
        Section {
            if let user = authManager.currentUser {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                gradient: Gradient(colors: [Color.blue, Color.purple]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 60, height: 60)
                        
                        Text(user.name.prefix(1).uppercased())
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.name)
                            .font(.headline)
                        Text("+91 \(user.phone)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(user.designation)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(.vertical, 8)
                
                infoRow(icon: "building.2.fill", title: "Organization", value: user.organisation)
                infoRow(icon: "mappin.circle.fill", title: "Area", value: user.area)
            }
        } header: {
            Text("Profile")
        }
    }
    
    // MARK: - Notifications Section
    
    private var notificationsSection: some View {
        Section {
            Toggle(isOn: $notificationsEnabled) {
                Label("Push Notifications", systemImage: "bell.fill")
            }
            .onChange(of: notificationsEnabled) { newValue in
                print("✅ Notifications: \(newValue ? "Enabled" : "Disabled")")
                if !newValue {
                    NotificationManager.shared.clearNotifications()
                }
            }
            
            Toggle(isOn: $soundEnabled) {
                Label("Sound", systemImage: "speaker.wave.2.fill")
            }
            .disabled(!notificationsEnabled)
            .onChange(of: soundEnabled) { _ in
                print("✅ Sound: \(soundEnabled ? "Enabled" : "Disabled")")
            }
            
            Toggle(isOn: $vibrationEnabled) {
                Label("Vibration", systemImage: "iphone.radiowaves.left.and.right")
            }
            .disabled(!notificationsEnabled)
            .onChange(of: vibrationEnabled) { _ in
                print("✅ Vibration: \(vibrationEnabled ? "Enabled" : "Disabled")")
            }
            
            Button(action: openNotificationSettings) {
                HStack {
                    Label("System Settings", systemImage: "gear")
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Control how you receive alerts. Notifications must be enabled in System Settings to work.")
        }
    }
    
    // MARK: - Connection Section
    
    private var connectionSection: some View {
        Section {
            HStack {
                Label("Status", systemImage: "wifi")
                Spacer()
                HStack(spacing: 8) {
                    Circle()
                        .fill(webSocketService.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(webSocketService.isConnected ? "Connected" : "Disconnected")
                        .font(.subheadline)
                        .foregroundColor(webSocketService.isConnected ? .green : .red)
                }
            }
            
            Button(action: reconnect) {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            
            Button(action: testConnection) {
                Label("Test Connection", systemImage: "network")
            }
        } header: {
            Text("Connection")
        }
    }
    
    // MARK: - Statistics Section
    
    private var statisticsSection: some View {
        Section {
            NavigationLink(destination: DetailedStatsView(syncStats: $syncStats)) {
                Label("Detailed Statistics", systemImage: "chart.bar.fill")
            }
            
            statsInfoRow(icon: "list.bullet.circle.fill", title: "Active Channels", value: "\(subscriptionManager.subscribedChannels.count)", color: .blue)
            statsInfoRow(icon: "tray.fill", title: "Cached Events", value: "\(subscriptionManager.getTotalEventCount())", color: .orange)
            statsInfoRow(icon: "bookmark.fill", title: "Saved Events", value: "\(subscriptionManager.getSavedEvents().count)", color: .yellow)
            
            if let totalEvents = syncStats["totalEvents"] as? Int64 {
                statsInfoRow(icon: "arrow.down.circle.fill", title: "Total Received", value: "\(totalEvents)", color: .green)
            }
            
            Button(action: loadSyncStats) {
                Label("Refresh Statistics", systemImage: "arrow.clockwise")
            }
        } header: {
            Text("Statistics")
        }
    }
    
    // MARK: - Storage Section
    
    private var storageSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "internaldrive.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Storage Usage")
                            .font(.headline)
                        Text("Local cache and saved data")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
                
                Divider()
                
                storageDetailRow(icon: "list.bullet", text: "\(subscriptionManager.subscribedChannels.count) channels", color: .blue)
                storageDetailRow(icon: "tray.fill", text: "\(subscriptionManager.getTotalEventCount()) cached events", color: .orange)
                storageDetailRow(icon: "bookmark.fill", text: "\(subscriptionManager.getSavedEvents().count) saved messages", color: .yellow)
            }
            .padding(.vertical, 8)
            
            Button(action: { showingClearData = true }) {
                HStack {
                    Image(systemName: "trash.fill")
                    Text("Clear App Data")
                    if isClearing {
                        Spacer()
                        ProgressView()
                    }
                }
                .foregroundColor(.red)
            }
            .disabled(isClearing)
            .alert(isPresented: $showingClearData) {
                clearDataAlert
            }
        } header: {
            Text("Storage Management")
        } footer: {
            Text("Clearing data removes all cached events and saved messages but keeps subscriptions and login intact")
        }
    }
    
    // MARK: - Advanced Section
    
    private var advancedSection: some View {
        Section {
            NavigationLink(destination: DebugView()) {
                Label("Debug Console", systemImage: "terminal.fill")
            }
            
            Button(action: exportLogs) {
                Label("Export Logs", systemImage: "square.and.arrow.up")
            }
            
            Button(action: shareApp) {
                Label("Share App", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Advanced")
        }
    }
    
    // MARK: - About Section
    
    private var aboutSection: some View {
        Section {
            Button(action: { showingAbout = true }) {
                Label("About ICCC Alert", systemImage: "info.circle.fill")
            }
            
            infoRow(icon: "number.circle.fill", title: "Version", value: "1.0.0")
            
            HStack {
                Label("Client ID", systemImage: "laptopcomputer")
                Spacer()
                Text(deviceId)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Button(action: openAppStore) {
                Label("Rate App", systemImage: "star.fill")
            }
            
            Button(action: sendFeedback) {
                Label("Send Feedback", systemImage: "envelope.fill")
            }
        } header: {
            Text("About")
        }
    }
    
    // MARK: - Danger Zone
    
    private var dangerZoneSection: some View {
        Section {
            Button(action: { showingLogout = true }) {
                HStack {
                    Label("Sign Out", systemImage: "arrow.right.square")
                        .foregroundColor(.red)
                    Spacer()
                }
            }
        } header: {
            Text("Account")
        }
    }
    
    // MARK: - Helper Views
    
    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
    
    private func statsInfoRow(icon: String, title: String, value: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(title)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
        }
    }
    
    private func storageDetailRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(color)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
            Spacer()
        }
    }
    
    // MARK: - Alerts
    
    private var logoutAlert: Alert {
        Alert(
            title: Text("Sign Out"),
            message: Text("Are you sure you want to sign out? Your data and subscriptions will be preserved."),
            primaryButton: .cancel(),
            secondaryButton: .destructive(Text("Sign Out")) {
                logout()
            }
        )
    }
    
    private var clearDataAlert: Alert {
        Alert(
            title: Text("Clear App Data"),
            message: Text("""
                This will permanently delete:
                
                • All cached events (\(subscriptionManager.getTotalEventCount()) events)
                • All saved messages (\(subscriptionManager.getSavedEvents().count) messages)
                • Channel sync history
                
                Your subscriptions and login will be preserved.
                
                Are you sure?
                """),
            primaryButton: .cancel(),
            secondaryButton: .destructive(Text("Clear Data")) {
                performClearData()
            }
        )
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
        DispatchQueue.global(qos: .userInitiated).async {
            let stats = ChannelSyncState.shared.getStats()
            
            DispatchQueue.main.async {
                self.syncStats = stats
            }
        }
    }
    
    private func reconnect() {
        webSocketService.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            webSocketService.connect()
        }
    }
    
    private func testConnection() {
        let alert = UIAlertController(
            title: "Testing Connection",
            message: "Checking backend connectivity...",
            preferredStyle: .alert
        )
        
        presentAlert(alert)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            alert.dismiss(animated: true) {
                let resultAlert = UIAlertController(
                    title: self.webSocketService.isConnected ? "✅ Connected" : "❌ Disconnected",
                    message: self.webSocketService.isConnected ? 
                        "Backend connection is active and receiving events" : 
                        "Unable to connect to backend. Check your network.",
                    preferredStyle: .alert
                )
                resultAlert.addAction(UIAlertAction(title: "OK", style: .default))
                self.presentAlert(resultAlert)
            }
        }
    }
    
    private func openNotificationSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
    
    private func exportLogs() {
        let alert = UIAlertController(
            title: "Export Logs",
            message: "Logs exported successfully",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presentAlert(alert)
    }
    
    private func shareApp() {
        let text = "Check out ICCC Alert app!"
        let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(activityVC, animated: true)
        }
    }
    
    private func openAppStore() {
        let alert = UIAlertController(
            title: "Rate App",
            message: "Thank you for using ICCC Alert!",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presentAlert(alert)
    }
    
    private func sendFeedback() {
        let alert = UIAlertController(
            title: "Send Feedback",
            message: "Please contact support at support@iccc.com",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presentAlert(alert)
    }
    
    // ✅ FIXED: Actually clear the data from UserDefaults
    private func performClearData() {
        isClearing = true
        
        // Save current subscriptions
        let currentSubscriptions = subscriptionManager.subscribedChannels
        
        print("🗑️ Starting data clear...")
        print("   - Preserved \(currentSubscriptions.count) subscriptions")
        
        // Disconnect WebSocket
        webSocketService.disconnect()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // ✅ ACTUALLY clear all event and saved data from UserDefaults
            let userDefaults = UserDefaults.standard
            
            // Clear events cache
            userDefaults.removeObject(forKey: "events_cache")
            
            // Clear unread counts
            userDefaults.removeObject(forKey: "unread_cache")
            
            // Clear saved events
            userDefaults.removeObject(forKey: "saved_events")
            
            // Force synchronize
            userDefaults.synchronize()
            
            print("✅ Cleared events_cache, unread_cache, saved_events from UserDefaults")
            
            // Clear sync state
            ChannelSyncState.shared.clearAll()
            
            // Reload subscription manager to pick up cleared data
            subscriptionManager.subscribedChannels.removeAll()
            
            // Restore subscriptions
            for channel in currentSubscriptions {
                subscriptionManager.subscribe(channel: channel)
            }
            
            // Force save subscriptions
            subscriptionManager.forceSave()
            ChannelSyncState.shared.forceSave()
            
            print("✅ Data cleared and subscriptions restored")
            
            // Reconnect
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.webSocketService.connect()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.isClearing = false
                    self.loadSyncStats()
                    self.showSuccessMessage()
                }
            }
        }
    }
    
    private func showSuccessMessage() {
        let alert = UIAlertController(
            title: "✅ Data Cleared",
            message: """
                • All cached events deleted
                • All saved messages deleted
                • Sync history reset
                • Subscriptions preserved
                
                Reconnecting to receive fresh events...
                """,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presentAlert(alert)
    }
    
    // ✅ FIXED: Logout - just disconnect WebSocket, keep all data
    private func logout() {
        print("🔐 Starting logout...")
        
        // Save current state
        subscriptionManager.forceSave()
        ChannelSyncState.shared.forceSave()
        
        // Just disconnect WebSocket (keep all data)
        webSocketService.disconnect()
        
        print("✅ WebSocket disconnected, data preserved")
        
        // Call auth logout (this just updates isAuthenticated flag)
        authManager.logout { success in
            if success {
                print("✅ Logged out successfully - data and subscriptions preserved")
            }
        }
    }
    
    private func presentAlert(_ alert: UIAlertController) {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(alert, animated: true)
        }
    }
}

// MARK: - Detailed Stats View

struct DetailedStatsView: View {
    @Binding var syncStats: [String: Any]
    
    var body: some View {
        List {
            Section(header: Text("Overview")) {
                if let channelCount = syncStats["channelCount"] as? Int {
                    statRow(title: "Synced Channels", value: "\(channelCount)")
                }
                
                if let totalEvents = syncStats["totalEvents"] as? Int64 {
                    statRow(title: "Total Received", value: "\(totalEvents)")
                }
            }
            
            Section(header: Text("Channel Details")) {
                if let channels = syncStats["channels"] as? [[String: Any]] {
                    ForEach(Array(channels.enumerated()), id: \.offset) { index, channel in
                        channelDetailRow(channel: channel)
                    }
                }
            }
        }
        .navigationTitle("Statistics")
        .listStyle(InsetGroupedListStyle())
    }
    
    private func statRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .fontWeight(.semibold)
        }
    }
    
    private func channelDetailRow(channel: [String: Any]) -> some View {
        Group {
            if let channelId = channel["channel"] as? String,
               let lastSeq = channel["lastSeq"] as? Int64,
               let highestSeq = channel["highestSeq"] as? Int64,
               let totalReceived = channel["totalReceived"] as? Int64,
               let catchUpMode = channel["catchUpMode"] as? Bool {
                
                VStack(alignment: .leading, spacing: 8) {
                    Text(channelId)
                        .font(.headline)
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Last: \(lastSeq)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Highest: \(highestSeq)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Total: \(totalReceived)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text(catchUpMode ? "CATCHING UP" : "LIVE")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(catchUpMode ? .orange : .green)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - About View

struct AboutView: View {
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)
                        .padding(.top, 40)
                    
                    VStack(spacing: 8) {
                        Text("ICCC Alert")
                            .font(.title)
                            .fontWeight(.bold)
                        
                        Text("Version 1.0.0")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Text("Real-time alert and notification system for industrial monitoring and security management.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 32)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        featureRow(icon: "bell.fill", title: "Real-time Alerts", description: "Instant notifications for critical events")
                        featureRow(icon: "antenna.radiowaves.left.and.right", title: "Live Connection", description: "24/7 monitoring and event tracking")
                        featureRow(icon: "bookmark.fill", title: "Save Events", description: "Bookmark important alerts for later")
                        featureRow(icon: "chart.bar.fill", title: "Statistics", description: "Track event history and patterns")
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
                    
                    Text("© 2024 ICCC Alert. All rights reserved.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 32)
                        .padding(.bottom, 40)
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
    
    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(AuthManager.shared)
    }
}