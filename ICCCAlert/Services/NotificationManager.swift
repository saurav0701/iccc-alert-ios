import Foundation
import UserNotifications
import UIKit

/// ✅ Local Notification Manager with Settings Support
class NotificationManager: NSObject {
    static let shared = NotificationManager()
    
    private let notificationCenter = UNUserNotificationCenter.current()
    private var isAuthorized = false
    
    // Track last notification time per channel to avoid spam
    private var lastNotificationTime: [String: TimeInterval] = [:]
    private let minNotificationInterval: TimeInterval = 3.0
    
    private override init() {
        super.init()
        notificationCenter.delegate = self
    }
    
    // MARK: - Settings Helpers
    
    private func areNotificationsEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: "notifications_enabled")
    }
    
    private func isSoundEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: "sound_enabled")
    }
    
    private func isVibrationEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: "vibration_enabled")
    }
    
    // MARK: - Request Permission
    
    func requestAuthorization() {
        notificationCenter.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.isAuthorized = granted
                
                if granted {
                    print("✅ Notification permission granted")
                    UIApplication.shared.registerForRemoteNotifications()
                    
                    // Set default to enabled
                    if UserDefaults.standard.object(forKey: "notifications_enabled") == nil {
                        UserDefaults.standard.set(true, forKey: "notifications_enabled")
                    }
                    if UserDefaults.standard.object(forKey: "sound_enabled") == nil {
                        UserDefaults.standard.set(true, forKey: "sound_enabled")
                    }
                    if UserDefaults.standard.object(forKey: "vibration_enabled") == nil {
                        UserDefaults.standard.set(true, forKey: "vibration_enabled")
                    }
                } else {
                    print("❌ Notification permission denied")
                }
                
                if let error = error {
                    print("❌ Notification permission error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Check Permission Status
    
    func checkAuthorizationStatus(completion: @escaping (Bool) -> Void) {
        notificationCenter.getNotificationSettings { settings in
            DispatchQueue.main.async {
                let authorized = settings.authorizationStatus == .authorized
                self.isAuthorized = authorized
                completion(authorized)
            }
        }
    }
    
    // MARK: - Send Event Notification
    
    func sendEventNotification(event: Event, channel: Channel) {
        // ✅ Check if notifications are enabled in app settings
        guard areNotificationsEnabled() else {
            print("🔕 Notifications disabled in app settings")
            return
        }
        
        // Check if authorized
        guard isAuthorized else {
            print("⚠️ Notifications not authorized in system")
            return
        }
        
        // Check if channel is muted
        if SubscriptionManager.shared.isChannelMuted(channelId: channel.id) {
            print("🔇 Channel \(channel.id) is muted, skipping notification")
            return
        }
        
        // Rate limiting per channel
        let now = Date().timeIntervalSince1970
        if let lastTime = lastNotificationTime[channel.id],
           (now - lastTime) < minNotificationInterval {
            print("⏱️ Too soon for another notification on \(channel.id)")
            return
        }
        lastNotificationTime[channel.id] = now
        
        // Create notification content
        let content = UNMutableNotificationContent()
        
        // Title based on event type
        if event.isGpsEvent {
            content.title = "🚨 \(event.typeDisplay ?? "GPS Alert")"
        } else {
            content.title = "🔔 \(channel.eventTypeDisplay)"
        }
        
        // Body based on event type
        if event.isGpsEvent {
            var bodyText = ""
            if let vehicle = event.vehicleNumber {
                bodyText = "Vehicle: \(vehicle)"
            }
            if let transporter = event.vehicleTransporter {
                if !bodyText.isEmpty { bodyText += " • " }
                bodyText += transporter
            }
            if let area = event.areaDisplay ?? event.area {
                if !bodyText.isEmpty { bodyText += "\n" }
                bodyText += "📍 \(area)"
            }
            content.body = bodyText
        } else {
            content.body = event.location
        }
        
        // Subtitle
        if let area = event.areaDisplay ?? event.area {
            content.subtitle = area
        }
        
        // ✅ Sound (respect settings)
        if isSoundEnabled() {
            content.sound = .default
        } else {
            content.sound = nil
        }
        
        // ✅ Vibration is handled by iOS automatically if sound is enabled
        // We can't directly control vibration, but iOS vibrates with sound by default
        
        // Badge (increment)
        let unreadCount = SubscriptionManager.shared.subscribedChannels
            .map { SubscriptionManager.shared.getUnreadCount(channelId: $0.id) }
            .reduce(0, +)
        content.badge = NSNumber(value: unreadCount)
        
        // User info for handling tap
        content.userInfo = [
            "channelId": channel.id,
            "eventId": event.id ?? "",
            "eventType": event.type ?? "",
            "isGpsEvent": event.isGpsEvent
        ]
        
        // Category for actions
        content.categoryIdentifier = event.isGpsEvent ? "GPS_EVENT" : "CAMERA_EVENT"
        
        // Thread ID for grouping
        content.threadIdentifier = channel.id
        
        // Create request with unique identifier
        let identifier = "\(channel.id)_\(event.id ?? UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Immediate delivery
        )
        
        // Add notification
        notificationCenter.add(request) { error in
            if let error = error {
                print("❌ Failed to send notification: \(error.localizedDescription)")
            } else {
                print("✅ Notification sent: \(content.title) [Sound: \(self.isSoundEnabled())]")
            }
        }
    }
    
    // MARK: - Send Summary Notification
    
    func sendSummaryNotification(count: Int, channels: [Channel]) {
        guard isAuthorized, count > 0, areNotificationsEnabled() else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "🔔 New Events"
        
        if channels.count == 1 {
            content.body = "\(count) new event\(count == 1 ? "" : "s") in \(channels[0].eventTypeDisplay)"
        } else {
            content.body = "\(count) new events across \(channels.count) channels"
        }
        
        if isSoundEnabled() {
            content.sound = .default
        }
        
        let unreadCount = SubscriptionManager.shared.subscribedChannels
            .map { SubscriptionManager.shared.getUnreadCount(channelId: $0.id) }
            .reduce(0, +)
        content.badge = NSNumber(value: unreadCount)
        
        let identifier = "summary_\(UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        
        notificationCenter.add(request) { error in
            if let error = error {
                print("❌ Failed to send summary notification: \(error.localizedDescription)")
            } else {
                print("✅ Summary notification sent: \(count) events")
            }
        }
    }
    
    // MARK: - Clear Notifications
    
    func clearNotifications(for channelId: String? = nil) {
        if let channelId = channelId {
            notificationCenter.getDeliveredNotifications { notifications in
                let identifiersToRemove = notifications
                    .filter { notification in
                        if let userInfo = notification.request.content.userInfo as? [String: Any],
                           let notifChannelId = userInfo["channelId"] as? String {
                            return notifChannelId == channelId
                        }
                        return false
                    }
                    .map { $0.request.identifier }
                
                self.notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiersToRemove)
            }
        } else {
            notificationCenter.removeAllDeliveredNotifications()
        }
    }
    
    // MARK: - Update Badge Count
    
    func updateBadgeCount() {
        let totalUnread = SubscriptionManager.shared.subscribedChannels
            .map { SubscriptionManager.shared.getUnreadCount(channelId: $0.id) }
            .reduce(0, +)
        
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = totalUnread
        }
    }
    
    // MARK: - Setup Notification Categories
    
    func setupNotificationCategories() {
        let viewMapAction = UNNotificationAction(
            identifier: "VIEW_MAP",
            title: "View on Map",
            options: .foreground
        )
        
        let gpsCategory = UNNotificationCategory(
            identifier: "GPS_EVENT",
            actions: [viewMapAction],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        
        let viewImageAction = UNNotificationAction(
            identifier: "VIEW_IMAGE",
            title: "View Image",
            options: .foreground
        )
        
        let cameraCategory = UNNotificationCategory(
            identifier: "CAMERA_EVENT",
            actions: [viewImageAction],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        
        notificationCenter.setNotificationCategories([gpsCategory, cameraCategory])
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    
    // Handle notification when app is in FOREGROUND
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        print("📲 Notification received in FOREGROUND")
        
        // ✅ Check if notifications are enabled
        guard UserDefaults.standard.bool(forKey: "notifications_enabled") else {
            completionHandler([])
            return
        }
        
        // Show banner and badge, sound only if enabled
        if #available(iOS 14.0, *) {
            if UserDefaults.standard.bool(forKey: "sound_enabled") {
                completionHandler([.banner, .sound, .badge])
            } else {
                completionHandler([.banner, .badge])
            }
        } else {
            if UserDefaults.standard.bool(forKey: "sound_enabled") {
                completionHandler([.alert, .sound, .badge])
            } else {
                completionHandler([.alert, .badge])
            }
        }
    }
    
    // Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        print("📲 Notification tapped")
        
        let userInfo = response.notification.request.content.userInfo
        
        // Post notification for app to handle
        NotificationCenter.default.post(
            name: .userTappedNotification,
            object: nil,
            userInfo: userInfo
        )
        
        completionHandler()
    }
}

extension Notification.Name {
    static let userTappedNotification = Notification.Name("userTappedNotification")
}