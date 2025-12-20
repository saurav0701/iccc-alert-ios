import Foundation
import UserNotifications
import UIKit

/// ✅ Local Notification Manager (WhatsApp/Telegram style)
/// Sends notifications for new events even when app is in background/foreground
class NotificationManager: NSObject {
    static let shared = NotificationManager()
    
    private let notificationCenter = UNUserNotificationCenter.current()
    private var isAuthorized = false
    
    // Track last notification time per channel to avoid spam
    private var lastNotificationTime: [String: TimeInterval] = [:]
    private let minNotificationInterval: TimeInterval = 3.0 // 3 seconds between notifications per channel
    
    private override init() {
        super.init()
        notificationCenter.delegate = self
    }
    
    // MARK: - Request Permission
    
    func requestAuthorization() {
        notificationCenter.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.isAuthorized = granted
                
                if granted {
                    print("✅ Notification permission granted")
                    UIApplication.shared.registerForRemoteNotifications()
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
        // Check if authorized
        guard isAuthorized else {
            print("⚠️ Notifications not authorized")
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
        
        // Sound
        content.sound = .default
        
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
                print("✅ Notification sent: \(content.title)")
            }
        }
    }
    
    // MARK: - Send Summary Notification (for bulk events)
    
    func sendSummaryNotification(count: Int, channels: [Channel]) {
        guard isAuthorized, count > 0 else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "🔔 New Events"
        
        if channels.count == 1 {
            content.body = "\(count) new event\(count == 1 ? "" : "s") in \(channels[0].eventTypeDisplay)"
        } else {
            content.body = "\(count) new events across \(channels.count) channels"
        }
        
        content.sound = .default
        
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
            // Clear notifications for specific channel
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
            // Clear all notifications
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
        // GPS Event Actions
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
        
        // Camera Event Actions
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
        
        // Show banner, sound, and badge even in foreground (like WhatsApp)
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
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

// MARK: - Notification Name Extension

extension Notification.Name {
    static let userTappedNotification = Notification.Name("userTappedNotification")
}