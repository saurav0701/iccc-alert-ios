import Foundation
import Combine

class CameraManager: ObservableObject {
    static let shared = CameraManager()
    
    @Published var cameras: [Camera] = []
    @Published var selectedArea: String? = nil
    @Published var isLoading = false
    @Published var lastUpdateTime: Date?
    
    private let userDefaults = UserDefaults.standard
    private let camerasKey = "cached_cameras"
    private let cameraListKey = "camera_list_cache"
    private let lastUpdateKey = "cameras_last_update"
    private let saveQueue = DispatchQueue(label: "com.iccc.camerasSaveQueue", qos: .background)
    
    var groupedCameras: [String: [Camera]] {
        Dictionary(grouping: cameras, by: { $0.area })
    }
    
    var availableAreas: [String] {
        Array(Set(cameras.map { $0.area })).sorted()
    }
    
    var onlineCamerasCount: Int {
        cameras.filter { $0.isOnline }.count
    }
    
    private init() {
        loadCachedCameras()
        DebugLogger.shared.log("📹 CameraManager initialized", emoji: "📹", color: .blue)
    }
    
    // MARK: - Update Cameras (Smart Update - Only Status Changes)
    
    func updateCameras(_ newCameras: [Camera]) {
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📹", color: .blue)
        DebugLogger.shared.log("📹 CameraManager.updateCameras() called", emoji: "📹", color: .blue)
        DebugLogger.shared.log("   Received: \(newCameras.count) cameras", emoji: "📊", color: .blue)
        
        DispatchQueue.main.async {
            let oldCount = self.cameras.count
            
            // If first load or camera list structure changed, full update
            if self.cameras.isEmpty || self.hasStructuralChanges(newCameras) {
                DebugLogger.shared.log("   Full camera list update", emoji: "🔄", color: .orange)
                self.cameras = newCameras
                self.saveCameraList() // Save complete list
            } else {
                // Only update status for existing cameras (faster)
                DebugLogger.shared.log("   Status-only update", emoji: "⚡", color: .green)
                self.updateCameraStatuses(newCameras)
            }
            
            self.lastUpdateTime = Date()
            
            DebugLogger.shared.log("   Updated: \(oldCount) → \(newCameras.count)", emoji: "🔄", color: .blue)
            DebugLogger.shared.log("   Online: \(self.onlineCamerasCount)", emoji: "🟢", color: .green)
            DebugLogger.shared.log("   Areas: \(self.availableAreas.count)", emoji: "📍", color: .blue)
            
            // Log per-area breakdown
            for area in self.availableAreas.prefix(3) {
                let areaCameras = self.getCameras(forArea: area)
                let areaOnline = areaCameras.filter { $0.isOnline }.count
                DebugLogger.shared.log("      \(area): \(areaCameras.count) total, \(areaOnline) online", emoji: "📍", color: .gray)
            }
            
            DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📹", color: .blue)
            
            // Force UI refresh
            NotificationCenter.default.post(name: NSNotification.Name("CamerasUpdated"), object: nil)
        }
        
        saveCameraStatuses()
    }
    
    // MARK: - Smart Update Helpers
    
    private func hasStructuralChanges(_ newCameras: [Camera]) -> Bool {
        // Check if camera IDs have changed
        let oldIds = Set(cameras.map { $0.id })
        let newIds = Set(newCameras.map { $0.id })
        return oldIds != newIds
    }
    
    private func updateCameraStatuses(_ newCameras: [Camera]) {
        // Create lookup dictionary for fast status updates
        let statusMap = Dictionary(uniqueKeysWithValues: newCameras.map { ($0.id, $0.status) })
        
        // Update only status field
        for i in 0..<cameras.count {
            if let newStatus = statusMap[cameras[i].id] {
                var updatedCamera = cameras[i]
                if updatedCamera.status != newStatus {
                    // Create new camera with updated status
                    cameras[i] = Camera(
                        category: updatedCamera.category,
                        id: updatedCamera.id,
                        ip: updatedCamera.ip,
                        Id: updatedCamera.Id,
                        deviceId: updatedCamera.deviceId,
                        Name: updatedCamera.Name,
                        name: updatedCamera.name,
                        latitude: updatedCamera.latitude,
                        longitude: updatedCamera.longitude,
                        status: newStatus,
                        groupId: updatedCamera.groupId,
                        area: updatedCamera.area,
                        transporter: updatedCamera.transporter,
                        location: updatedCamera.location,
                        lastUpdate: updatedCamera.lastUpdate
                    )
                }
            }
        }
    }
    
    // MARK: - Get Cameras by Area
    
    func getCameras(forArea area: String) -> [Camera] {
        return cameras.filter { $0.area == area }
    }
    
    func getOnlineCameras(forArea area: String) -> [Camera] {
        return cameras.filter { $0.area == area && $0.isOnline }
    }
    
    // MARK: - Persistence (Separate Cache for List vs Status)
    
    private func saveCameraList() {
        saveQueue.async {
            if let data = try? JSONEncoder().encode(self.cameras) {
                self.userDefaults.set(data, forKey: self.cameraListKey)
                self.userDefaults.set(Date().timeIntervalSince1970, forKey: self.lastUpdateKey)
                DebugLogger.shared.log("💾 Saved camera list (\(self.cameras.count) cameras)", emoji: "💾", color: .blue)
            }
        }
    }
    
    private func saveCameraStatuses() {
        saveQueue.async {
            // Only save status data (lighter)
            let statusData = self.cameras.map { ["id": $0.id, "status": $0.status] }
            if let data = try? JSONEncoder().encode(statusData) {
                self.userDefaults.set(data, forKey: self.camerasKey)
                DebugLogger.shared.log("💾 Saved camera statuses", emoji: "💾", color: .gray)
            }
        }
    }
    
    private func loadCachedCameras() {
        // Load full camera list
        if let data = userDefaults.data(forKey: cameraListKey),
           let cached = try? JSONDecoder().decode([Camera].self, from: data) {
            cameras = cached
            
            if let lastUpdate = userDefaults.object(forKey: lastUpdateKey) as? TimeInterval {
                lastUpdateTime = Date(timeIntervalSince1970: lastUpdate)
            }
            
            DebugLogger.shared.log("📦 Loaded \(cached.count) cameras from cache", emoji: "📦", color: .blue)
            DebugLogger.shared.log("   Online: \(onlineCamerasCount)", emoji: "🟢", color: .green)
            DebugLogger.shared.log("   Areas: \(availableAreas.joined(separator: ", "))", emoji: "📍", color: .gray)
            
            if let lastUpdate = lastUpdateTime {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                DebugLogger.shared.log("   Last update: \(formatter.string(from: lastUpdate))", emoji: "🕐", color: .gray)
            }
        } else {
            DebugLogger.shared.log("⚠️ No cached cameras found", emoji: "⚠️", color: .orange)
        }
    }
    
    func clearCache() {
        cameras.removeAll()
        userDefaults.removeObject(forKey: camerasKey)
        userDefaults.removeObject(forKey: cameraListKey)
        userDefaults.removeObject(forKey: lastUpdateKey)
        lastUpdateTime = nil
        DebugLogger.shared.log("🗑️ Camera cache cleared", emoji: "🗑️", color: .red)
    }
    
    // MARK: - Camera initializer helper
    
    private func createCamera(from existing: Camera, newStatus: String) -> Camera {
        return Camera(
            category: existing.category,
            id: existing.id,
            ip: existing.ip,
            Id: existing.Id,
            deviceId: existing.deviceId,
            Name: existing.Name,
            name: existing.name,
            latitude: existing.latitude,
            longitude: existing.longitude,
            status: newStatus,
            groupId: existing.groupId,
            area: existing.area,
            transporter: existing.transporter,
            location: existing.location,
            lastUpdate: existing.lastUpdate
        )
    }
}

// MARK: - Camera Model Extension (Add Memberwise Init)
extension Camera {
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
}