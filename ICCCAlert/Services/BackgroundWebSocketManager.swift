import Foundation
import BackgroundTasks
import UIKit

/// ✅ Background WebSocket Manager
/// Handles persistent connection even when app is in background
class BackgroundWebSocketManager {
    static let shared = BackgroundWebSocketManager()
    
    private let backgroundTaskIdentifier = "com.icccalert.websocket.refresh"
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    private init() {
        setupBackgroundHandling()
    }
    
    // MARK: - Setup
    
    func setupBackgroundHandling() {
        // Register background task
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskIdentifier,
            using: nil
        ) { task in
            self.handleBackgroundTask(task: task as! BGAppRefreshTask)
        }
        
        // Monitor app lifecycle
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    // MARK: - App Lifecycle Handlers
    
    @objc private func appWillResignActive() {
        print("📱 App will resign active - keeping WebSocket alive")
        startBackgroundTask()
    }
    
    @objc private func appDidEnterBackground() {
        print("📱 App entered background - scheduling background refresh")
        scheduleBackgroundRefresh()
        
        // Save state
        SubscriptionManager.shared.forceSave()
        ChannelSyncState.shared.forceSave()
    }
    
    @objc private func appWillEnterForeground() {
        print("📱 App will enter foreground - reconnecting WebSocket")
        endBackgroundTask()
        
        // Reconnect if needed
        if !WebSocketService.shared.isConnected {
            WebSocketService.shared.connect()
        }
    }
    
    // MARK: - Background Task Management
    
    private func startBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
        
        print("🔄 Background task started: \(backgroundTask)")
    }
    
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        
        print("⏹️ Background task ended: \(backgroundTask)")
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    
    // MARK: - Background Refresh
    
    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("✅ Background refresh scheduled")
        } catch {
            print("❌ Failed to schedule background refresh: \(error)")
        }
    }
    
    private func handleBackgroundTask(task: BGAppRefreshTask) {
        print("🔄 Background refresh task started")
        
        // Schedule next refresh
        scheduleBackgroundRefresh()
        
        // Reconnect WebSocket if needed
        if !WebSocketService.shared.isConnected {
            WebSocketService.shared.connect()
        }
        
        // Complete the task
        task.setTaskCompleted(success: true)
    }
}

// MARK: - Info.plist Configuration Required
/*
 Add the following to Info.plist:
 
 <key>BGTaskSchedulerPermittedIdentifiers</key>
 <array>
     <string>com.icccalert.websocket.refresh</string>
 </array>
 
 <key>UIBackgroundModes</key>
 <array>
     <string>fetch</string>
     <string>remote-notification</string>
     <string>processing</string>
 </array>
 */