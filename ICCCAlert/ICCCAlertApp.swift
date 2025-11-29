import SwiftUI

@main
struct ICCCAlertApp: App {
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    
    @Environment(\.scenePhase) var scenePhase
    
    init() {
        setupAppearance()
    }
    
    var body: some Scene {
        WindowGroup {
            if authManager.isAuthenticated {
                ContentView()
                    .environmentObject(authManager)
                    .environmentObject(webSocketService)
                    .environmentObject(subscriptionManager)
                    .onAppear {
                        connectWebSocket()
                    }
            } else {
                LoginView()
                    .environmentObject(authManager)
            }
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(newPhase)
        }
    }
    
    // MARK: - WebSocket Lifecycle
    
    private func connectWebSocket() {
        if authManager.isAuthenticated && !webSocketService.isConnected {
            print("🚀 Starting WebSocket connection...")
            webSocketService.connect()
        }
    }
    
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            print("📱 App became active")
            if authManager.isAuthenticated && !webSocketService.isConnected {
                webSocketService.connect()
            }
            
        case .inactive:
            print("📱 App became inactive")
            
        case .background:
            print("📱 App moved to background")
            subscriptionManager.forceSave()
            ChannelSyncState.shared.forceSave()
            
        @unknown default:
            break
        }
    }
    
    // MARK: - Appearance Setup
    
    private func setupAppearance() {
        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithOpaqueBackground()
        navBarAppearance.backgroundColor = .systemBackground
        navBarAppearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        navBarAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.label]
        
        UINavigationBar.appearance().standardAppearance = navBarAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navBarAppearance
        UINavigationBar.appearance().compactAppearance = navBarAppearance
        
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = .systemBackground
        
        UITabBar.appearance().standardAppearance = tabBarAppearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
        }
    }
}

// MARK: - Main Content View

struct MainContentView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var webSocketService: WebSocketService
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            AlertsView()
                .tabItem {
                    Label("Alerts", systemImage: selectedTab == 0 ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                }
                .tag(0)
            
            ChannelsView()
                .tabItem {
                    Label("Channels", systemImage: selectedTab == 1 ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                }
                .tag(1)
            
            StatsView()
                .tabItem {
                    Label("Stats", systemImage: selectedTab == 2 ? "chart.bar.fill" : "chart.bar")
                }
                .tag(2)
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: selectedTab == 3 ? "gear.circle.fill" : "gear")
                }
                .tag(3)
        }
    }
}

// MARK: - Stats View

struct StatsView: View {
    @EnvironmentObject var webSocketService: WebSocketService
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Connection")) {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(webSocketService.isConnected ? Color.green : Color.red)
                                .frame(width: 10, height: 10)
                            Text(webSocketService.isConnected ? "Connected" : "Disconnected")
                                .foregroundColor(webSocketService.isConnected ? .green : .red)
                        }
                    }
                    
                    HStack {
                        Text("Client ID")
                        Spacer()
                        Text(UserDefaults.standard.string(forKey: "persistent_client_id") ?? "N/A")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text("Event Processing")) {
                    StatRow(label: "Received", value: "\(webSocketService.receivedCount)")
                    StatRow(label: "Processed", value: "\(webSocketService.processedCount)")
                    StatRow(label: "Acknowledged", value: "\(webSocketService.ackedCount)")
                    StatRow(label: "Dropped", value: "\(webSocketService.droppedCount)")
                    StatRow(label: "Errors", value: "\(webSocketService.errorCount)")
                }
                
                Section(header: Text("Subscriptions")) {
                    StatRow(label: "Channels", value: "\(subscriptionManager.subscribedChannels.count)")
                    StatRow(label: "Total Events", value: "\(subscriptionManager.getTotalEventCount())")
                    
                    let unreadTotal = subscriptionManager.subscribedChannels.reduce(0) { total, channel in
                        total + subscriptionManager.getUnreadCount(channelId: channel.id)
                    }
                    StatRow(label: "Unread", value: "\(unreadTotal)")
                }
                
                Section(header: Text("Sync State")) {
                    let totalReceived = ChannelSyncState.shared.getTotalEventsReceived()
                    StatRow(label: "Total Tracked", value: "\(totalReceived)")
                    
                    let states = ChannelSyncState.shared.getAllSyncStates()
                    StatRow(label: "Synced Channels", value: "\(states.count)")
                }
                
                Section {
                    Button(action: {
                        if webSocketService.isConnected {
                            webSocketService.disconnect()
                        } else {
                            webSocketService.connect()
                        }
                    }) {
                        HStack {
                            Spacer()
                            Text(webSocketService.isConnected ? "Disconnect" : "Connect")
                                .foregroundColor(webSocketService.isConnected ? .red : .blue)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Statistics")
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