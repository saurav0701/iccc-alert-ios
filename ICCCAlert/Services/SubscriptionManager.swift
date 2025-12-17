import Foundation
import Combine

class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()
    
    @Published var subscribedChannels: [Channel] = []
    @Published var channelEvents: [String: [Event]] = [:]
    @Published var unreadCounts: [String: Int] = [:]
    
    private let defaults = UserDefaults.standard
    private let channelsKey = "subscribed_channels"
    private let eventsKey = "channel_events"
    private let unreadKey = "unread_counts"
    
    // ✅ SIMPLE: Just use a lock, no complex queues
    private let lock = NSLock()
    
    private var recentEventIds: Set<String> = []
    private var saveTimer: Timer?
    
    private init() {
        loadSubscriptions()
        loadEvents()
        loadUnreadCounts()
        buildRecentEventIds()
    }
    
    // ✅ SIMPLE SUBSCRIBE - NO ASYNC BULLSHIT
    func subscribe(channel: Channel) {
        lock.lock()
        defer { lock.unlock() }
        
        print("📝 Subscribe: \(channel.id)")
        
        var updatedChannel = channel
        updatedChannel.isSubscribed = true
        
        if subscribedChannels.contains(where: { $0.id == channel.id }) {
            print("⚠️ Already subscribed")
            return
        }
        
        subscribedChannels.append(updatedChannel)
        saveSubscriptions()
        
        // Initialize sync state
        if ChannelSyncState.shared.getSyncInfo(channelId: channel.id) == nil {
            _ = ChannelSyncState.shared.recordEventReceived(
                channelId: channel.id,
                eventId: "init",
                timestamp: Int64(Date().timeIntervalSince1970),
                seq: 0
            )
        }
        
        print("✅ Subscribed to \(channel.id)")
        
        // Update WebSocket in background
        DispatchQueue.global().async {
            WebSocketService.shared.sendSubscriptionV2()
        }
    }
    
    // ✅ SIMPLE UNSUBSCRIBE
    func unsubscribe(channelId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        print("📝 Unsubscribe: \(channelId)")
        
        subscribedChannels.removeAll { $0.id == channelId }
        
        if let events = channelEvents[channelId] {
            events.forEach { event in
                if let eventId = event.id {
                    recentEventIds.remove(eventId)
                }
            }
        }
        
        channelEvents.removeValue(forKey: channelId)
        unreadCounts.removeValue(forKey: channelId)
        ChannelSyncState.shared.clearChannel(channelId: channelId)
        
        saveSubscriptions()
        scheduleSave()
        
        print("✅ Unsubscribed from \(channelId)")
        
        DispatchQueue.global().async {
            WebSocketService.shared.sendSubscriptionV2()
        }
    }
    
    func getSubscriptions() -> [Channel] {
        lock.lock()
        defer { lock.unlock() }
        return subscribedChannels
    }
    
    func isSubscribed(channelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return subscribedChannels.contains { $0.id == channelId }
    }
    
    func updateChannel(_ channel: Channel) {
        lock.lock()
        defer { lock.unlock() }
        
        if let index = subscribedChannels.firstIndex(where: { $0.id == channel.id }) {
            subscribedChannels[index] = channel
            saveSubscriptions()
        }
    }
    
    func isChannelMuted(channelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return subscribedChannels.first(where: { $0.id == channelId })?.isMuted ?? false
    }
    
    func addEvent(event: Event) -> Bool {
        guard let eventId = event.id else { return false }
        
        lock.lock()
        defer { lock.unlock() }
        
        let channelId = "\(event.area ?? "")_\(event.type ?? "")"
        
        // Check duplicate
        if let events = channelEvents[channelId],
           events.contains(where: { $0.id == eventId }) {
            return false
        }
        
        // Check recent
        if recentEventIds.contains(eventId) {
            return false
        }
        
        // Add event
        if channelEvents[channelId] == nil {
            channelEvents[channelId] = []
        }
        channelEvents[channelId]?.insert(event, at: 0)
        recentEventIds.insert(eventId)
        unreadCounts[channelId] = (unreadCounts[channelId] ?? 0) + 1
        
        scheduleSave()
        return true
    }
    
    func getEvents(channelId: String) -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return channelEvents[channelId] ?? []
    }
    
    func getUnreadCount(channelId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return unreadCounts[channelId] ?? 0
    }
    
    func markAsRead(channelId: String) {
        lock.lock()
        unreadCounts[channelId] = 0
        lock.unlock()
        
        scheduleSave()
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .subscriptionsUpdated, object: nil)
        }
    }
    
    func getTotalEventCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return channelEvents.values.reduce(0) { $0 + $1.count }
    }
    
    private func buildRecentEventIds() {
        lock.lock()
        defer { lock.unlock() }
        
        recentEventIds.removeAll()
        let fiveMinutesAgo = Date().timeIntervalSince1970 - (5 * 60)
        
        for (_, events) in channelEvents {
            for event in events {
                let eventTime = TimeInterval(event.timestamp)
                if eventTime > fiveMinutesAgo, let eventId = event.id {
                    recentEventIds.insert(eventId)
                }
            }
        }
    }
    
    private func saveSubscriptions() {
        if let data = try? JSONEncoder().encode(subscribedChannels) {
            defaults.set(data, forKey: channelsKey)
        }
    }
    
    private func loadSubscriptions() {
        if let data = defaults.data(forKey: channelsKey),
           let channels = try? JSONDecoder().decode([Channel].self, from: data) {
            subscribedChannels = channels
        }
    }
    
    private func scheduleSave() {
        DispatchQueue.main.async {
            self.saveTimer?.invalidate()
            self.saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                self.saveNow()
            }
        }
    }
    
    private func saveNow() {
        lock.lock()
        defer { lock.unlock() }
        
        if let data = try? JSONEncoder().encode(channelEvents) {
            defaults.set(data, forKey: eventsKey)
        }
        if let data = try? JSONEncoder().encode(unreadCounts) {
            defaults.set(data, forKey: unreadKey)
        }
    }
    
    private func loadEvents() {
        if let data = defaults.data(forKey: eventsKey),
           let events = try? JSONDecoder().decode([String: [Event]].self, from: data) {
            channelEvents = events
        }
    }
    
    private func loadUnreadCounts() {
        if let data = defaults.data(forKey: unreadKey),
           let counts = try? JSONDecoder().decode([String: Int].self, from: data) {
            unreadCounts = counts
        }
    }
}