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
        return areaDisplay ?? area
    }
    
    var priority: String? {
        // Determine priority based on event type
        guard let eventType = type?.lowercased() else {
            return "normal"
        }
        
        switch eventType {
        case "id", "ct", "sh", "tamper": // Intrusion, Camera Tamper, Safety Hazard, Tamper
            return "high"
        case "cd", "vc", "off-route": // Crowd, Vehicle Congestion, Off-Route
            return "medium"
        default:
            return "low"
        }
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
    
    // Geofence data (for GPS events)
    var geofenceData: GeofenceData? {
        guard let geofenceDict = data["geofence"]?.dictionaryValue else {
            return nil
        }
        
        guard let id = geofenceDict["id"]?.intValue,
              let name = geofenceDict["name"]?.stringValue else {
            return nil
        }
        
        return GeofenceData(
            id: id,
            name: name,
            description: geofenceDict["description"]?.stringValue,
            geoType: geofenceDict["geotype"]?.stringValue,
            attributes: geofenceDict["attributes"]?.dictionaryValue,
            geoJSON: geofenceDict["geojson"]?.value
        )
    }
    
    static func == (lhs: Event, rhs: Event) -> Bool {
        return lhs.id == rhs.id
    }
    
    enum CodingKeys: String, CodingKey {
        case id, timestamp, source, area, areaDisplay, type, typeDisplay
        case groupId, vehicleNumber, vehicleTransporter, data, isRead
    }
}

// MARK: - GPS Location

struct GPSLocation: Codable {
    let lat: Double
    let lng: Double
}

// MARK: - Geofence Data

struct GeofenceData {
    let id: Int
    let name: String
    let description: String?
    let geoType: String?
    let attributes: [String: AnyCodable]?
    let geoJSON: Any?
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

struct SubscriptionRequest: Codable {
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
    
    // Computed property for backward compatibility
    var username: String {
        return name
    }
    
    var role: String {
        return designation ?? "User"
    }
    
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

// MARK: - AnyCodable Helper

struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    var stringValue: String? {
        return value as? String
    }
    
    var intValue: Int? {
        return value as? Int
    }
    
    var int64Value: Int64? {
        if let int = value as? Int {
            return Int64(int)
        }
        return value as? Int64
    }
    
    var doubleValue: Double? {
        if let double = value as? Double {
            return double
        } else if let int = value as? Int {
            return Double(int)
        } else if let float = value as? Float {
            return Double(float)
        }
        return nil
    }
    
    var boolValue: Bool? {
        return value as? Bool
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
        } else if container.decodeNil() {
            value = NSNull()
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
        case is NSNull:
            try container.encodeNil()
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
    case overspeed = "overspeed"
    
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
        case .overspeed: return "Overspeed Alert"
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
        case .overspeed: return "gauge.badge.plus"
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
        case .overspeed: return "#FF6B35"
        }
    }
}

// MARK: - Area Helpers

enum Area: String, CaseIterable {
    case barkasayal = "barkasayal"
    case argada = "argada"
    case northkaranpura = "northkaranpura"
    case bokarokargali = "bokarokargali"
    case kathara = "kathara"
    case giridih = "giridih"
    case amrapali = "amrapali"
    case rajhara = "rajhara"
    case kuju = "kuju"
    case hazaribagh = "hazaribagh"
    case rajrappa = "rajrappa"
    case dhori = "dhori"
    case piparwar = "piparwar"
    case magadh = "magadh"
    
    var displayName: String {
        switch self {
        case .barkasayal: return "Barka Sayal"
        case .argada: return "Argada"
        case .northkaranpura: return "North Karanpura"
        case .bokarokargali: return "Bokaro & Kargali"
        case .kathara: return "Kathara"
        case .giridih: return "Giridih"
        case .amrapali: return "Amrapali & Chandragupta"
        case .rajhara: return "Rajhara"
        case .kuju: return "Kuju"
        case .hazaribagh: return "Hazaribagh"
        case .rajrappa: return "Rajrappa"
        case .dhori: return "Dhori"
        case .piparwar: return "Piparwar"
        case .magadh: return "Magadh"
        }
    }
}

// MARK: - Helper Extensions

extension Event {
    /// Returns a formatted time string (e.g., "2m ago", "1h ago")
    func timeAgo() -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)
        
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
    
    /// Returns formatted timestamp (e.g., "Dec 15, 3:45 PM")
    func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

extension Channel {
    /// Returns icon color based on event type
    var iconColor: String {
        if let eventType = EventType(rawValue: eventType) {
            return eventType.color
        }
        return "#9E9E9E" // Default gray
    }
    
    /// Returns SF Symbol name for icon
    var iconName: String {
        if let eventType = EventType(rawValue: eventType) {
            return eventType.iconName
        }
        return "bell.fill" // Default icon
    }
}

// Note: Color(hex:) extension is defined in ChannelsView.swift to avoid duplication