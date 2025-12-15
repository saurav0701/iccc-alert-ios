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
    
    var channelName: String? {
        guard let area = area, let type = type else { return nil }
        return "\(area)_\(type)"
    }
    
    var isRead: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case id, timestamp, source, area, areaDisplay, type, typeDisplay
        case groupId, vehicleNumber, vehicleTransporter, data
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
    let id: Int
    let name: String
    let phone: String
    let area: String?
    let designation: String?
    let organisation: String?
    let isActive: Bool?
    let createdAt: String?
    let updatedAt: String?
    
    enum CodingKeys: String, CodingKey {
        case id, name, phone, area, designation, organisation, isActive, createdAt, updatedAt
    }
}

// MARK: - Auth Response
struct AuthResponse: Codable {
    let token: String
    let user: User
    let expiresAt: Int64?
    
    enum CodingKeys: String, CodingKey {
        case token, expiresAt, user
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        user = try container.decode(User.self, forKey: .user)
        expiresAt = try container.decodeIfPresent(Int64.self, forKey: .expiresAt)
    }
}

// MARK: - Login Request
struct LoginRequest: Codable {
    let phone: String
    let purpose: String
}

// MARK: - OTP Verification Request
struct OTPVerificationRequest: Codable {
    let phone: String
    let otp: String
    let deviceId: String
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