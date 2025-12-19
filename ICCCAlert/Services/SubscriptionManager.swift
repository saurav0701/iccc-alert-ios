import Foundation
import Combine

class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()
    
    @Published var subscribedChannels: [Channel] = []
    
    // Channel data storage: [channelId: ChannelData]
    private var channels: [String: ChannelData] = [:]
    private let channelsLock = NSLock()
    
    private let channelsKey = "subscribedChannels"
    private let channelDataKey = "channelData"
    
    struct ChannelData: Codable {
        var channel: Channel
        var events: [Event]
        var lastSyncTimestamp: Int64
    }
    
    private init() {
        loadChannelsFromUserDefaults()
        
        // Auto-save periodically
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.saveChannelsToUserDefaults()
        }
    }
    
    // MARK: - Subscription Management
    
    func subscribe(channel: Channel) {
        var updatedChannel = channel
        updatedChannel.isSubscribed = true
        
        if !subscribedChannels.contains(where: { $0.id == channel.id }) {
            subscribedChannels.append(updatedChannel)
            
            // Initialize channel data if needed
            channelsLock.lock()
            if channels[channel.id] == nil {
                channels[channel.id] = ChannelData(
                    channel: updatedChannel,
                    events: [],
                    lastSyncTimestamp: 0
                )
            }
            channelsLock.unlock()
            
            saveChannelsToUserDefaults()
            print("✅ Subscribed to: \(channel.eventTypeDisplay)")
            
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    }
    
    func unsubscribe(channelId: String) {
        subscribedChannels.removeAll { $0.id == channelId }
        
        channelsLock.lock()
        channels.removeValue(forKey: channelId)
        channelsLock.unlock()
        
        saveChannelsToUserDefaults()
        print("✅ Unsubscribed from: \(channelId)")
        
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
    
    func isSubscribed(channelId: String) -> Bool {
        return subscribedChannels.contains { $0.id == channelId }
    }
    
    func updateChannel(_ channel: Channel) {
        if let index = subscribedChannels.firstIndex(where: { $0.id == channel.id }) {
            subscribedChannels[index] = channel
            
            channelsLock.lock()
            if var channelData = channels[channel.id] {
                channelData.channel = channel
                channels[channel.id] = channelData
            }
            channelsLock.unlock()
            
            saveChannelsToUserDefaults()
            
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    }
    
    func isChannelMuted(channelId: String) -> Bool {
        return subscribedChannels.first(where: { $0.id == channelId })?.isMuted ?? false
    }
    
    // MARK: - NEW: Get All Available Channels
    
    func getAllAvailableChannels() -> [Channel] {
        return subscribedChannels
    }
    
    // MARK: - Event Management
    
    func addEvent(_ event: Event) -> Bool {
        guard let eventId = event.id,
              let area = event.area,
              let type = event.type else {
            print("⚠️ Event missing required fields")
            return false
        }
        
        let channelId = "\(area)_\(type)"
        
        channelsLock.lock()
        defer { channelsLock.unlock() }
        
        guard var channelData = channels[channelId] else {
            print("⚠️ Channel not found: \(channelId)")
            return false
        }
        
        // Check for duplicates
        if channelData.events.contains(where: { $0.id == eventId }) {
            print("⏭️ Duplicate event: \(eventId)")
            return false
        }
        
        // Add event at the beginning (most recent first)
        channelData.events.insert(event, at: 0)
        
        // Keep only last 100 events per channel
        if channelData.events.count > 100 {
            channelData.events = Array(channelData.events.prefix(100))
        }
        
        // Update last sync timestamp
        channelData.lastSyncTimestamp = event.timestamp
        
        channels[channelId] = channelData
        
        print("✅ Event added: \(channelId) - \(eventId)")
        return true
    }
    
    func getEvents(channelId: String) -> [Event] {
        channelsLock.lock()
        defer { channelsLock.unlock() }
        
        return channels[channelId]?.events ?? []
    }
    
    func getTotalEventCount() -> Int {
        channelsLock.lock()
        defer { channelsLock.unlock() }
        
        return channels.values.reduce(0) { $0 + $1.events.count }
    }
    
    func getUnreadCount(channelId: String) -> Int {
        channelsLock.lock()
        defer { channelsLock.unlock() }
        
        guard let channelData = channels[channelId] else { return 0 }
        return channelData.events.filter { !$0.isRead }.count
    }
    
    // MARK: - Read Status Management
    
    func markAsRead(channelId: String) {
        channelsLock.lock()
        guard var channelData = channels[channelId] else {
            channelsLock.unlock()
            print("⚠️ Channel not found: \(channelId)")
            return
        }
        
        var markedCount = 0
        for i in 0..<channelData.events.count {
            if !channelData.events[i].isRead {
                channelData.events[i].isRead = true
                markedCount += 1
            }
        }
        
        if markedCount > 0 {
            channels[channelId] = channelData
            channelsLock.unlock()
            
            print("✅ Marked \(markedCount) events as read in channel: \(channelId)")
            
            // Persist changes
            saveChannelsToUserDefaults()
            
            // Notify UI to refresh
            DispatchQueue.main.async {
                self.objectWillChange.send()
                NotificationCenter.default.post(name: .eventsMarkedAsRead, object: nil)
            }
        } else {
            channelsLock.unlock()
            print("ℹ️ No unread events to mark in channel: \(channelId)")
        }
    }
    
    // MARK: - Save/Bookmark Management
    
    func toggleSaveEvent(channelId: String, eventId: String) {
        channelsLock.lock()
        guard var channelData = channels[channelId] else {
            channelsLock.unlock()
            print("⚠️ Channel not found: \(channelId)")
            return
        }
        
        // Find and toggle the event's isSaved status
        if let eventIndex = channelData.events.firstIndex(where: { $0.id == eventId }) {
            channelData.events[eventIndex].isSaved.toggle()
            let newStatus = channelData.events[eventIndex].isSaved
            channels[channelId] = channelData
            channelsLock.unlock()
            
            print("✅ Event \(eventId) save status: \(newStatus)")
            
            // Persist changes
            saveChannelsToUserDefaults()
            
            // Notify UI to refresh
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        } else {
            channelsLock.unlock()
            print("⚠️ Event not found: \(eventId)")
        }
    }
    
    func getAllSavedEvents() -> [Event] {
        channelsLock.lock()
        defer { channelsLock.unlock() }
        
        var savedEvents: [Event] = []
        
        for channelData in channels.values {
            let saved = channelData.events.filter { $0.isSaved }
            savedEvents.append(contentsOf: saved)
        }
        
        // Sort by timestamp (most recent first)
        return savedEvents.sorted { $0.timestamp > $1.timestamp }
    }
    
    func getSavedCount(channelId: String) -> Int {
        channelsLock.lock()
        defer { channelsLock.unlock() }
        
        guard let channelData = channels[channelId] else { return 0 }
        return channelData.events.filter { $0.isSaved }.count
    }
    
    // MARK: - Persistence
    
    private func saveChannelsToUserDefaults() {
        // Save subscribed channels list
        if let encoded = try? JSONEncoder().encode(subscribedChannels) {
            UserDefaults.standard.set(encoded, forKey: channelsKey)
        }
        
        // Save channel data (events)
        channelsLock.lock()
        let channelsToSave = channels
        channelsLock.unlock()
        
        if let encoded = try? JSONEncoder().encode(channelsToSave) {
            UserDefaults.standard.set(encoded, forKey: channelDataKey)
        }
        
        UserDefaults.standard.synchronize()
    }
    
    func forceSave() {
        saveChannelsToUserDefaults()
        print("💾 Force saved SubscriptionManager state")
    }
    
    private func loadChannelsFromUserDefaults() {
        // Load subscribed channels
        if let data = UserDefaults.standard.data(forKey: channelsKey),
           let decoded = try? JSONDecoder().decode([Channel].self, from: data) {
            subscribedChannels = decoded
            print("✅ Loaded \(decoded.count) subscribed channels")
        }
        
        // Load channel data (events)
        if let data = UserDefaults.standard.data(forKey: channelDataKey),
           let decoded = try? JSONDecoder().decode([String: ChannelData].self, from: data) {
            channelsLock.lock()
            channels = decoded
            channelsLock.unlock()
            
            let totalEvents = channels.values.reduce(0) { $0 + $1.events.count }
            print("✅ Loaded \(channels.count) channels with \(totalEvents) total events")
        }
    }
    
    // MARK: - Channel Sync State
    
    func getLastSyncInfo(channelId: String) -> (lastEventId: String?, lastTimestamp: Int64) {
        channelsLock.lock()
        defer { channelsLock.unlock() }
        
        guard let channelData = channels[channelId] else {
            return (nil, 0)
        }
        
        let lastEvent = channelData.events.first
        return (lastEvent?.id, channelData.lastSyncTimestamp)
    }
}

// MARK: - Notification Extensions

extension Notification.Name {
    static let eventsMarkedAsRead = Notification.Name("eventsMarkedAsRead")
}