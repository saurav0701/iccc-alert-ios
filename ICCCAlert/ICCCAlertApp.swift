import SwiftUI

@main
struct ICCCAlertApp: App {
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    
    @Environment(\.scenePhase) var scenePhase
    
    // CRITICAL: Memory monitoring
    @State private var memoryMonitorTimer: Timer?
    
    init() {
        setupAppearance()
        _ = BackgroundWebSocketManager.shared
        _ = MemoryMonitor.shared
        
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
        
        // Register for memory warnings
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            ICCCAlertApp.handleMemoryWarning()
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
                        startProactiveMemoryMonitoring()
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
    
    // MARK: - Proactive Memory Monitoring (NEW - CRITICAL)
    
    private func startProactiveMemoryMonitoring() {
        // Monitor memory every 15 seconds
        memoryMonitorTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { _ in
            checkAndCleanMemory()
        }
    }
    
    private func checkAndCleanMemory() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let usedMemoryMB = Double(info.resident_size) / 1024 / 1024
            
            print("💾 Memory: \(String(format: "%.1f", usedMemoryMB)) MB")
            
            // CRITICAL: Proactive cleanup at 180MB (before reaching 200MB threshold)
            if usedMemoryMB > 180 {
                print("⚠️ Memory approaching threshold - proactive cleanup")
                performProactiveCleanup()
            }
            
            // CRITICAL: Emergency cleanup at 220MB
            if usedMemoryMB > 220 {
                print("🚨 CRITICAL MEMORY - Emergency cleanup")
                ICCCAlertApp.handleMemoryWarning()
            }
        }
    }
    
    private func performProactiveCleanup() {
        // Clear thumbnail memory cache (keep disk cache)
        ThumbnailCacheManager.shared.clearChannelThumbnails()
        
        // Clear image caches
        EventImageLoader.shared.clearCache()
        
        // Clear URL cache
        URLCache.shared.removeAllCachedResponses()
        
        // Force autoreleasepool drain
        autoreleasepool {}
        
        print("🧹 Proactive cleanup complete")
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
            startProactiveMemoryMonitoring()
            
        case .inactive:
            print("📱 App became inactive")
            // CRITICAL: Stop all active streams immediately
            PlayerManager.shared.clearAll()
            
        case .background:
            print("📱 App moved to background")
            saveAppState()
            
            // CRITICAL: Aggressive cleanup for background
            PlayerManager.shared.clearAll()
            ThumbnailCacheManager.shared.clearChannelThumbnails()
            EventImageLoader.shared.clearCache()
            URLCache.shared.removeAllCachedResponses()
            
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
        ThumbnailCacheManager.shared.clearAllThumbnails()
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
        ThumbnailCacheManager.shared.clearChannelThumbnails()
        
        SubscriptionManager.shared.forceSave()
        ChannelSyncState.shared.forceSave()
        WebSocketService.shared.disconnect()
        
        print("✅ Termination cleanup complete")
    }
    
    // MARK: - Memory Warning Handler
    
    private static func handleMemoryWarning() {
        print("⚠️ MEMORY WARNING - EMERGENCY CLEANUP")
        
        // 1. Stop all active streams IMMEDIATELY
        PlayerManager.shared.clearAll()
        
        // 2. Clear ALL caches
        ThumbnailCacheManager.shared.clearChannelThumbnails()
        EventImageLoader.shared.clearCache()
        
        // 3. Clear URL cache
        URLCache.shared.removeAllCachedResponses()
        
        // 4. Force multiple autoreleasepool drains
        for _ in 0..<3 {
            autoreleasepool {}
        }
        
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