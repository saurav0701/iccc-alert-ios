import Foundation
import Combine

class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()
    
    // MARK: - Published Properties
    @Published var subscribedChannels: [Channel] = []
    @Published var channelEvents: [String: [Event]] = [:]
    @Published var unreadCounts: [String: Int] = [:]
    
    // MARK: - Private Properties
    private let defaults = UserDefaults.standard
    private let channelsKey = "subscribed_channels"
    private let eventsKey = "channel_events"
    private let unreadKey = "unread_counts"
    
    private let lock = NSLock()
    private var recentEventIds: Set<String> = []
    private var eventTimestamps: [String: TimeInterval] = [:]
    
    private var saveTimer: Timer?
    private let saveDelay: TimeInterval = 0.5
    
    // MARK: - Initialization
    private init() {
        loadSubscriptions()
        loadEvents()
        loadUnreadCounts()
        buildRecentEventIds()
        startRecentEventCleanup()
    }
    
    // MARK: - Channel Subscription
    func subscribe(channel: Channel) {
        lock.lock()
        defer { lock.unlock() }
        
        var updatedChannel = channel
        updatedChannel.isSubscribed = true
        
        if !subscribedChannels.contains(where: { $0.id == channel.id }) {
            subscribedChannels.append(updatedChannel)
            saveSubscriptions()
            
            // Notify WebSocket to update subscriptions
            DispatchQueue.main.async {
                WebSocketService.shared.updateSubscriptions()
                NotificationCenter.default.post(name: .subscriptionsUpdated, object: nil)
            }
            
            print("✅ Subscribed to \(channel.id)")
        }
    }
    
    func unsubscribe(channelId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        subscribedChannels.removeAll { $0.id == channelId }
        
        // Remove events for this channel
        if let events = channelEvents[channelId] {
            events.forEach { event in
                if let eventId = event.id {
                    recentEventIds.remove(eventId)
                    eventTimestamps.removeValue(forKey: eventId)
                }
            }
        }
        
        channelEvents.removeValue(forKey: channelId)
        unreadCounts.removeValue(forKey: channelId)
        
        // Clear sync state
        ChannelSyncState.shared.clearChannel(channelId: channelId)
        
        saveSubscriptions()
        scheduleSave()
        
        // Notify WebSocket
        DispatchQueue.main.async {
            WebSocketService.shared.updateSubscriptions()
            NotificationCenter.default.post(name: .subscriptionsUpdated, object: nil)
        }
        
        print("✅ Unsubscribed from \(channelId)")
    }
    
    func isSubscribed(channelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return subscribedChannels.contains { $0.id == channelId }
    }
    
    func getSubscriptions() -> [Channel] {
        lock.lock()
        defer { lock.unlock() }
        return subscribedChannels
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
    
    // MARK: - Event Management
    func addEvent(event: Event) -> Bool {
        guard let eventId = event.id else { return false }
        
        let channelId = "\(event.area ?? "")_\(event.type ?? "")"
        let timestamp = TimeInterval(event.timestamp)
        let now = Date().timeIntervalSince1970
        
        lock.lock()
        defer { lock.unlock() }
        
        // Check if event already exists in cache
        if let events = channelEvents[channelId],
           events.contains(where: { $0.id == eventId }) {
            print("⏭️ Event \(eventId) already in cache")
            return false
        }
        
        // Check recent IDs
        if let lastSeenTime = eventTimestamps[eventId],
           (now - lastSeenTime) < 5 * 60 {
            print("⏭️ Event \(eventId) seen recently")
            return false
        }
        
        // Add event to channel
        if channelEvents[channelId] == nil {
            channelEvents[channelId] = []
        }
        channelEvents[channelId]?.insert(event, at: 0)
        
        // Track recent event
        recentEventIds.insert(eventId)
        eventTimestamps[eventId] = timestamp
        
        // Update unread count
        unreadCounts[channelId] = (unreadCounts[channelId] ?? 0) + 1
        
        scheduleSave()
        
        print("✅ Added event \(eventId) to \(channelId)")
        return true
    }
    
    func getEvents(channelId: String) -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return channelEvents[channelId] ?? []
    }
    
    func getLastEvent(channelId: String) -> Event? {
        lock.lock()
        defer { lock.unlock() }
        return channelEvents[channelId]?.first
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
    
    func getEventCount(channelId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return channelEvents[channelId]?.count ?? 0
    }
    
    // MARK: - Recent Event Tracking
    private func buildRecentEventIds() {
        lock.lock()
        defer { lock.unlock() }
        
        recentEventIds.removeAll()
        eventTimestamps.removeAll()
        
        let fiveMinutesAgo = Date().timeIntervalSince1970 - (5 * 60)
        var recentCount = 0
        
        for (_, events) in channelEvents {
            for event in events {
                let eventTime = TimeInterval(event.timestamp)
                if eventTime > fiveMinutesAgo, let eventId = event.id {
                    recentEventIds.insert(eventId)
                    eventTimestamps[eventId] = eventTime
                    recentCount += 1
                }
            }
        }
        
        print("📊 Built recent event IDs: \(recentCount) events from last 5 minutes")
    }
    
    private func startRecentEventCleanup() {
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 60.0) { [weak self] in
            self?.cleanupRecentEvents()
        }
    }
    
    private func cleanupRecentEvents() {
        lock.lock()
        let fiveMinutesAgo = Date().timeIntervalSince1970 - (5 * 60)
        var cleaned = 0
        
        for (eventId, timestamp) in eventTimestamps {
            if timestamp < fiveMinutesAgo {
                recentEventIds.remove(eventId)
                eventTimestamps.removeValue(forKey: eventId)
                cleaned += 1
            }
        }
        lock.unlock()
        
        if cleaned > 0 {
            print("🧹 Cleaned \(cleaned) old event IDs from memory")
        }
        
        // Schedule next cleanup
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 60.0) { [weak self] in
            self?.cleanupRecentEvents()
        }
    }
    
    // MARK: - Persistence
    private func saveSubscriptions() {
        if let data = try? JSONEncoder().encode(subscribedChannels) {
            defaults.set(data, forKey: channelsKey)
        }
    }
    
    private func loadSubscriptions() {
        if let data = defaults.data(forKey: channelsKey),
           let channels = try? JSONDecoder().decode([Channel].self, from: data) {
            subscribedChannels = channels
            print("📊 Loaded \(channels.count) subscribed channels")
        }
    }
    
    private func scheduleSave() {
        saveTimer?.invalidate()
        
        DispatchQueue.main.async { [weak self] in
            self?.saveTimer = Timer.scheduledTimer(withTimeInterval: self?.saveDelay ?? 0.5, repeats: false) { [weak self] _ in
                self?.saveNow()
            }
        }
    }
    
    private func saveNow() {
        lock.lock()
        let eventsSnapshot = channelEvents
        let unreadSnapshot = unreadCounts
        lock.unlock()
        
        // Save events
        if let data = try? JSONEncoder().encode(eventsSnapshot) {
            defaults.set(data, forKey: eventsKey)
        }
        
        // Save unread counts
        if let data = try? JSONEncoder().encode(unreadSnapshot) {
            defaults.set(data, forKey: unreadKey)
        }
        
        let totalEvents = eventsSnapshot.values.reduce(0) { $0 + $1.count }
        print("💾 Saved \(totalEvents) events across \(eventsSnapshot.count) channels")
    }
    
    private func loadEvents() {
        if let data = defaults.data(forKey: eventsKey),
           let events = try? JSONDecoder().decode([String: [Event]].self, from: data) {
            channelEvents = events
            let total = events.values.reduce(0) { $0 + $1.count }
            print("📊 Loaded \(total) events from \(events.count) channels")
        }
    }
    
    private func loadUnreadCounts() {
        if let data = defaults.data(forKey: unreadKey),
           let counts = try? JSONDecoder().decode([String: Int].self, from: data) {
            unreadCounts = counts
        }
    }
    
    func forceSave() {
        saveTimer?.invalidate()
        saveNow()
        print("💾 Force saved all data")
    }
}

// MARK: - Available Channels
extension SubscriptionManager {
    static let availableAreas: [(id: String, display: String)] = [
        ("sijua", "Sijua"),
        ("kusunda", "Kusunda"),
        ("bastacolla", "Bastacolla"),
        ("lodna", "Lodna"),
        ("govindpur", "Govindpur"),
        ("barora", "Barora"),
        ("ccwo", "CCWO"),
        ("ej", "EJ"),
        ("cvarea", "CV Area"),
        ("wjarea", "WJ Area"),
        ("pbarea", "PB Area"),
        ("block2", "Block 2"),
        ("katras", "Katras")
    ]
    
    static let availableEventTypes: [(id: String, display: String)] = [
        ("cd", "Crowd Detection"),
        ("vd", "Vehicle Detection"),
        ("pd", "Person Detection"),
        ("id", "Intrusion Detection"),
        ("vc", "Vehicle Congestion"),
        ("ls", "Loading Status"),
        ("us", "Unloading Status"),
        ("ct", "Camera Tampering"),
        ("sh", "Safety Hazard"),
        ("ii", "Insufficient Illumination"),
        ("off-route", "Off-Route Alert"),
        ("tamper", "Tamper Alert")
    ]
    
    static func getAllAvailableChannels() -> [Channel] {
        var channels: [Channel] = []
        
        for area in availableAreas {
            for eventType in availableEventTypes {
                let channel = Channel(
                    id: "\(area.id)_\(eventType.id)",
                    area: area.id,
                    areaDisplay: area.display,
                    eventType: eventType.id,
                    eventTypeDisplay: eventType.display,
                    description: "\(area.display) - \(eventType.display)"
                )
                channels.append(channel)
            }
        }
        
        return channels
    }
}