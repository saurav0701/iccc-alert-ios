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
        
        NotificationManager.shared.requestAuthorization()
        NotificationManager.shared.setupNotificationCategories()
        
        // Register for app termination
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            ICCCAlertApp.handleAppTermination()
        }
        
        print("🚀 ICCCAlertApp initialized")
    }
    
    var body: some Scene {
        WindowGroup {
            if authManager.isAuthenticated {
                ContentView()
                    .environmentObject(authManager)
                    .environmentObject(webSocketService)
                    .environmentObject(subscriptionManager)
                    .onAppear {
                        print("🚀 ContentView appeared - User authenticated")
                        connectWebSocket()
                    }
            } else {
                LoginView()
                    .environmentObject(authManager)
                    .onAppear {
                        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                        print("🔐 LOGIN VIEW APPEARED")
                        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                    }
                    .onChange(of: authManager.isAuthenticated) { isAuth in
                        if isAuth {
                            let deviceClientId: String = {
                                if let uuid = UIDevice.current.identifierForVendor?.uuidString {
                                    return "ios-\(uuid.prefix(8))"
                                }
                                return "ios-unknown"
                            }()
                            
                            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                            print("✅ OTP VERIFIED - USER AUTHENTICATED")
                            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                            print("   - clientId: \(deviceClientId)")
                            print("   - Connecting WebSocket...")
                            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                self.connectWebSocket()
                            }
                        } else {
                            print("🔐 USER LOGGED OUT")
                        }
                    }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(newPhase)
        }
    }
    
    // MARK: - WebSocket Connection
    
    private func connectWebSocket() {
        guard authManager.isAuthenticated else {
            print("⚠️ Not authenticated, skipping WebSocket")
            return
        }
        
        if !webSocketService.isConnected {
            print("🔌 Starting WebSocket...")
            webSocketService.connect()
        } else {
            print("ℹ️ WebSocket already connected")
        }
    }
    
    // MARK: - Scene Phase Changes
    
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            print("📱 App became active")
            if authManager.isAuthenticated && !webSocketService.isConnected {
                print("🔄 Reconnecting WebSocket...")
                webSocketService.connect()
            }
            NotificationManager.shared.updateBadgeCount()
            
        case .inactive:
            print("📱 App became inactive")
            // Stop all active streams immediately
            PlayerManager.shared.clearAll()
            
        case .background:
            print("📱 App moved to background")
            saveAppState()
            
            // ✅ FIXED: Only basic cleanup for background
            PlayerManager.shared.clearAll()
            
            // Stop memory monitoring
            memoryMonitorTimer?.invalidate()
            memoryMonitorTimer = nil
            
            NotificationManager.shared.updateBadgeCount()
            
            print("🧹 Background cleanup complete")
            
        @unknown default:
            break
        }
    }
    
    // MARK: - Logout Handler
    
    private func handleLogout() {
        print("🔐 Handling logout - full cleanup")
        
        // Stop memory monitoring
        memoryMonitorTimer?.invalidate()
        memoryMonitorTimer = nil
        
        // Stop all streams
        PlayerManager.shared.clearAll()
        
        // Clear all caches
        EventImageLoader.shared.clearCache()
        URLCache.shared.removeAllCachedResponses()
        
        // Disconnect WebSocket
        WebSocketService.shared.disconnect()
        
        print("✅ Logout cleanup complete")
    }
    
    // MARK: - App Termination Handler
    
    private static func handleAppTermination() {
        print("🛑 App terminating - cleanup")
        
        PlayerManager.shared.clearAll()
        
        SubscriptionManager.shared.forceSave()
        ChannelSyncState.shared.forceSave()
        WebSocketService.shared.disconnect()
        
        print("✅ Termination cleanup complete")
    }
    
    // MARK: - Memory Warning Handler (ONLY FOR CRITICAL WARNINGS)
    
    private static func handleMemoryWarning() {
        print("⚠️ SYSTEM MEMORY WARNING - Emergency cleanup")
        
        // 1. Stop all active streams IMMEDIATELY
        PlayerManager.shared.clearAll()
        
        // 2. Clear image cache
        EventImageLoader.shared.clearCache()
        
        // 3. Clear URL cache
        URLCache.shared.removeAllCachedResponses()
        
        // 4. Force autoreleasepool drain
        autoreleasepool {}
        
        print("🧹 Emergency cleanup complete")
    }
    
    // MARK: - State Persistence
    
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