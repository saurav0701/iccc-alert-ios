import Foundation
import Combine

class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()
    
    @Published var subscribedChannels: [Channel] = []
    private var eventsCache: [String: [Event]] = [:]
    private var unreadCountCache: [String: Int] = [:]
    private var savedEventIds: Set<String> = []
    
    private let userDefaults = UserDefaults.standard
    private let channelsKey = "subscribed_channels"
    private let eventsKey = "events_cache"
    private let unreadKey = "unread_cache"
    private let savedEventsKey = "saved_events"
    
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
            
            if timeSinceLastCheck > 2 * 60 {
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
        
        // Load saved event IDs
        if let savedIds = userDefaults.array(forKey: savedEventsKey) as? [String] {
            savedEventIds = Set(savedIds)
            print("📦 Loaded \(savedIds.count) saved events")
        }
    }
    
    func forceSave() {
        saveChannels()
        saveEvents()
        saveUnreadCounts()
        saveSavedEvents()
        
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
    
    private func saveSavedEvents() {
        let savedArray = Array(savedEventIds)
        userDefaults.set(savedArray, forKey: savedEventsKey)
    }
    
    // ✅ FIXED: Clear ALL event data (for Clear Data functionality)
    func clearAllEventData() {
        print("🗑️ Clearing ALL event data...")
        
        // Clear from memory
        eventsCache.removeAll()
        unreadCountCache.removeAll()
        savedEventIds.removeAll()
        recentEventIds.removeAll()
        eventTimestamps.removeAll()
        
        // Clear from UserDefaults
        userDefaults.removeObject(forKey: eventsKey)
        userDefaults.removeObject(forKey: unreadKey)
        userDefaults.removeObject(forKey: savedEventsKey)
        userDefaults.synchronize()
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✅ ALL EVENT DATA CLEARED")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("CLEARED FROM MEMORY:")
        print("  ✓ eventsCache: \(eventsCache.count) (should be 0)")
        print("  ✓ unreadCountCache: \(unreadCountCache.count) (should be 0)")
        print("  ✓ savedEventIds: \(savedEventIds.count) (should be 0)")
        print("  ✓ recentEventIds: \(recentEventIds.count) (should be 0)")
        print("  ✓ eventTimestamps: \(eventTimestamps.count) (should be 0)")
        print("")
        print("CLEARED FROM USERDEFAULTS:")
        print("  ✓ events_cache: REMOVED")
        print("  ✓ unread_cache: REMOVED")
        print("  ✓ saved_events: REMOVED")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // Force UI update
        DispatchQueue.main.async {
            self.objectWillChange.send()
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
        
        WebSocketService.shared.sendSubscriptionV2()
    }
    
    func unsubscribe(channelId: String) {
        guard let index = subscribedChannels.firstIndex(where: { $0.id == channelId }) else {
            return
        }
        
        subscribedChannels.remove(at: index)
        
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
        
        if let channelEvents = eventsCache[channelId] {
            if channelEvents.contains(where: { $0.id == eventId }) {
                print("⏭️ Event \(eventId) already in cache")
                return false
            }
        }
        
        if let lastSeenTime = eventTimestamps[eventId] {
            if (now - lastSeenTime) < 5 * 60 {
                print("⏭️ Event \(eventId) seen recently")
                return false
            }
        }
        
        // Set saved status if event was saved before
        var eventToAdd = event
        if savedEventIds.contains(eventId) {
            eventToAdd.isSaved = true
        }
        
        if eventsCache[channelId] == nil {
            eventsCache[channelId] = []
        }
        
        eventsCache[channelId]?.insert(eventToAdd, at: 0)
        
        recentEventIds.insert(eventId)
        eventTimestamps[eventId] = timestamp
        
        print("✅ Added event \(eventId) to \(channelId) (total: \(eventsCache[channelId]?.count ?? 0))")
        
        unreadCountCache[channelId] = (unreadCountCache[channelId] ?? 0) + 1
        
        DispatchQueue.global(qos: .background).async {
            self.saveEvents()
            self.saveUnreadCounts()
        }
        
        return true
    }
    
    func getEvents(channelId: String) -> [Event] {
        guard var events = eventsCache[channelId] else { return [] }
        
        // Update saved status for all events
        for i in 0..<events.count {
            if let eventId = events[i].id {
                events[i].isSaved = savedEventIds.contains(eventId)
            }
        }
        
        return events
    }
    
    func getLastEvent(channelId: String) -> Event? {
        guard var event = eventsCache[channelId]?.first else { return nil }
        
        // Update saved status
        if let eventId = event.id {
            event.isSaved = savedEventIds.contains(eventId)
        }
        
        return event
    }
    
    func getUnreadCount(channelId: String) -> Int {
        return unreadCountCache[channelId] ?? 0
    }
    
    func markAsRead(channelId: String) {
        unreadCountCache[channelId] = 0
        saveUnreadCounts()
        
        // Force UI update
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        
        print("✅ Marked \(channelId) as read")
    }
    
    func getTotalEventCount() -> Int {
        return eventsCache.values.reduce(0) { $0 + $1.count }
    }
    
    // MARK: - Saved Events Management
    
    func toggleSaved(eventId: String, channelId: String) {
        if savedEventIds.contains(eventId) {
            savedEventIds.remove(eventId)
            print("🗑️ Removed event \(eventId) from saved")
        } else {
            savedEventIds.insert(eventId)
            print("💾 Saved event \(eventId)")
        }
        
        // Update event in cache
        if let index = eventsCache[channelId]?.firstIndex(where: { $0.id == eventId }) {
            eventsCache[channelId]?[index].isSaved = savedEventIds.contains(eventId)
        }
        
        saveSavedEvents()
        saveEvents()
        
        // Force UI update
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
    
    func isSaved(eventId: String) -> Bool {
        return savedEventIds.contains(eventId)
    }
    
    func getSavedEvents() -> [Event] {
        var savedEvents: [Event] = []
        
        for (_, events) in eventsCache {
            let channelSavedEvents = events.filter { event in
                guard let eventId = event.id else { return false }
                return savedEventIds.contains(eventId)
            }
            savedEvents.append(contentsOf: channelSavedEvents)
        }
        
        // Sort by timestamp (newest first)
        return savedEvents.sorted { $0.timestamp > $1.timestamp }
    }
    
    // MARK: - Available Channels
    
    static func getAllAvailableChannels() -> [Channel] {
        let areas = [
            ("barora", "Barora Area"),
            ("block2", "Block II Area"),
            ("govindpur", "Govindpur Area"),
            ("katras", "Katras Area"),
            ("sijua", "Sijua Area"),
            ("kusunda", "Kusunda Area"),
            ("pbarea", "PB Area"),
            ("bastacolla", "Bastacolla Area"),
            ("lodna", "Lodna Area"),
            ("ej", "EJ Area"),
            ("cvarea", "CV Area"),
            ("ccwo", "CCWO"),
            ("wjarea", "WJ Area")
        ]
        
        let eventTypes = [
            ("cd", "Crowd Detection", "FF5722"),
            ("vd", "Vehicle Detection", "2196F3"),
            ("pd", "Person Detection", "4CAF50"),
            ("id", "Intrusion Detection", "F44336"),
            ("vc", "Vehicle Congestion", "FFC107"),
            ("ls", "Loading Status", "00BCD4"),
            ("ct", "Camera Tampering", "E91E63"),
            ("sh", "Safety Hazard", "FF9800"),
            ("ii", "Insufficient Illumination", "9C27B0"),
            ("off-route", "Off-Route Alert", "FF5722"),
            ("tamper", "Tamper Alert", "F44336")
        ]
        
        var channels: [Channel] = []
        
        for (area, areaDisplay) in areas {
            for (eventType, eventTypeDisplay, _) in eventTypes {
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