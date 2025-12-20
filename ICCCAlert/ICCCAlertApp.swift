import SwiftUI

@main
struct ICCCAlertApp: App {
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    
    @Environment(\.scenePhase) var scenePhase
    
    init() {
        setupAppearance()
        _ = BackgroundWebSocketManager.shared
        
        // ✅ Setup notifications
        NotificationManager.shared.requestAuthorization()
        NotificationManager.shared.setupNotificationCategories()
        
        // ✅ Register for app termination notification
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            ICCCAlertApp.handleAppTermination()
        }
    }
    
    var body: some Scene {
        WindowGroup {
            if authManager.isAuthenticated {
                ContentView()
                    .environmentObject(authManager)
                    .environmentObject(webSocketService)
                    .environmentObject(subscriptionManager)
                    .onAppear {
                        print("🚀 ContentView appeared, starting WebSocket")
                        connectWebSocket()
                    }
            } else {
                LoginView()
                    .environmentObject(authManager)
                    .onChange(of: authManager.isAuthenticated) { isAuth in
                        if isAuth {
                            print("✅ User authenticated, connecting WebSocket")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                connectWebSocket()
                            }
                        }
                    }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(newPhase)
        }
    }
    
    // MARK: - WebSocket Lifecycle
    
    private func connectWebSocket() {
        guard authManager.isAuthenticated else {
            print("⚠️ Not authenticated, skipping WebSocket connection")
            return
        }
        
        if !webSocketService.isConnected {
            print("🔌 Starting WebSocket connection...")
            webSocketService.connect()
        } else {
            print("ℹ️ WebSocket already connected")
        }
    }
    
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            print("📱 App became active")
            if authManager.isAuthenticated && !webSocketService.isConnected {
                print("🔄 Reconnecting WebSocket...")
                webSocketService.connect()
            }
            
            // ✅ Clear badge when app opens
            NotificationManager.shared.updateBadgeCount()
            
        case .inactive:
            print("📱 App became inactive")
            
        case .background:
            print("📱 App moved to background")
            saveAppState()
            
            // ✅ Update badge count
            NotificationManager.shared.updateBadgeCount()
            
        @unknown default:
            break
        }
    }
    
    // ✅ Handle app termination
    private static func handleAppTermination() {
        print("🛑 App will terminate - saving state")
        
        SubscriptionManager.shared.forceSave()
        ChannelSyncState.shared.forceSave()
        WebSocketService.shared.disconnect()
        
        print("✅ App state saved on termination")
    }
    
    // ✅ Force save app state
    private func saveAppState() {
        print("💾 Saving app state...")
        subscriptionManager.forceSave()
        ChannelSyncState.shared.forceSave()
        print("✅ App state saved")
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