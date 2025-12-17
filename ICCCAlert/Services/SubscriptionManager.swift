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
    
    // ✅ CRITICAL FIX: Use DispatchQueue instead of NSLock to prevent deadlocks
    private let syncQueue = DispatchQueue(label: "com.iccc.subscription.sync", qos: .userInitiated)
    
    private var recentEventIds: Set<String> = []
    private var eventTimestamps: [String: TimeInterval] = [:]
    
    private var saveTimer: Timer?
    private let saveDelay: TimeInterval = 0.5
    
    private var runtimeCheckTimer: Timer?
    
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
        
        // ✅ Use async dispatch to prevent blocking
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            
            var updatedChannel = channel
            updatedChannel.isSubscribed = true
            
            // Check if already subscribed
            if self.subscribedChannels.contains(where: { $0.id == channel.id }) {
                print("⚠️ Already subscribed to \(channel.id)")
                return
            }
            
            // Add to subscriptions
            self.subscribedChannels.append(updatedChannel)
            self.saveSubscriptions()
            
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
            
            print("✅ Subscribed to \(channel.id)")
            
            // ✅ Update UI on main thread
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
        
        // ✅ Send WebSocket update on background thread WITHOUT blocking
        DispatchQueue.global(qos: .userInitiated).async {
            WebSocketService.shared.sendSubscriptionV2()
        }
    }
    
    /// Unsubscribe from a channel - thread-safe and non-blocking
    func unsubscribe(channelId: String) {
        print("📝 Unsubscribe called for: \(channelId)")
        
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.subscribedChannels.removeAll { $0.id == channelId }
            
            // Clean up events
            if let events = self.channelEvents[channelId] {
                events.forEach { event in
                    if let eventId = event.id {
                        self.recentEventIds.remove(eventId)
                        self.eventTimestamps.removeValue(forKey: eventId)
                    }
                }
            }
            
            self.channelEvents.removeValue(forKey: channelId)
            self.unreadCounts.removeValue(forKey: channelId)
            
            ChannelSyncState.shared.clearChannel(channelId: channelId)
            
            self.saveSubscriptions()
            self.scheduleSave()
            
            print("✅ Unsubscribed from \(channelId)")
            
            // ✅ Update UI on main thread
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
        
        // ✅ Send WebSocket update on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            WebSocketService.shared.sendSubscriptionV2()
        }
    }
    
    // ✅ CRITICAL FIX: Make getSubscriptions() thread-safe
    func getSubscriptions() -> [Channel] {
        return syncQueue.sync {
            return subscribedChannels
        }
    }
    
    func isSubscribed(channelId: String) -> Bool {
        return syncQueue.sync {
            return subscribedChannels.contains { $0.id == channelId }
        }
    }
    
    func updateChannel(_ channel: Channel) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            
            if let index = self.subscribedChannels.firstIndex(where: { $0.id == channel.id }) {
                self.subscribedChannels[index] = channel
                self.saveSubscriptions()
            }
        }
    }
    
    func isChannelMuted(channelId: String) -> Bool {
        return syncQueue.sync {
            return subscribedChannels.first(where: { $0.id == channelId })?.isMuted ?? false
        }
    }

    // ✅ CRITICAL FIX: Optimized addEvent - non-blocking
    func addEvent(event: Event) -> Bool {
        guard let eventId = event.id else { return false }
        
        let channelId = "\(event.area ?? "")_\(event.type ?? "")"
        let timestamp = TimeInterval(event.timestamp)
        let now = Date().timeIntervalSince1970
        
        // ✅ Quick duplicate check (no locks needed)
        if let lastSeenTime = eventTimestamps[eventId],
           (now - lastSeenTime) < 5 * 60 {
            return false
        }
        
        // ✅ Use async dispatch to prevent blocking
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Check if event already exists
            if let events = self.channelEvents[channelId],
               events.contains(where: { $0.id == eventId }) {
                return
            }
            
            // Add event
            if self.channelEvents[channelId] == nil {
                self.channelEvents[channelId] = []
            }
            self.channelEvents[channelId]?.insert(event, at: 0)
            
            self.recentEventIds.insert(eventId)
            self.eventTimestamps[eventId] = timestamp
            
            self.unreadCounts[channelId] = (self.unreadCounts[channelId] ?? 0) + 1
            
            self.scheduleSave()
            
            // ✅ Update UI on main thread
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
        
        return true
    }
    
    func getEvents(channelId: String) -> [Event] {
        return syncQueue.sync {
            return channelEvents[channelId] ?? []
        }
    }
    
    func getLastEvent(channelId: String) -> Event? {
        return syncQueue.sync {
            return channelEvents[channelId]?.first
        }
    }
    
    func getUnreadCount(channelId: String) -> Int {
        return syncQueue.sync {
            return unreadCounts[channelId] ?? 0
        }
    }
    
    func markAsRead(channelId: String) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            self.unreadCounts[channelId] = 0
            self.scheduleSave()
            
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .subscriptionsUpdated, object: nil)
            }
        }
    }
    
    func getTotalEventCount() -> Int {
        return syncQueue.sync {
            return channelEvents.values.reduce(0) { $0 + $1.count }
        }
    }
    
    func getEventCount(channelId: String) -> Int {
        return syncQueue.sync {
            return channelEvents[channelId]?.count ?? 0
        }
    }
 
    private func buildRecentEventIds() {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.recentEventIds.removeAll()
            self.eventTimestamps.removeAll()
            
            let fiveMinutesAgo = Date().timeIntervalSince1970 - (5 * 60)
            
            for (_, events) in self.channelEvents {
                for event in events {
                    let eventTime = TimeInterval(event.timestamp)
                    if eventTime > fiveMinutesAgo, let eventId = event.id {
                        self.recentEventIds.insert(eventId)
                        self.eventTimestamps[eventId] = eventTime
                    }
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
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            
            let fiveMinutesAgo = Date().timeIntervalSince1970 - (5 * 60)
            
            for (eventId, timestamp) in self.eventTimestamps {
                if timestamp < fiveMinutesAgo {
                    self.recentEventIds.remove(eventId)
                    self.eventTimestamps.removeValue(forKey: eventId)
                }
            }
        }
        
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
        // Must be called from syncQueue
        DispatchQueue.main.async { [weak self] in
            self?.saveTimer?.invalidate()
            self?.saveTimer = Timer.scheduledTimer(withTimeInterval: self?.saveDelay ?? 0.5, repeats: false) { [weak self] _ in
                self?.saveNow()
            }
        }
    }
    
    private func saveNow() {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            
            if let data = try? JSONEncoder().encode(self.channelEvents) {
                self.defaults.set(data, forKey: self.eventsKey)
            }
            
            if let data = try? JSONEncoder().encode(self.unreadCounts) {
                self.defaults.set(data, forKey: self.unreadKey)
            }
            
            self.defaults.set(Date().timeIntervalSince1970, forKey: self.lastRuntimeCheckKey)
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