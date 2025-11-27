import Foundation

// MARK: - Event Model (Equivalent to Event.kt)
struct Event: Codable, Identifiable {
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
    let data: [String: AnyCodable]
    
    enum CodingKeys: String, CodingKey {
        case id, timestamp, source, area, areaDisplay, type, typeDisplay
        case groupId, vehicleNumber, vehicleTransporter, data
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        timestamp = try container.decodeIfPresent(Int64.self, forKey: .timestamp) ?? 0
        source = try container.decodeIfPresent(String.self, forKey: .source)
        area = try container.decodeIfPresent(String.self, forKey: .area)
        areaDisplay = try container.decodeIfPresent(String.self, forKey: .areaDisplay)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        typeDisplay = try container.decodeIfPresent(String.self, forKey: .typeDisplay)
        groupId = try container.decodeIfPresent(String.self, forKey: .groupId)
        vehicleNumber = try container.decodeIfPresent(String.self, forKey: .vehicleNumber)
        vehicleTransporter = try container.decodeIfPresent(String.self, forKey: .vehicleTransporter)
        data = try container.decodeIfPresent([String: AnyCodable].self, forKey: .data) ?? [:]
    }
}

// MARK: - Channel Model
struct Channel: Codable, Identifiable {
    let id: String
    let area: String
    let areaDisplay: String
    let eventType: String
    let eventTypeDisplay: String
    let description: String
    var isSubscribed: Bool
    var isMuted: Bool
    var isPinned: Bool
    
    init(
        id: String,
        area: String,
        areaDisplay: String,
        eventType: String,
        eventTypeDisplay: String,
        description: String,
        isSubscribed: Bool = false,
        isMuted: Bool = false,
        isPinned: Bool = false
    ) {
        self.id = id
        self.area = area
        self.areaDisplay = areaDisplay
        self.eventType = eventType
        self.eventTypeDisplay = eventTypeDisplay
        self.description = description
        self.isSubscribed = isSubscribed
        self.isMuted = isMuted
        self.isPinned = isPinned
    }
}

// MARK: - Subscription Models
struct SubscriptionFilter: Codable {
    let area: String
    let eventType: String
}

struct SubscriptionRequestV2: Codable {
    let clientId: String
    let filters: [SubscriptionFilter]
    let syncState: [String: SyncStateInfo]?
    let resetConsumers: Bool
}

struct SyncStateInfo: Codable {
    let lastEventId: String?
    let lastTimestamp: Int64
    let lastSeq: Int64
}

// MARK: - ACK Message
struct AckMessage: Codable {
    let type: String
    let eventId: String?
    let eventIds: [String]?
    let clientId: String
}

// MARK: - AnyCodable (Helper for dynamic JSON)
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
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary.mapValues { $0.value }
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
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - Available Channels (Static Data)
enum AvailableChannels {
    static let areas: [(code: String, display: String)] = [
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
    
    static let eventTypes: [(code: String, display: String)] = [
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
    
    static func getAllChannels() -> [Channel] {
        var channels: [Channel] = []
        for area in areas {
            for eventType in eventTypes {
                let channel = Channel(
                    id: "\(area.code)_\(eventType.code)",
                    area: area.code,
                    areaDisplay: area.display,
                    eventType: eventType.code,
                    eventTypeDisplay: eventType.display,
                    description: "\(area.display) - \(eventType.display)"
                )
                channels.append(channel)
            }
        }
        return channels
    }
}

// MARK: - Client ID Manager
class ClientIdManager {
    static let shared = ClientIdManager()
    private let userDefaults = UserDefaults.standard
    private let clientIdKey = "client_id"
    
    func getOrCreateClientId() -> String {
        if let existingId = userDefaults.string(forKey: clientIdKey) {
            print("✅ Using existing persistent client ID: \(existingId)")
            return existingId
        }
        
        // Generate new stable client ID
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        let uuid = UUID().uuidString.prefix(8)
        let clientId = "ios-\(deviceId)-\(uuid)"
        
        // Save permanently
        userDefaults.set(clientId, forKey: clientIdKey)
        print("✅ Created new persistent client ID: \(clientId)")
        
        return clientId
    }
    
    func getCurrentClientId() -> String? {
        return userDefaults.string(forKey: clientIdKey)
    }
    
    func resetClientId() {
        let oldId = getCurrentClientId()
        userDefaults.removeObject(forKey: clientIdKey)
        print("⚠️ Client ID reset (old ID: \(oldId ?? "none"))")
    }
    
    func hasClientId() -> Bool {
        return userDefaults.string(forKey: clientIdKey) != nil
    }
}