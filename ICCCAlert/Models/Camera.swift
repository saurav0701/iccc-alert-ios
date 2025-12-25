import Foundation

// MARK: - Camera Model (matches backend exactly, with defaults for optional fields)

struct Camera: Codable, Identifiable, Equatable {
    let category: String
    let id: String
    let ip: String
    let Id: Int
    let deviceId: Int
    let Name: String
    let name: String
    let latitude: String
    let longitude: String
    let status: String
    let groupId: Int
    let area: String
    let transporter: String
    let location: String
    let lastUpdate: String
    
    enum CodingKeys: String, CodingKey {
        case category, id, ip, Id
        case deviceId = "device_id"
        case Name, name, latitude, longitude, status
        case groupId = "groupId"
        case area, transporter, location
        case lastUpdate = "lastUpdate"
    }
    
    // Custom decoder to handle missing/null fields gracefully
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "camera"
        id = try container.decode(String.self, forKey: .id)
        ip = try container.decodeIfPresent(String.self, forKey: .ip) ?? ""
        Id = try container.decodeIfPresent(Int.self, forKey: .Id) ?? 0
        deviceId = try container.decodeIfPresent(Int.self, forKey: .deviceId) ?? 0
        Name = try container.decodeIfPresent(String.self, forKey: .Name) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        latitude = try container.decodeIfPresent(String.self, forKey: .latitude) ?? ""
        longitude = try container.decodeIfPresent(String.self, forKey: .longitude) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "offline"
        groupId = try container.decodeIfPresent(Int.self, forKey: .groupId) ?? 0
        area = try container.decodeIfPresent(String.self, forKey: .area) ?? "Unknown"
        transporter = try container.decodeIfPresent(String.self, forKey: .transporter) ?? ""
        location = try container.decodeIfPresent(String.self, forKey: .location) ?? ""
        lastUpdate = try container.decodeIfPresent(String.self, forKey: .lastUpdate) ?? ""
    }
    
    // Standard encoder
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(category, forKey: .category)
        try container.encode(id, forKey: .id)
        try container.encode(ip, forKey: .ip)
        try container.encode(Id, forKey: .Id)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(Name, forKey: .Name)
        try container.encode(name, forKey: .name)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(status, forKey: .status)
        try container.encode(groupId, forKey: .groupId)
        try container.encode(area, forKey: .area)
        try container.encode(transporter, forKey: .transporter)
        try container.encode(location, forKey: .location)
        try container.encode(lastUpdate, forKey: .lastUpdate)
    }
    
    var isOnline: Bool {
        return status.lowercased() == "online"
    }
    
    var displayName: String {
        // Prefer 'name' field, fallback to 'Name'
        if !name.isEmpty {
            return name
        }
        return Name.isEmpty ? "Camera \(id)" : Name
    }
    
    var streamURL: String? {
        return getStreamURL(for: groupId, cameraId: id)
    }
    
    // Server URL mapping based on groupId
    private func getStreamURL(for groupId: Int, cameraId: String) -> String? {
        let serverURLs: [Int: String] = [
            5: "http://103.208.173.131:8888",
            6: "http://103.208.173.147:8888",
            7: "http://103.208.173.163:8888",
            8: "http://a5va.bccliccc.in:8888",
            9: "http://a5va.bccliccc.in:8888",
            10: "http://a6va.bccliccc.in:8888",
            11: "http://103.208.173.195:8888",
            12: "http://a9va.bccliccc.in:8888",
            13: "http://a10va.bccliccc.in:8888",
            14: "http://103.210.88.195:8888",
            15: "http://103.210.88.211:8888",
            16: "http://103.208.173.179:8888",
            22: "http://103.208.173.211:8888"
        ]
        
        guard let serverURL = serverURLs[groupId] else {
            return nil
        }
        
        return "\(serverURL)/\(cameraId)/index.m3u8"
    }
    
    static func == (lhs: Camera, rhs: Camera) -> Bool {
        return lhs.id == rhs.id
    }
}

// MARK: - Camera Response (from WebSocket)

struct CameraListResponse: Codable {
    let cameras: [Camera]
    let message: String?
    
    enum CodingKeys: String, CodingKey {
        case cameras
        case message
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cameras = try container.decode([Camera].self, forKey: .cameras)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
}