import Foundation
import Combine

class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()
    
    @Published var subscribedChannels: [Channel] = []
    private var eventsCache: [String: [Event]] = [:]
    private var unreadCountCache: [String: Int] = [:]
    
    private let userDefaults = UserDefaults.standard
    private let channelsKey = "subscribed_channels"
    private let eventsKey = "events_cache"
    private let unreadKey = "unread_cache"
    
    // Deduplication
    private var recentEventIds: Set<String> = []
    private var eventTimestamps: [String: Int64] = [:]
    
    // App kill detection
    private let lastRuntimeCheckKey = "last_runtime_check"
    private let serviceStartedAtKey = "service_started_at"
    private var runtimeCheckTimer: Timer?
    
    private var wasAppKilled = false
    
    private init() {
        loadData()
        detectAppKill()
        markServiceRunning()
        startRuntimeChecker()
        
        if !wasAppKilled {
            buildRecentEventIds()
        }
        
        startRecentEventCleanup()
    }
    
    // MARK: - App Kill Detection
    
    private func detectAppKill() {
        let lastRuntimeCheck = userDefaults.object(forKey: lastRuntimeCheckKey) as? Int64 ?? 0
        let serviceStartedAt = userDefaults.object(forKey: serviceStartedAtKey) as? Int64 ?? 0
        let now = Int64(Date().timeIntervalSince1970)
        
        if serviceStartedAt > 0 && lastRuntimeCheck > 0 {
            let timeSinceLastCheck = now - lastRuntimeCheck
            
            if timeSinceLastCheck > 2 * 60 { // 2 minutes
                print("🔴 DETECTED: App was killed or cleared from background")
                print("   - Service started at: \(serviceStartedAt)")
                print("   - Last runtime check: \(lastRuntimeCheck)")
                print("   - Gap: \(timeSinceLastCheck)s")
                
                userDefaults.removeObject(forKey: serviceStartedAtKey)
                wasAppKilled = true
            }
        }
    }
    
    private func markServiceRunning() {
        let now = Int64(Date().timeIntervalSince1970)
        userDefaults.set(now, forKey: serviceStartedAtKey)
        userDefaults.set(now, forKey: lastRuntimeCheckKey)
    }
    
    private func startRuntimeChecker() {
        runtimeCheckTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            let now = Int64(Date().timeIntervalSince1970)
            self?.userDefaults.set(now, forKey: self?.lastRuntimeCheckKey ?? "")
        }
    }
    
    // MARK: - Data Management
    
    private func loadData() {
        // Load channels
        if let data = userDefaults.data(forKey: channelsKey),
           let channels = try? JSONDecoder().decode([Channel].self, from: data) {
            subscribedChannels = channels
            print("📦 Loaded \(channels.count) subscribed channels")
        }
        
        // Load events
        if let data = userDefaults.data(forKey: eventsKey),
           let events = try? JSONDecoder().decode([String: [Event]].self, from: data) {
            eventsCache = events
            let totalEvents = events.values.reduce(0) { $0 + $1.count }
            print("📦 Loaded \(totalEvents) events across \(events.count) channels")
        }
        
        // Load unread counts
        if let data = userDefaults.data(forKey: unreadKey),
           let unread = try? JSONDecoder().decode([String: Int].self, from: data) {
            unreadCountCache = unread
        }
    }
    
    func forceSave() {
        saveChannels()
        saveEvents()
        saveUnreadCounts()
        
        let now = Int64(Date().timeIntervalSince1970)
        userDefaults.set(now, forKey: lastRuntimeCheckKey)
        
        print("💾 Force saved all data")
    }
    
    private func saveChannels() {
        if let data = try? JSONEncoder().encode(subscribedChannels) {
            userDefaults.set(data, forKey: channelsKey)
        }
    }
    
    private func saveEvents() {
        if let data = try? JSONEncoder().encode(eventsCache) {
            userDefaults.set(data, forKey: eventsKey)
            let totalEvents = eventsCache.values.reduce(0) { $0 + $1.count }
            print("💾 Saved \(totalEvents) events across \(eventsCache.count) channels")
        }
    }
    
    private func saveUnreadCounts() {
        if let data = try? JSONEncoder().encode(unreadCountCache) {
            userDefaults.set(data, forKey: unreadKey)
        }
    }
    
    // MARK: - Recent Event IDs Management
    
    private func buildRecentEventIds() {
        recentEventIds.removeAll()
        eventTimestamps.removeAll()
        
        let fiveMinutesAgo = Int64(Date().timeIntervalSince1970) - (5 * 60)
        var recentCount = 0
        
        for (_, events) in eventsCache {
            for event in events {
                if event.timestamp > fiveMinutesAgo {
                    if let eventId = event.id {
                        recentEventIds.insert(eventId)
                        eventTimestamps[eventId] = event.timestamp
                        recentCount += 1
                    }
                }
            }
        }
        
        print("📋 Built recent event IDs: \(recentCount) events from last 5 minutes")
    }
    
    private func startRecentEventCleanup() {
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            let fiveMinutesAgo = Int64(Date().timeIntervalSince1970) - (5 * 60)
            var cleaned = 0
            
            let idsToRemove = self.eventTimestamps.filter { $0.value < fiveMinutesAgo }.map { $0.key }
            
            for id in idsToRemove {
                self.recentEventIds.remove(id)
                self.eventTimestamps.removeValue(forKey: id)
                cleaned += 1
            }
            
            if cleaned > 0 {
                print("🧹 Cleaned \(cleaned) old event IDs from memory")
            }
        }
    }
    
    // MARK: - Subscription Management
    
    func subscribe(channel: Channel) {
        guard !subscribedChannels.contains(where: { $0.id == channel.id }) else {
            print("⚠️ Already subscribed to \(channel.id)")
            return
        }
        
        var updatedChannel = channel
        updatedChannel.isSubscribed = true
        subscribedChannels.append(updatedChannel)
        
        saveChannels()
        
        print("✅ Subscribed to \(channel.id)")
        
        // Update WebSocket subscription
        WebSocketService.shared.sendSubscriptionV2()
    }
    
    func unsubscribe(channelId: String) {
        guard let index = subscribedChannels.firstIndex(where: { $0.id == channelId }) else {
            return
        }
        
        subscribedChannels.remove(at: index)
        
        // Clean up events for this channel
        if let events = eventsCache[channelId] {
            for event in events {
                if let eventId = event.id {
                    recentEventIds.remove(eventId)
                    eventTimestamps.removeValue(forKey: eventId)
                }
            }
        }
        
        eventsCache.removeValue(forKey: channelId)
        unreadCountCache.removeValue(forKey: channelId)
        
        ChannelSyncState.shared.clearChannel(channelId: channelId)
        
        saveChannels()
        saveEvents()
        saveUnreadCounts()
        
        print("❌ Unsubscribed from \(channelId)")
        
        // Update WebSocket subscription
        WebSocketService.shared.sendSubscriptionV2()
    }
    
    func isSubscribed(channelId: String) -> Bool {
        return subscribedChannels.contains { $0.id == channelId }
    }
    
    func updateChannel(_ channel: Channel) {
        if let index = subscribedChannels.firstIndex(where: { $0.id == channel.id }) {
            subscribedChannels[index] = channel
            saveChannels()
        }
    }
    
    func isChannelMuted(channelId: String) -> Bool {
        return subscribedChannels.first { $0.id == channelId }?.isMuted ?? false
    }
    
    // MARK: - Event Management
    
    func addEvent(_ event: Event) -> Bool {
        guard let eventId = event.id,
              let area = event.area,
              let type = event.type else {
            return false
        }
        
        let channelId = "\(area)_\(type)"
        let timestamp = event.timestamp
        let now = Int64(Date().timeIntervalSince1970)
        
        // Check if event already exists in cache
        if let channelEvents = eventsCache[channelId] {
            if channelEvents.contains(where: { $0.id == eventId }) {
                print("⏭️ Event \(eventId) already in cache")
                return false
            }
        }
        
        // Check recent IDs
        if let lastSeenTime = eventTimestamps[eventId] {
            if (now - lastSeenTime) < 5 * 60 {
                print("⏭️ Event \(eventId) seen recently")
                return false
            }
        }
        
        // Add event
        if eventsCache[channelId] == nil {
            eventsCache[channelId] = []
        }
        
        eventsCache[channelId]?.insert(event, at: 0)
        
        // Update recent tracking
        recentEventIds.insert(eventId)
        eventTimestamps[eventId] = timestamp
        
        print("✅ Added event \(eventId) to \(channelId) (total: \(eventsCache[channelId]?.count ?? 0))")
        
        // Update unread count
        unreadCountCache[channelId] = (unreadCountCache[channelId] ?? 0) + 1
        
        // Save asynchronously
        DispatchQueue.global(qos: .background).async {
            self.saveEvents()
            self.saveUnreadCounts()
        }
        
        return true
    }
    
    func getEvents(channelId: String) -> [Event] {
        return eventsCache[channelId] ?? []
    }
    
    func getLastEvent(channelId: String) -> Event? {
        return eventsCache[channelId]?.first
    }
    
    func getUnreadCount(channelId: String) -> Int {
        return unreadCountCache[channelId] ?? 0
    }
    
    func markAsRead(channelId: String) {
        unreadCountCache[channelId] = 0
        saveUnreadCounts()
    }
    
    func getTotalEventCount() -> Int {
        return eventsCache.values.reduce(0) { $0 + $1.count }
    }
    
    // MARK: - Available Channels
    
    static func getAllAvailableChannels() -> [Channel] {
        let areas = [
            ("barkasayal", "Barka Sayal"),
            ("argada", "Argada"),
            ("northkaranpura", "North Karanpura"),
            ("bokarokargali", "Bokaro & Kargali"),
            ("kathara", "Kathara"),
            ("giridih", "Giridih"),
            ("amrapali", "Amrapali & Chandragupta"),
            ("magadh", "Magadh & Sanghmitra"),
            ("rajhara", "Rajhara"),
            ("kuju", "Kuju"),
            ("hazaribagh", "Hazaribagh"),
            ("rajrappa", "Rajrappa"),
            ("dhori", "Dhori"),
            ("piparwar", "Piparwar")
        ]
        
        let eventTypes = [
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
        
        var channels: [Channel] = []
        
        for (area, areaDisplay) in areas {
            for (eventType, eventTypeDisplay) in eventTypes {
                channels.append(Channel(
                    id: "\(area)_\(eventType)",
                    area: area,
                    areaDisplay: areaDisplay,
                    eventType: eventType,
                    eventTypeDisplay: eventTypeDisplay,
                    description: "\(areaDisplay) - \(eventTypeDisplay)",
                    isSubscribed: false,
                    isMuted: false,
                    isPinned: false
                ))
            }
        }
        
        return channels
    }
}