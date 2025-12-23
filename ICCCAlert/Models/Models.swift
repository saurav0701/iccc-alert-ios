import Foundation

// MARK: - System Filter (for AlertsView)

enum SystemFilter {
    case all
    case va   // Video Analytics (camera events)
    case vts  // Vehicle Tracking System (GPS events)
}

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
    var isSaved: Bool = false
    
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, source, area, areaDisplay, type, typeDisplay
        case groupId, vehicleNumber, vehicleTransporter, data
    }
    
    // ✅ FIXED: Correct date conversion with VA timezone adjustment
    var date: Date {
        // Backend sends Unix timestamp in SECONDS (not milliseconds)
        // Swift Date() expects seconds since 1970, so use directly
        
        // ✅ CRITICAL: VA events have IST times parsed as UTC by backend
        // This means they're 5:30 hours ahead. We need to subtract that offset.
        // VTS events don't have this issue (they use correct UTC timestamps)
        
        let baseDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
        
        // Check if this is a VA event (camera events) vs VTS event (GPS)
        // VTS events have these types: off-route, tamper, overspeed
        let isVTSEvent = type == "off-route" || type == "tamper" || type == "overspeed"
        
        if isVTSEvent {
            // VTS events are correct, use as-is
            return baseDate
        } else {
            return baseDate.addingTimeInterval(-19800) 
        }
    }
    
    var isGpsEvent: Bool {
        return type == "off-route" || type == "tamper" || type == "overspeed"
    }
    
    var message: String {
        if isGpsEvent {
            // Try geofence name first
            if let geofence = data?["geofence"]?.dictionaryValue,
               let name = geofence["name"]?.stringValue {
                return name
            }
            
            // Try alertLocation coordinates
            if let alertLoc = data?["alertLocation"]?.dictionaryValue,
               let lat = alertLoc["lat"]?.doubleValue,
               let lng = alertLoc["lng"]?.doubleValue {
                return String(format: "%.6f, %.6f", lat, lng)
            }
            
            // Try allocatedGeofence
            if let allocated = data?["allocatedGeofence"]?.arrayValue,
               let first = allocated.first?.stringValue {
                return first
            }
            
            return "GPS Alert Location"
        }
        
        // For camera events: use location field
        if let location = data?["location"]?.stringValue {
            return location
        }
        
        return "Unknown location"
    }
    
    var location: String {
        return message
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

struct User: Codable {
    let id: Int
    let name: String
    let phone: String
    let area: String
    let designation: String
    let organisation: String
    let isActive: Bool
    let createdAt: String
    let updatedAt: String
    
    enum CodingKeys: String, CodingKey {
        case id, name, phone, area, designation, organisation, isActive, createdAt, updatedAt
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

struct ApiResponse<T: Codable>: Codable {
    let success: Bool?
    let message: String?
    let error: String?
    let data: T?
}


struct GpsLocation: Codable {
    let lat: Double
    let lng: Double
}

struct GeofenceInfo: Codable {
    let id: Int
    let name: String?
    let description: String?
    let type: String?
    let attributes: GeofenceAttributes?
    let geojson: GeoJsonGeometry?
}

struct GeofenceAttributes: Codable {
    let color: String?
    let polylineColor: String?
    let speed: Int?
}

struct GeoJsonGeometry: Codable {
    let type: String
    let coordinates: AnyCodableValue
    
    // Helper to get coordinates as array
    var coordinatesArray: [[Double]]? {
        switch type {
        case "Point":
            if case .array(let arr) = coordinates,
               arr.count >= 2,
               case .double(let lng) = arr[0],
               case .double(let lat) = arr[1] {
                return [[lng, lat]]
            }
        case "LineString":
            if case .array(let arr) = coordinates {
                return arr.compactMap { coord -> [Double]? in
                    if case .array(let point) = coord,
                       point.count >= 2,
                       case .double(let lng) = point[0],
                       case .double(let lat) = point[1] {
                        return [lng, lat]
                    }
                    return nil
                }
            }
        case "Polygon":
            if case .array(let rings) = coordinates,
               let firstRing = rings.first,
               case .array(let ring) = firstRing {
                return ring.compactMap { coord -> [Double]? in
                    if case .array(let point) = coord,
                       point.count >= 2,
                       case .double(let lng) = point[0],
                       case .double(let lat) = point[1] {
                        return [lng, lat]
                    }
                    return nil
                }
            }
        default:
            break
        }
        return nil
    }
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
        if case .int(let value) = self {
            return Double(value)
        }
        if case .int64(let value) = self {
            return Double(value)
        }
        return nil
    }
    
    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }
    
    var arrayValue: [AnyCodableValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }
    
    var dictionaryValue: [String: AnyCodableValue]? {
        if case .dictionary(let value) = self {
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

// MARK: - Helper Extensions

extension Event {
    // Extract GPS location data
    var gpsAlertLocation: GpsLocation? {
        guard let alertLoc = data?["alertLocation"]?.dictionaryValue else { return nil }
        guard let lat = alertLoc["lat"]?.doubleValue,
              let lng = alertLoc["lng"]?.doubleValue else { return nil }
        return GpsLocation(lat: lat, lng: lng)
    }
    
    var gpsCurrentLocation: GpsLocation? {
        guard let currentLoc = data?["currentLocation"]?.dictionaryValue else { return nil }
        guard let lat = currentLoc["lat"]?.doubleValue,
              let lng = currentLoc["lng"]?.doubleValue else { return nil }
        return GpsLocation(lat: lat, lng: lng)
    }
    
    var geofenceInfo: GeofenceInfo? {
        guard let geofenceDict = data?["geofence"]?.dictionaryValue else { return nil }
        
        let id = geofenceDict["id"]?.intValue ?? 0
        let name = geofenceDict["name"]?.stringValue
        let description = geofenceDict["description"]?.stringValue
        let type = geofenceDict["type"]?.stringValue
        
        var attributes: GeofenceAttributes?
        if let attrsDict = geofenceDict["attributes"]?.dictionaryValue {
            attributes = GeofenceAttributes(
                color: attrsDict["color"]?.stringValue,
                polylineColor: attrsDict["polylineColor"]?.stringValue,
                speed: attrsDict["speed"]?.intValue
            )
        }
        
        var geojson: GeoJsonGeometry?
        if let geojsonDict = geofenceDict["geojson"]?.dictionaryValue,
           let geoType = geojsonDict["type"]?.stringValue,
           let coords = geojsonDict["coordinates"] {
            geojson = GeoJsonGeometry(type: geoType, coordinates: coords)
        }
        
        return GeofenceInfo(
            id: id,
            name: name,
            description: description,
            type: type,
            attributes: attributes,
            geojson: geojson
        )
    }
    
    var alertSubType: String? {
        return data?["alertSubType"]?.stringValue
    }
    
    var allocatedGeofence: [String]? {
        return data?["allocatedGeofence"]?.arrayValue?.compactMap { $0.stringValue }
    }
}