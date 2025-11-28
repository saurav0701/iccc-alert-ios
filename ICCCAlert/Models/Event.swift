import Foundation

struct Event: Identifiable, Codable {
    let id: String
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
    
    // Computed properties for compatibility with views
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
}

// Helper to handle dynamic JSON values
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
    
    var doubleValue: Double? {
        return value as? Double
    }
    
    var boolValue: Bool? {
        return value as? Bool
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
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = ""
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        if let bool = value as? Bool {
            try container.encode(bool)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let string = value as? String {
            try container.encode(string)
        } else {
            try container.encode("")
        }
    }
}