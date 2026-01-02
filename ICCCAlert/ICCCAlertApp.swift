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
        
        // ✅ Register for app termination
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            ICCCAlertApp.handleAppTermination()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            ICCCAlertApp.handleMemoryWarning()
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
                        print("🚀 ContentView appeared - User is authenticated")
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
                            handleLogout()
                        }
                    }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(newPhase)
        }
    }
    
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
            NotificationManager.shared.updateBadgeCount()
            
        case .inactive:
            print("📱 App became inactive")
            PlayerManager.shared.clearAll()
            
        case .background:
            print("📱 App moved to background")
            saveAppState()
    
            PlayerManager.shared.clearAll()

            ThumbnailCacheManager.shared.clearChannelThumbnails()
            
            NotificationManager.shared.updateBadgeCount()
            
        @unknown default:
            break
        }
    }

    private func handleLogout() {
        print("🔐 Handling logout - cleaning up all resources")

        PlayerManager.shared.clearAll()
 
        ThumbnailCacheManager.shared.clearAllThumbnails()

        EventImageLoader.shared.clearCache()
        
        print("✅ Logout cleanup complete")
    }
  
    private static func handleAppTermination() {
        print("🛑 App will terminate - cleaning up resources")

        PlayerManager.shared.clearAll()
 
        ThumbnailCacheManager.shared.clearChannelThumbnails()

        SubscriptionManager.shared.forceSave()
        ChannelSyncState.shared.forceSave()
        WebSocketService.shared.disconnect()
        
        print("✅ Resources cleaned up")
    }
    
    private static func handleMemoryWarning() {
        print("⚠️ MEMORY WARNING - Aggressive cleanup")
        
        PlayerManager.shared.clearAll()
        
        // 2. Clear thumbnail memory cache (keep disk cache for recovery)
        ThumbnailCacheManager.shared.clearChannelThumbnails()
        
        // 3. Clear image caches
        EventImageLoader.shared.clearCache()
        
        // 4. Force URLCache cleanup
        URLCache.shared.removeAllCachedResponses()
        
        print("🧹 Memory cleanup complete")
    }
    
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