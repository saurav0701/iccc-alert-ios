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
    private let lastRuntimeCheckKey = "last_runtime_check"
    private let serviceStartedAtKey = "service_started_at"
    
    // ✅ CRITICAL FIX: Use NSRecursiveLock instead of NSLock
    // This prevents deadlocks when same thread tries to lock twice
    private let lock = NSRecursiveLock()
    
    private var recentEventIds: Set<String> = []
    private var eventTimestamps: [String: TimeInterval] = [:]
    
    private var saveTimer: Timer?
    private let saveDelay: TimeInterval = 0.5
    
    private var runtimeCheckTimer: Timer?
    private var wasAppKilled = false
    
    // ✅ REMOVED: subscriptionQueue - causes deadlocks
    // All operations will use the recursive lock instead
    
    // MARK: - Initialization
    private init() {
        let wasAppKilled = detectAppKillOrBackgroundClear()
        
        loadSubscriptions()
        loadEvents()
        loadUnreadCounts()
        
        if wasAppKilled {
            print("⚠️ APP WAS KILLED - Clearing recent event cache")
            recentEventIds.removeAll()
            eventTimestamps.removeAll()
        } else {
            buildRecentEventIds()
        }
        
        markServiceRunning()
        startRecentEventCleanup()
        startRuntimeChecker()
        
        print("SubscriptionManager initialized (wasKilled=\(wasAppKilled))")
    }
    
    private func detectAppKillOrBackgroundClear() -> Bool {
        let lastRuntimeCheck = defaults.double(forKey: lastRuntimeCheckKey)
        let serviceStartedAt = defaults.double(forKey: serviceStartedAtKey)
        let now = Date().timeIntervalSince1970
        
        if serviceStartedAt > 0 && lastRuntimeCheck > 0 {
            let timeSinceLastCheck = now - lastRuntimeCheck
            
            if timeSinceLastCheck > 2 * 60 {
                print("🔴 DETECTED: App was killed (gap: \(timeSinceLastCheck)s)")
                defaults.removeObject(forKey: serviceStartedAtKey)
                return true
            }
        }
        
        return false
    }
    
    private func markServiceRunning() {
        let now = Date().timeIntervalSince1970
        defaults.set(now, forKey: serviceStartedAtKey)
        defaults.set(now, forKey: lastRuntimeCheckKey)
    }
    
    private func startRuntimeChecker() {
        DispatchQueue.main.async { [weak self] in
            self?.runtimeCheckTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
                self?.defaults.set(Date().timeIntervalSince1970, forKey: self?.lastRuntimeCheckKey ?? "")
            }
        }
    }
    
    // MARK: - Channel Subscription (✅ COMPLETELY REWRITTEN)
    
    /// Subscribe to a channel - thread-safe and non-blocking
    func subscribe(channel: Channel) {
        print("📝 Subscribe called for: \(channel.id)")
        
        // ✅ FIX 1: Use recursive lock (no deadlocks)
        lock.lock()
        
        var updatedChannel = channel
        updatedChannel.isSubscribed = true
        
        // Check if already subscribed
        if subscribedChannels.contains(where: { $0.id == channel.id }) {
            lock.unlock()
            print("⚠️ Already subscribed to \(channel.id)")
            return
        }
        
        // Add to subscriptions
        subscribedChannels.append(updatedChannel)
        saveSubscriptions()
        
        // Initialize sync state if needed
        let channelId = channel.id
        if ChannelSyncState.shared.getSyncInfo(channelId: channelId) == nil {
            _ = ChannelSyncState.shared.recordEventReceived(
                channelId: channelId,
                eventId: "init",
                timestamp: Int64(Date().timeIntervalSince1970),
                seq: 0
            )
            print("🆕 Initialized sync state for: \(channelId)")
        }
        
        lock.unlock()
        
        print("✅ Subscribed to \(channel.id)")
        
        // ✅ FIX 2: Update UI immediately on main thread
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
        
        // ✅ FIX 3: Send WebSocket update on background thread WITHOUT delay
        // This prevents blocking the subscribe button
        DispatchQueue.global(qos: .userInitiated).async {
            WebSocketService.shared.sendSubscriptionV2()
        }
    }
    
    /// Unsubscribe from a channel - thread-safe and non-blocking
    func unsubscribe(channelId: String) {
        print("📝 Unsubscribe called for: \(channelId)")
        
        lock.lock()
        
        subscribedChannels.removeAll { $0.id == channelId }
        
        // Clean up events
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
        
        ChannelSyncState.shared.clearChannel(channelId: channelId)
        
        saveSubscriptions()
        scheduleSave()
        
        lock.unlock()
        
        print("✅ Unsubscribed from \(channelId)")
        
        // ✅ Update UI on main thread
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
        
        // ✅ Send WebSocket update on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            WebSocketService.shared.sendSubscriptionV2()
        }
    }
    
    // ✅ CRITICAL FIX: Make getSubscriptions() lock-safe
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
        
        let channelId = "\(event.area ?? "")_\(event.type ?? "")"
        let timestamp = TimeInterval(event.timestamp)
        let now = Date().timeIntervalSince1970
        
        lock.lock()
        defer { lock.unlock() }

        if let events = channelEvents[channelId],
           events.contains(where: { $0.id == eventId }) {
            return false
        }
        
        if let lastSeenTime = eventTimestamps[eventId],
           (now - lastSeenTime) < 5 * 60 {
            return false
        }
     
        if channelEvents[channelId] == nil {
            channelEvents[channelId] = []
        }
        channelEvents[channelId]?.insert(event, at: 0)
      
        recentEventIds.insert(eventId)
        eventTimestamps[eventId] = timestamp
      
        unreadCounts[channelId] = (unreadCounts[channelId] ?? 0) + 1
        
        scheduleSave()
        
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
 
    private func buildRecentEventIds() {
        lock.lock()
        defer { lock.unlock() }
        
        recentEventIds.removeAll()
        eventTimestamps.removeAll()
        
        let fiveMinutesAgo = Date().timeIntervalSince1970 - (5 * 60)
        
        for (_, events) in channelEvents {
            for event in events {
                let eventTime = TimeInterval(event.timestamp)
                if eventTime > fiveMinutesAgo, let eventId = event.id {
                    recentEventIds.insert(eventId)
                    eventTimestamps[eventId] = eventTime
                }
            }
        }
    }
    
    private func startRecentEventCleanup() {
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 60.0) { [weak self] in
            self?.cleanupRecentEvents()
        }
    }
    
    private func cleanupRecentEvents() {
        lock.lock()
        let fiveMinutesAgo = Date().timeIntervalSince1970 - (5 * 60)
        
        for (eventId, timestamp) in eventTimestamps {
            if timestamp < fiveMinutesAgo {
                recentEventIds.remove(eventId)
                eventTimestamps.removeValue(forKey: eventId)
            }
        }
        lock.unlock()
        
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 60.0) { [weak self] in
            self?.cleanupRecentEvents()
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
        
        if let data = try? JSONEncoder().encode(eventsSnapshot) {
            defaults.set(data, forKey: eventsKey)
        }
        
        if let data = try? JSONEncoder().encode(unreadSnapshot) {
            defaults.set(data, forKey: unreadKey)
        }
        
        defaults.set(Date().timeIntervalSince1970, forKey: lastRuntimeCheckKey)
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
    
    func forceSave() {
        saveTimer?.invalidate()
        saveNow()
    }
}

extension SubscriptionManager {
    static let availableAreas: [(id: String, display: String)] = [
        ("barkasayal", "Barka Sayal"),
        ("argada", "Argada"),
        ("northkaranpura", "North Karanpura"),
        ("bokarokargali", "Bokaro & Kargali"),
        ("kathara", "Kathara"),
        ("giridih", "Giridih"),
        ("amrapali", "Amrapali & Chandragupta"),
        ("rajhara", "Rajhara"),
        ("kuju", "Kuju"),
        ("hazaribagh", "Hazaribagh"),
        ("rajrappa", "Rajrappa"),
        ("dhori", "Dhori"),
        ("piparwar", "Piparwar")
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