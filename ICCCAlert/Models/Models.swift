import Foundation

// MARK: - Event Model
struct Event: Identifiable, Codable {
    let id: String?
    let timestamp: Int64
    let source: String?
    let area: String?
    let areaDisplay: String?
    let type: String?
    let typeDisplay: String?
    let groupId: String?
    let vehicleNumber: String?
    let vehicleTransporter: String?
    let data: [String: AnyCodable]?
    
    // Computed properties
    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
    
    var location: String {
        if let location = data?["location"]?.value as? String {
            return location
        }
        return areaDisplay ?? area ?? "Unknown Location"
    }
    
    var priority: String? {
        data?["priority"]?.value as? String
    }
    
    var title: String {
        typeDisplay ?? type?.capitalized ?? "Event"
    }
    
    var message: String {
        if let eventData = data {
            if let desc = eventData["description"]?.value as? String {
                return desc
            }
            if let msg = eventData["message"]?.value as? String {
                return msg
            }
        }
        return "\(title) at \(location)"
    }
    
    // **CRITICAL FIX**: Properly compute channelName from area and type
    var channelName: String? {
        guard let area = area, let type = type else { return nil }
        return "\(area)_\(type)"
    }
    
    // Track read status (not from server, managed locally)
    var isRead: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case id, timestamp, source, area, areaDisplay, type, typeDisplay
        case groupId, vehicleNumber, vehicleTransporter, data
    }
    
    // Custom decoder to handle flexible data types
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decodeIfPresent(String.self, forKey: .id)
        timestamp = try container.decode(Int64.self, forKey: .timestamp)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        area = try container.decodeIfPresent(String.self, forKey: .area)
        areaDisplay = try container.decodeIfPresent(String.self, forKey: .areaDisplay)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        typeDisplay = try container.decodeIfPresent(String.self, forKey: .typeDisplay)
        groupId = try container.decodeIfPresent(String.self, forKey: .groupId)
        vehicleNumber = try container.decodeIfPresent(String.self, forKey: .vehicleNumber)
        vehicleTransporter = try container.decodeIfPresent(String.self, forKey: .vehicleTransporter)
        
        // Decode data as dictionary of AnyCodable
        if let dataDict = try? container.decode([String: AnyCodable].self, forKey: .data) {
            data = dataDict
        } else {
            data = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(area, forKey: .area)
        try container.encodeIfPresent(areaDisplay, forKey: .areaDisplay)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(typeDisplay, forKey: .typeDisplay)
        try container.encodeIfPresent(groupId, forKey: .groupId)
        try container.encodeIfPresent(vehicleNumber, forKey: .vehicleNumber)
        try container.encodeIfPresent(vehicleTransporter, forKey: .vehicleTransporter)
        try container.encodeIfPresent(data, forKey: .data)
    }
}

// MARK: - AnyCodable Helper
struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let int64 = try? container.decode(Int64.self) {
            value = int64
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let int64 as Int64:
            try container.encode(int64)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - Channel Model
struct Channel: Identifiable, Codable, Equatable {
    let id: String
    let area: String
    let areaDisplay: String
    let eventType: String
    let eventTypeDisplay: String
    let description: String
    var isSubscribed: Bool = false
    var isMuted: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case id, area, areaDisplay, eventType, eventTypeDisplay, description, isSubscribed, isMuted
    }
    
    static func == (lhs: Channel, rhs: Channel) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - User Model
struct User: Codable {
    let id: String
    let username: String
    let email: String?
    let role: String?
    let createdAt: String?
    
    enum CodingKeys: String, CodingKey {
        case id, username, email, role, createdAt
    }
}

// MARK: - Auth Response
struct AuthResponse: Codable {
    let token: String
    let user: User
}

// MARK: - Login Request
struct LoginRequest: Codable {
    let username: String
    let password: String
}

// MARK: - Register Request
struct RegisterRequest: Codable {
    let username: String
    let email: String
    let password: String
}

// MARK: - API Error Response
struct APIError: Codable {
    let error: String
    let message: String?
    let statusCode: Int?
}

// MARK: - Subscription State
struct SubscriptionState: Codable {
    let channelId: String
    let lastEventId: String?
    let lastTimestamp: Int64?
    let lastSeq: Int64?
    let eventsReceived: Int
    
    enum CodingKeys: String, CodingKey {
        case channelId, lastEventId, lastTimestamp, lastSeq, eventsReceived
    }
}

// MARK: - Channel Sync State
class ChannelSyncState {
    static let shared = ChannelSyncState()
    
    private var channelStates: [String: ChannelState] = [:]
    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private let stateKey = "channel_sync_states"
    
    private struct ChannelState: Codable {
        var lastEventId: String?
        var lastTimestamp: Int64 = 0
        var lastSeq: Int64 = 0
        var eventsReceived: Int = 0
        var recentEventIds: Set<String> = []
        var isInCatchUpMode: Bool = false
        var catchUpStartTime: Date?
        var catchUpEventsProcessed: Int = 0
    }
    
    private init() {
        loadStates()
    }
    
    func recordEventReceived(channelId: String, eventId: String, timestamp: Int64, seq: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        var state = channelStates[channelId] ?? ChannelState()
        
        // Check if already received
        if state.recentEventIds.contains(eventId) {
            return false
        }
        
        // Add to recent IDs
        state.recentEventIds.insert(eventId)
        
        // Keep only last 100 event IDs
        if state.recentEventIds.count > 100 {
            state.recentEventIds.removeFirst()
        }
        
        // Update state
        state.lastEventId = eventId
        state.lastTimestamp = max(state.lastTimestamp, timestamp)
        state.lastSeq = max(state.lastSeq, seq)
        state.eventsReceived += 1
        
        if state.isInCatchUpMode {
            state.catchUpEventsProcessed += 1
        }
        
        channelStates[channelId] = state
        scheduleSave()
        
        return true
    }
    
    func enableCatchUpMode(channelId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        var state = channelStates[channelId] ?? ChannelState()
        state.isInCatchUpMode = true
        state.catchUpStartTime = Date()
        state.catchUpEventsProcessed = 0
        channelStates[channelId] = state
    }
    
    func disableCatchUpMode(channelId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        var state = channelStates[channelId] ?? ChannelState()
        state.isInCatchUpMode = false
        state.catchUpStartTime = nil
        channelStates[channelId] = state
    }
    
    func isInCatchUpMode(channelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        return channelStates[channelId]?.isInCatchUpMode ?? false
    }
    
    func getCatchUpProgress(channelId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        return channelStates[channelId]?.catchUpEventsProcessed ?? 0
    }
    
    func getLastSequence(channelId: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        
        return channelStates[channelId]?.lastSeq ?? 0
    }
    
    func getTotalEventsReceived() -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        return channelStates.values.reduce(0) { $0 + $1.eventsReceived }
    }
    
    func getAllSyncStates() -> [String: SubscriptionState] {
        lock.lock()
        defer { lock.unlock() }
        
        var states: [String: SubscriptionState] = [:]
        for (channelId, state) in channelStates {
            states[channelId] = SubscriptionState(
                channelId: channelId,
                lastEventId: state.lastEventId,
                lastTimestamp: state.lastTimestamp,
                lastSeq: state.lastSeq,
                eventsReceived: state.eventsReceived
            )
        }
        return states
    }
    
    func clearChannel(channelId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        channelStates.removeValue(forKey: channelId)
        scheduleSave()
    }
    
    // MARK: - Persistence
    
    private var saveTimer: Timer?
    
    private func scheduleSave() {
        saveTimer?.invalidate()
        
        DispatchQueue.main.async { [weak self] in
            self?.saveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                self?.saveStates()
            }
        }
    }
    
    private func saveStates() {
        lock.lock()
        let statesToSave = channelStates
        lock.unlock()
        
        if let data = try? JSONEncoder().encode(statesToSave) {
            defaults.set(data, forKey: stateKey)
        }
    }
    
    private func loadStates() {
        if let data = defaults.data(forKey: stateKey),
           let states = try? JSONDecoder().decode([String: ChannelState].self, from: data) {
            channelStates = states
            print("📊 Loaded sync states for \(states.count) channels")
        }
    }
    
    func forceSave() {
        saveTimer?.invalidate()
        saveStates()
    }
}

// MARK: - Keychain Client ID
class KeychainClientID {
    private static let service = "com.iccc.alert"
    private static let account = "persistent_client_id"
    
    static func getOrCreateClientID() -> String {
        // Try to get from keychain
        if let existingID = getFromKeychain() {
            return existingID
        }
        
        // Generate new ID
        let newID = UUID().uuidString
        saveToKeychain(newID)
        return newID
    }
    
    private static func getFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let clientID = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return clientID
    }
    
    private static func saveToKeychain(_ clientID: String) {
        guard let data = clientID.data(using: .utf8) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        
        // Delete any existing item
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        SecItemAdd(query as CFDictionary, nil)
    }
}