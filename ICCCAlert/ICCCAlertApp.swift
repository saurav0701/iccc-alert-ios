import SwiftUI

@main
struct ICCCAlertApp: App {
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    
    @Environment(\.scenePhase) var scenePhase
    
    // ✅ Memory pressure monitoring
    @State private var memoryWarningCount = 0
    
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
        
        // ✅ Register for memory warnings (CRITICAL)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            ICCCAlertApp.handleMemoryWarning()
        }
        
        // ✅ Setup low memory handler
        setupLowMemoryHandler()
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
                            // Clean up all resources
                            cleanupAllResources()
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
            
            // ✅ CRITICAL: Aggressive cleanup on inactive
            cleanupVideoResources()
            
        case .background:
            print("📱 App moved to background")
            
            // ✅ CRITICAL: Full cleanup in background
            cleanupVideoResources()
            saveAppState()
            
            NotificationManager.shared.updateBadgeCount()
            
        @unknown default:
            break
        }
    }
    
    // ✅ Clean up video resources (players + thumbnails)
    private func cleanupVideoResources() {
        print("🧹 Cleaning up video resources...")
        
        // 1. Stop all video players
        PlayerManager.shared.clearAll()
        
        // 2. Stop all thumbnail captures
        ThumbnailCacheManager.shared.stopAllCaptures()
        
        // 3. Clear memory cache (keep disk cache)
        ThumbnailCacheManager.shared.clearChannelThumbnails()
        
        print("✅ Video resources cleaned")
    }
    
    // ✅ Clean up ALL resources (logout)
    private func cleanupAllResources() {
        print("🧹 Cleaning up ALL resources...")
        
        PlayerManager.shared.clearAll()
        ThumbnailCacheManager.shared.stopAllCaptures()
        ThumbnailCacheManager.shared.clearChannelThumbnails()
        EventImageLoader.shared.clearCache()
        
        print("✅ All resources cleaned")
    }
    
    // ✅ Handle app termination
    private static func handleAppTermination() {
        print("🛑 App will terminate - cleaning up resources")
        
        // Clean up video resources
        PlayerManager.shared.clearAll()
        ThumbnailCacheManager.shared.stopAllCaptures()
        
        // Save state
        SubscriptionManager.shared.forceSave()
        ChannelSyncState.shared.forceSave()
        WebSocketService.shared.disconnect()
        
        print("✅ Resources cleaned up")
    }
    
    // ✅ Handle memory warnings (CRITICAL)
    private static func handleMemoryWarning() {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("⚠️ MEMORY WARNING - EMERGENCY CLEANUP")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // 1. Stop ALL video players immediately
        PlayerManager.shared.clearAll()
        
        // 2. Stop ALL thumbnail captures immediately
        ThumbnailCacheManager.shared.stopAllCaptures()
        
        // 3. Clear ALL image caches
        ThumbnailCacheManager.shared.clearChannelThumbnails()
        EventImageLoader.shared.clearCache()
        
        // 4. Force garbage collection
        autoreleasepool {
            // Empty pool to release autorelease objects
        }
        
        print("🧹 Emergency cleanup complete")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }
    
    // ✅ Setup proactive low memory handler
    private func setupLowMemoryHandler() {
        // Monitor memory usage every 10 seconds
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            autoreleasepool {
                let memoryUsage = self.getMemoryUsage()
                
                // If using more than 200MB, proactively clean up
                if memoryUsage > 200 * 1024 * 1024 {
                    print("⚠️ High memory usage: \(memoryUsage / 1024 / 1024)MB - Proactive cleanup")
                    
                    // Cleanup in background
                    DispatchQueue.global(qos: .background).async {
                        ThumbnailCacheManager.shared.clearChannelThumbnails()
                        EventImageLoader.shared.clearCache()
                    }
                }
            }
        }
    }
    
    // ✅ Get current memory usage
    private func getMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return info.resident_size
        }
        
        return 0
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