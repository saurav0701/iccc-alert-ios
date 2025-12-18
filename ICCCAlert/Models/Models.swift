import Foundation

// MARK: - Event

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
    let data: [String: AnyCodableValue]?
    
    var isRead: Bool = false
    var priority: String?
    
    var date: Date {
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
    
    var message: String {
        return data?["location"]?.stringValue ?? "Unknown location"
    }
    
    var location: String {
        return data?["location"]?.stringValue ?? "Unknown location"
    }
}

// MARK: - Channel

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
}

// MARK: - User

struct User: Codable {
    let id: String
    let name: String
    let phone: String
    let area: String
    let designation: String
    let workingFor: String
}

// MARK: - Auth

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

struct ApiResponse<T: Codable>: Codable {
    let success: Bool?
    let message: String?
    let error: String?
    let data: T?
}

// MARK: - AnyCodableValue

enum AnyCodableValue: Codable {
    case string(String)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case dictionary([String: AnyCodableValue])
    case null
    
    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
    
    var intValue: Int? {
        if case .int(let value) = self {
            return value
        }
        if case .int64(let value) = self {
            return Int(value)
        }
        return nil
    }
    
    var int64Value: Int64? {
        if case .int64(let value) = self {
            return value
        }
        if case .int(let value) = self {
            return Int64(value)
        }
        return nil
    }
    
    var doubleValue: Double? {
        if case .double(let value) = self {
            return value
        }
        return nil
    }
    
    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int64(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([AnyCodableValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AnyCodableValue].self) {
            self = .dictionary(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode AnyCodableValue"
            )
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .int64(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .dictionary(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}