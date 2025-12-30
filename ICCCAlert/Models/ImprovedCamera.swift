import Foundation

// MARK: - Camera Model with H.264 Stream Support

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
        
        if ip.isEmpty {
            print("⚠️ Camera \(id) has NO IP address!")
        }
    }
    
    // Memberwise initializer
    init(category: String, id: String, ip: String, Id: Int, deviceId: Int,
         Name: String, name: String, latitude: String, longitude: String,
         status: String, groupId: Int, area: String, transporter: String,
         location: String, lastUpdate: String) {
        self.category = category
        self.id = id
        self.ip = ip
        self.Id = Id
        self.deviceId = deviceId
        self.Name = Name
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.status = status
        self.groupId = groupId
        self.area = area
        self.transporter = transporter
        self.location = location
        self.lastUpdate = lastUpdate
    }
    
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
        if !name.isEmpty {
            return name
        }
        return Name.isEmpty ? "Camera \(id)" : Name
    }
    
    // H.264 Stream URL with proper MediaMTX path
    var streamURL: String? {
        return getH264StreamURL(for: groupId, cameraIp: ip, cameraId: id)
    }

    private func getH264StreamURL(for groupId: Int, cameraIp: String, cameraId: String) -> String? {
        // MediaMTX server URLs mapped by group ID
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
            print("❌ No server URL for groupId: \(groupId)")
            return nil
        }
        
        // Use IP address as stream path (MediaMTX format for H.264)
        // Format: http://server:port/camera_ip/index.m3u8
        if !cameraIp.isEmpty {
            let url = "\(serverURL)/\(cameraIp)/index.m3u8"
            print("✅ H.264 Stream URL: \(url)")
            return url
        }
        
        // Fallback to camera ID if IP is missing
        let fallbackUrl = "\(serverURL)/\(cameraId)/index.m3u8"
        print("⚠️ H.264 Stream URL (fallback): \(fallbackUrl)")
        return fallbackUrl
    }
    
    // Compare both ID and status for change detection
    static func == (lhs: Camera, rhs: Camera) -> Bool {
        return lhs.id == rhs.id && lhs.status == rhs.status
    }
}

extension Camera {
    // Efficient status update
    func withUpdatedStatus(_ newStatus: String) -> Camera {
        return Camera(
            category: self.category,
            id: self.id,
            ip: self.ip,
            Id: self.Id,
            deviceId: self.deviceId,
            Name: self.Name,
            name: self.name,
            latitude: self.latitude,
            longitude: self.longitude,
            status: newStatus,
            groupId: self.groupId,
            area: self.area,
            transporter: self.transporter,
            location: self.location,
            lastUpdate: self.lastUpdate
        )
    }

    // Flexible update method
    func updated(
        category: String? = nil,
        ip: String? = nil,
        Id: Int? = nil,
        deviceId: Int? = nil,
        Name: String? = nil,
        name: String? = nil,
        latitude: String? = nil,
        longitude: String? = nil,
        status: String? = nil,
        groupId: Int? = nil,
        area: String? = nil,
        transporter: String? = nil,
        location: String? = nil,
        lastUpdate: String? = nil
    ) -> Camera {
        return Camera(
            category: category ?? self.category,
            id: self.id,
            ip: ip ?? self.ip,
            Id: Id ?? self.Id,
            deviceId: deviceId ?? self.deviceId,
            Name: Name ?? self.Name,
            name: name ?? self.name,
            latitude: latitude ?? self.latitude,
            longitude: longitude ?? self.longitude,
            status: status ?? self.status,
            groupId: groupId ?? self.groupId,
            area: area ?? self.area,
            transporter: transporter ?? self.transporter,
            location: location ?? self.location,
            lastUpdate: lastUpdate ?? self.lastUpdate
        )
    }
    
    // Debug print stream info
    func printStreamInfo() {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📹 Camera: \(displayName)")
        print("   ID: \(id)")
        print("   IP: \(ip.isEmpty ? "MISSING!" : ip)")
        print("   Group: \(groupId)")
        print("   Stream URL: \(streamURL ?? "nil")")
        print("   Online: \(isOnline)")
        print("   Expected Format: H.264")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }
    
    // Validate stream availability
    func validateStream() -> StreamValidation {
        guard !ip.isEmpty else {
            return .invalid(reason: "No IP address")
        }
        
        guard streamURL != nil else {
            return .invalid(reason: "No server for group \(groupId)")
        }
        
        guard isOnline else {
            return .offline
        }
        
        return .valid
    }
    
    enum StreamValidation {
        case valid
        case offline
        case invalid(reason: String)
        
        var isValid: Bool {
            if case .valid = self {
                return true
            }
            return false
        }
        
        var errorMessage: String? {
            switch self {
            case .valid:
                return nil
            case .offline:
                return "Camera is offline"
            case .invalid(let reason):
                return reason
            }
        }
    }
}

// MARK: - Camera Response

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