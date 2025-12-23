import Foundation
import Combine

class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()
    
    @Published var subscribedChannels: [Channel] = []
    
    // ✅ FIXED: Thread-safe data structures with proper locking
    private var eventsCache: [String: [Event]] = [:]
    private var unreadCountCache: [String: Int] = [:]
    private var savedEventIds: Set<String> = []
    
    private let eventsCacheLock = NSLock()
    private let unreadLock = NSLock()
    private let savedEventsLock = NSLock()
    
    // ✅ FIXED: Maximum cache size to prevent memory issues
    private let maxEventsPerChannel = 500
    
    private let userDefaults = UserDefaults.standard
    private let channelsKey = "subscribed_channels"
    private let eventsKey = "events_cache"
    private let unreadKey = "unread_cache"
    private let savedEventsKey = "saved_events"
    
    // Deduplication
    private var recentEventIds: Set<String> = []
    private var eventTimestamps: [String: Int64] = [:]
    private let deduplicationLock = NSLock()
    
    // App kill detection
    private let lastRuntimeCheckKey = "last_runtime_check"
    private let serviceStartedAtKey = "service_started_at"
    private var runtimeCheckTimer: Timer?
    
    private var wasAppKilled = false
    
    // ✅ NEW: Save queue to prevent blocking
    private let saveQueue = DispatchQueue(label: "com.iccc.saveQueue", qos: .background)
    private var pendingSave = false
    
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
            eventsCacheLock.lock()
            eventsCache = events
            eventsCacheLock.unlock()
            let totalEvents = events.values.reduce(0) { $0 + $1.count }
            print("📦 Loaded \(totalEvents) events across \(events.count) channels")
        }
        
        // Load unread counts
        if let data = userDefaults.data(forKey: unreadKey),
           let unread = try? JSONDecoder().decode([String: Int].self, from: data) {
            unreadLock.lock()
            unreadCountCache = unread
            unreadLock.unlock()
        }
        
        // Load saved event IDs
        if let savedIds = userDefaults.array(forKey: savedEventsKey) as? [String] {
            savedEventsLock.lock()
            savedEventIds = Set(savedIds)
            savedEventsLock.unlock()
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
    
    // ✅ FIXED: Non-blocking save with debouncing
    private func saveEvents() {
        guard !pendingSave else { return }
        pendingSave = true
        
        saveQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            
            self.eventsCacheLock.lock()
            let eventsToSave = self.eventsCache
            self.eventsCacheLock.unlock()
            
            if let data = try? JSONEncoder().encode(eventsToSave) {
                self.userDefaults.set(data, forKey: self.eventsKey)
                let totalEvents = eventsToSave.values.reduce(0) { $0 + $1.count }
                print("💾 Saved \(totalEvents) events across \(eventsToSave.count) channels")
            }
            
            self.pendingSave = false
        }
    }
    
    private func saveUnreadCounts() {
        unreadLock.lock()
        let countsToSave = unreadCountCache
        unreadLock.unlock()
        
        if let data = try? JSONEncoder().encode(countsToSave) {
            userDefaults.set(data, forKey: unreadKey)
        }
    }
    
    private func saveSavedEvents() {
        savedEventsLock.lock()
        let savedArray = Array(savedEventIds)
        savedEventsLock.unlock()
        
        userDefaults.set(savedArray, forKey: savedEventsKey)
    }
    
    func clearAllEventData() {
        print("🗑️ Clearing ALL event data...")
        
        // Clear from memory with locks
        eventsCacheLock.lock()
        eventsCache.removeAll()
        eventsCacheLock.unlock()
        
        unreadLock.lock()
        unreadCountCache.removeAll()
        unreadLock.unlock()
        
        savedEventsLock.lock()
        savedEventIds.removeAll()
        savedEventsLock.unlock()
        
        deduplicationLock.lock()
        recentEventIds.removeAll()
        eventTimestamps.removeAll()
        deduplicationLock.unlock()
        
        // Clear from UserDefaults
        userDefaults.removeObject(forKey: eventsKey)
        userDefaults.removeObject(forKey: unreadKey)
        userDefaults.removeObject(forKey: savedEventsKey)
        userDefaults.synchronize()
        
        print("✅ ALL EVENT DATA CLEARED")
        
        // Force UI update on main thread
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
    
    // MARK: - Recent Event IDs Management
    
    private func buildRecentEventIds() {
        deduplicationLock.lock()
        defer { deduplicationLock.unlock() }
        
        recentEventIds.removeAll()
        eventTimestamps.removeAll()
        
        let fiveMinutesAgo = Int64(Date().timeIntervalSince1970) - (5 * 60)
        var recentCount = 0
        
        eventsCacheLock.lock()
        let cacheSnapshot = eventsCache
        eventsCacheLock.unlock()
        
        for (_, events) in cacheSnapshot {
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
            
            self.deduplicationLock.lock()
            let idsToRemove = self.eventTimestamps.filter { $0.value < fiveMinutesAgo }.map { $0.key }
            
            for id in idsToRemove {
                self.recentEventIds.remove(id)
                self.eventTimestamps.removeValue(forKey: id)
            }
            self.deduplicationLock.unlock()
            
            if !idsToRemove.isEmpty {
                print("🧹 Cleaned \(idsToRemove.count) old event IDs from memory")
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
        
        // ✅ FIXED: Update on main thread since it's @Published
        DispatchQueue.main.async {
            self.subscribedChannels.append(updatedChannel)
        }
        
        saveChannels()
        
        print("✅ Subscribed to \(channel.id)")
        
        WebSocketService.shared.sendSubscriptionV2()
    }
    
    func unsubscribe(channelId: String) {
        guard let index = subscribedChannels.firstIndex(where: { $0.id == channelId }) else {
            return
        }
        
        // ✅ FIXED: Update on main thread
        DispatchQueue.main.async {
            self.subscribedChannels.remove(at: index)
        }
        
        // Clean up events
        eventsCacheLock.lock()
        if let events = eventsCache[channelId] {
            deduplicationLock.lock()
            for event in events {
                if let eventId = event.id {
                    recentEventIds.remove(eventId)
                    eventTimestamps.removeValue(forKey: eventId)
                }
            }
            deduplicationLock.unlock()
        }
        eventsCache.removeValue(forKey: channelId)
        eventsCacheLock.unlock()
        
        unreadLock.lock()
        unreadCountCache.removeValue(forKey: channelId)
        unreadLock.unlock()
        
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
            DispatchQueue.main.async {
                self.subscribedChannels[index] = channel
            }
            saveChannels()
        }
    }
    
    func isChannelMuted(channelId: String) -> Bool {
        return subscribedChannels.first { $0.id == channelId }?.isMuted ?? false
    }

    // ✅ CRITICAL FIX: Thread-safe event adding with size limits
    func addEvent(_ event: Event) -> Bool {
        guard let eventId = event.id,
              let area = event.area,
              let type = event.type else {
            return false
        }
        
        let channelId = "\(area)_\(type)"
        let timestamp = event.timestamp
        let now = Int64(Date().timeIntervalSince1970)
        
        // Check for duplicates with locks
        eventsCacheLock.lock()
        let isDuplicate = eventsCache[channelId]?.contains(where: { $0.id == eventId }) ?? false
        eventsCacheLock.unlock()
        
        if isDuplicate {
            print("⏭️ Event \(eventId) already in cache")
            return false
        }
        
        // Check recent events
        deduplicationLock.lock()
        if let lastSeenTime = eventTimestamps[eventId] {
            deduplicationLock.unlock()
            if (now - lastSeenTime) < 5 * 60 {
                print("⏭️ Event \(eventId) seen recently")
                return false
            }
        } else {
            deduplicationLock.unlock()
        }

        // Update saved status
        var eventToAdd = event
        savedEventsLock.lock()
        if savedEventIds.contains(eventId) {
            eventToAdd.isSaved = true
        }
        savedEventsLock.unlock()
        
        // ✅ CRITICAL: Add with size limit
        eventsCacheLock.lock()
        if eventsCache[channelId] == nil {
            eventsCache[channelId] = []
        }
        
        eventsCache[channelId]?.insert(eventToAdd, at: 0)
        
        // ✅ Trim to max size to prevent memory issues
        if let count = eventsCache[channelId]?.count, count > maxEventsPerChannel {
            eventsCache[channelId]?.removeLast(count - maxEventsPerChannel)
            print("🧹 Trimmed \(channelId) to \(maxEventsPerChannel) events")
        }
        
        let totalEvents = eventsCache[channelId]?.count ?? 0
        eventsCacheLock.unlock()
        
        // Update deduplication
        deduplicationLock.lock()
        recentEventIds.insert(eventId)
        eventTimestamps[eventId] = timestamp
        deduplicationLock.unlock()
        
        print("✅ Added event \(eventId) to \(channelId) (total: \(totalEvents))")
        
        // Update unread count
        unreadLock.lock()
        unreadCountCache[channelId] = (unreadCountCache[channelId] ?? 0) + 1
        unreadLock.unlock()
        
        // Save asynchronously
        saveQueue.async {
            self.saveEvents()
            self.saveUnreadCounts()
        }
        
        return true
    }
    
    func getEvents(channelId: String) -> [Event] {
        eventsCacheLock.lock()
        guard var events = eventsCache[channelId] else {
            eventsCacheLock.unlock()
            return []
        }
        eventsCacheLock.unlock()
        
        // Update saved status
        savedEventsLock.lock()
        for i in 0..<events.count {
            if let eventId = events[i].id {
                events[i].isSaved = savedEventIds.contains(eventId)
            }
        }
        savedEventsLock.unlock()
        
        return events
    }
    
    func getLastEvent(channelId: String) -> Event? {
        eventsCacheLock.lock()
        guard var event = eventsCache[channelId]?.first else {
            eventsCacheLock.unlock()
            return nil
        }
        eventsCacheLock.unlock()
        
        // Update saved status
        if let eventId = event.id {
            savedEventsLock.lock()
            event.isSaved = savedEventIds.contains(eventId)
            savedEventsLock.unlock()
        }
        
        return event
    }
    
    func getUnreadCount(channelId: String) -> Int {
        unreadLock.lock()
        let count = unreadCountCache[channelId] ?? 0
        unreadLock.unlock()
        return count
    }
    
    func markAsRead(channelId: String) {
        unreadLock.lock()
        unreadCountCache[channelId] = 0
        unreadLock.unlock()
        
        saveUnreadCounts()
        
        // Force UI update on main thread
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
        
        print("✅ Marked \(channelId) as read")
    }
    
    func getTotalEventCount() -> Int {
        eventsCacheLock.lock()
        let count = eventsCache.values.reduce(0) { $0 + $1.count }
        eventsCacheLock.unlock()
        return count
    }
    
    // MARK: - Saved Events Management
    
    func toggleSaved(eventId: String, channelId: String) {
        savedEventsLock.lock()
        if savedEventIds.contains(eventId) {
            savedEventIds.remove(eventId)
            print("🗑️ Removed event \(eventId) from saved")
        } else {
            savedEventIds.insert(eventId)
            print("💾 Saved event \(eventId)")
        }
        let wasSaved = savedEventIds.contains(eventId)
        savedEventsLock.unlock()
        
        // Update event in cache
        eventsCacheLock.lock()
        if let index = eventsCache[channelId]?.firstIndex(where: { $0.id == eventId }) {
            eventsCache[channelId]?[index].isSaved = wasSaved
        }
        eventsCacheLock.unlock()
        
        saveSavedEvents()
        saveEvents()
        
        // Force UI update
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
    
    func isSaved(eventId: String) -> Bool {
        savedEventsLock.lock()
        let saved = savedEventIds.contains(eventId)
        savedEventsLock.unlock()
        return saved
    }
    
    func getSavedEvents() -> [Event] {
        var savedEvents: [Event] = []
        
        eventsCacheLock.lock()
        savedEventsLock.lock()
        
        for (_, events) in eventsCache {
            let channelSavedEvents = events.filter { event in
                guard let eventId = event.id else { return false }
                return savedEventIds.contains(eventId)
            }
            savedEvents.append(contentsOf: channelSavedEvents)
        }
        
        savedEventsLock.unlock()
        eventsCacheLock.unlock()

        return savedEvents.sorted { $0.timestamp > $1.timestamp }
    }
    
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