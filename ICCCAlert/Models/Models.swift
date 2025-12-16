import Foundation

// MARK: - Event Model

struct Event: Identifiable, Codable, Equatable {
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
    var isRead: Bool = false
    
    // Custom coding keys to handle optional isRead
    enum CodingKeys: String, CodingKey {
        case id, timestamp, source, area, areaDisplay, type, typeDisplay
        case groupId, vehicleNumber, vehicleTransporter, data, isRead
    }
    
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
        
        // Decode data - handle both empty and populated cases
        if let dataDict = try? container.decode([String: AnyCodable].self, forKey: .data) {
            data = dataDict
        } else {
            data = [:]
        }
        
        isRead = (try? container.decode(Bool.self, forKey: .isRead)) ?? false
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
        try container.encodeIfPresent(vehicleNumber, forKey: .vehicleTransporter)
        try container.encodeIfPresent(vehicleTransporter, forKey: .vehicleTransporter)
        try container.encode(data, forKey: .data)
        try container.encode(isRead, forKey: .isRead)
    }
    
    // Manual initializer for creating events programmatically
    init(id: String?, timestamp: Int64, source: String?, area: String?, 
         areaDisplay: String?, type: String?, typeDisplay: String?, 
         groupId: String?, vehicleNumber: String?, vehicleTransporter: String?,
         data: [String: AnyCodable], isRead: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.area = area
        self.areaDisplay = areaDisplay
        self.type = type
        self.typeDisplay = typeDisplay
        self.groupId = groupId
        self.vehicleNumber = vehicleNumber
        self.vehicleTransporter = vehicleTransporter
        self.data = data
        self.isRead = isRead
    }
    
    // Computed properties
    var title: String {
        return typeDisplay ?? type ?? "Alert"
    }
    
    var message: String {
        if let desc = data["description"]?.stringValue {
            return desc
        }
        return location
    }
    
    var channelName: String? {
        guard let area = area, let type = type else { return nil }
        return "\(area)_\(type)"
    }
    
    var priority: String? {
        return data["priority"]?.stringValue ?? "normal"
    }
    
    var createdAt: String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
    
    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
    
    var location: String {
        if let loc = data["location"]?.stringValue {
            return loc
        }
        return "Unknown Location"
    }
    
    var eventTime: String? {
        return data["eventTime"]?.stringValue
    }
    
    var sequence: Int64? {
        if let seq = data["_seq"]?.int64Value {
            return seq
        } else if let seqStr = data["_seq"]?.stringValue,
                  let seq = Int64(seqStr) {
            return seq
        }
        return nil
    }
    
    var requiresAck: Bool {
        return data["_requireAck"]?.boolValue ?? true
    }
    
    // GPS-specific properties
    var isGPSEvent: Bool {
        return type == "off-route" || type == "tamper" || type == "overspeed"
    }
    
    var currentLocation: GPSLocation? {
        guard let locData = data["currentLocation"]?.dictionaryValue else {
            return nil
        }
        guard let lat = locData["lat"]?.doubleValue,
              let lng = locData["lng"]?.doubleValue else {
            return nil
        }
        return GPSLocation(lat: lat, lng: lng)
    }
    
    var alertLocation: GPSLocation? {
        guard let locData = data["alertLocation"]?.dictionaryValue else {
            return nil
        }
        guard let lat = locData["lat"]?.doubleValue,
              let lng = locData["lng"]?.doubleValue else {
            return nil
        }
        return GPSLocation(lat: lat, lng: lng)
    }
    
    static func == (lhs: Event, rhs: Event) -> Bool {
        return lhs.id == rhs.id
    }
}

// MARK: - GPS Location

struct GPSLocation: Codable {
    let lat: Double
    let lng: Double
}

// MARK: - Channel Model

struct Channel: Identifiable, Codable, Equatable {
    let id: String
    let area: String
    let areaDisplay: String
    let eventType: String
    let eventTypeDisplay: String
    let description: String?
    var isSubscribed: Bool = false
    var isMuted: Bool = false
    var isPinned: Bool = false
    
    // Computed properties for compatibility
    var name: String {
        return areaDisplay
    }
    
    var category: String {
        return eventTypeDisplay
    }
    
    enum CodingKeys: String, CodingKey {
        case id, area, areaDisplay, eventType, eventTypeDisplay, description
        case isSubscribed, isMuted, isPinned
    }
    
    static func == (lhs: Channel, rhs: Channel) -> Bool {
        return lhs.id == rhs.id
    }
}

// MARK: - Subscription Models

struct SubscriptionFilter: Codable {
    let area: String
    let eventType: String
}

struct SyncStateInfo: Codable {
    let lastEventId: String?
    let lastTimestamp: Int64
    let lastSeq: Int64
}

struct SubscriptionRequest: Codable {
    let clientId: String
    let filters: [SubscriptionFilter]
    let syncState: [String: SyncStateInfo]?
    let resetConsumers: Bool
}

// MARK: - Auth Models

struct User: Codable {
    let id: Int
    let name: String
    let phone: String
    let area: String?
    let designation: String?
    let organisation: String?
    let createdAt: String
    let updatedAt: String?
    
    enum CodingKeys: String, CodingKey {
        case id, name, phone, area, designation, organisation, createdAt, updatedAt
    }
}

struct LoginRequest: Codable {
    let phone: String
    let purpose: String
}

struct OTPVerificationRequest: Codable {
    let phone: String
    let otp: String
    let deviceId: String
}

struct AuthResponse: Codable {
    let token: String
    let expiresAt: Int64
    let user: User
}

// MARK: - AnyCodable Helper (FIXED VERSION)

struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    var stringValue: String? {
        if let str = value as? String {
            return str
        }
        if let num = value as? NSNumber {
            return num.stringValue
        }
        return nil
    }
    
    var intValue: Int? {
        if let int = value as? Int {
            return int
        }
        if let str = value as? String, let int = Int(str) {
            return int
        }
        return nil
    }
    
    var int64Value: Int64? {
        if let int64 = value as? Int64 {
            return int64
        }
        if let int = value as? Int {
            return Int64(int)
        }
        if let str = value as? String, let int64 = Int64(str) {
            return int64
        }
        return nil
    }
    
    var doubleValue: Double? {
        if let double = value as? Double {
            return double
        }
        if let int = value as? Int {
            return Double(int)
        }
        if let float = value as? Float {
            return Double(float)
        }
        if let str = value as? String, let double = Double(str) {
            return double
        }
        return nil
    }
    
    var boolValue: Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let int = value as? Int {
            return int != 0
        }
        if let str = value as? String {
            return str.lowercased() == "true" || str == "1"
        }
        return nil
    }
    
    var arrayValue: [Any]? {
        return value as? [Any]
    }
    
    var dictionaryValue: [String: AnyCodable]? {
        guard let dict = value as? [String: Any] else {
            return nil
        }
        return dict.mapValues { AnyCodable($0) }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        // Try to decode in order of specificity
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
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
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable value cannot be decoded"
            )
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case is NSNull:
            try container.encodeNil()
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
            let codableArray = array.map { AnyCodable($0) }
            try container.encode(codableArray)
        case let dict as [String: Any]:
            let codableDict = dict.mapValues { AnyCodable($0) }
            try container.encode(codableDict)
        default:
            let context = EncodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "AnyCodable value cannot be encoded"
            )
            throw EncodingError.invalidValue(value, context)
        }
    }
}

// MARK: - Event Type Helpers

enum EventType: String, CaseIterable {
    case cd = "cd"
    case vd = "vd"
    case pd = "pd"
    case id = "id"
    case vc = "vc"
    case ls = "ls"
    case us = "us"
    case ct = "ct"
    case sh = "sh"
    case ii = "ii"
    case offRoute = "off-route"
    case tamper = "tamper"
    
    var displayName: String {
        switch self {
        case .cd: return "Crowd Detection"
        case .vd: return "Vehicle Detection"
        case .pd: return "Person Detection"
        case .id: return "Intrusion Detection"
        case .vc: return "Vehicle Congestion"
        case .ls: return "Loading Status"
        case .us: return "Unloading Status"
        case .ct: return "Camera Tampering"
        case .sh: return "Safety Hazard"
        case .ii: return "Insufficient Illumination"
        case .offRoute: return "Off-Route Alert"
        case .tamper: return "Tamper Alert"
        }
    }
    
    var iconName: String {
        switch self {
        case .cd: return "person.3.fill"
        case .vd: return "car.fill"
        case .pd: return "person.fill"
        case .id: return "exclamationmark.triangle.fill"
        case .vc: return "car.2.fill"
        case .ls: return "arrow.up.bin.fill"
        case .us: return "arrow.down.bin.fill"
        case .ct: return "video.slash.fill"
        case .sh: return "exclamationmark.shield.fill"
        case .ii: return "lightbulb.slash.fill"
        case .offRoute: return "location.slash.fill"
        case .tamper: return "hand.raised.slash.fill"
        }
    }
    
    var color: String {
        switch self {
        case .cd: return "#FF5722"
        case .vd: return "#2196F3"
        case .pd: return "#4CAF50"
        case .id: return "#F44336"
        case .vc: return "#FFC107"
        case .ls: return "#00BCD4"
        case .us: return "#00BCD4"
        case .ct: return "#E91E63"
        case .sh: return "#FF9800"
        case .ii: return "#9C27B0"
        case .offRoute: return "#FF5722"
        case .tamper: return "#F44336"
        }
    }
}