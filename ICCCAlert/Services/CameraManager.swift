import Foundation
import Combine

class CameraManager: ObservableObject {
    static let shared = CameraManager()
    
    @Published var cameras: [Camera] = []
    @Published var selectedArea: String? = nil
    @Published var isLoading = false
    @Published var lastUpdateTime: Date?
    
    private let userDefaults = UserDefaults.standard
    private let cameraListKey = "camera_list_permanent"
    private let cameraStatusKey = "camera_status_cache"
    private let lastUpdateKey = "cameras_last_update"
    private let hasInitialDataKey = "has_initial_camera_data"
    private let saveQueue = DispatchQueue(label: "com.iccc.camerasSaveQueue", qos: .background)
    
    private var hasInitialData: Bool {
        get { userDefaults.bool(forKey: hasInitialDataKey) }
        set { userDefaults.set(newValue, forKey: hasInitialDataKey) }
    }
    
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
        DebugLogger.shared.log("   Has initial data: \(hasInitialData)", emoji: "📊", color: .gray)
        DebugLogger.shared.log("   Cameras loaded: \(cameras.count)", emoji: "📊", color: .gray)
    }
    
    // MARK: - Update Cameras (Smart Update Strategy)
    
    func updateCameras(_ newCameras: [Camera]) {
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📹", color: .blue)
        DebugLogger.shared.log("📹 CameraManager.updateCameras() called", emoji: "📹", color: .blue)
        DebugLogger.shared.log("   Received: \(newCameras.count) cameras", emoji: "📊", color: .blue)
        
        DispatchQueue.main.async {
            if !self.hasInitialData || self.cameras.isEmpty {
                // FIRST TIME: Store complete camera list permanently
                self.performInitialLoad(newCameras)
            } else {
                // SUBSEQUENT: Only update status + add any new cameras
                self.performStatusUpdate(newCameras)
            }
            
            self.lastUpdateTime = Date()
            
            DebugLogger.shared.log("   Current total: \(self.cameras.count)", emoji: "🔄", color: .blue)
            DebugLogger.shared.log("   Online: \(self.onlineCamerasCount)", emoji: "🟢", color: .green)
            DebugLogger.shared.log("   Areas: \(self.availableAreas.count)", emoji: "📍", color: .blue)
            
            // Log per-area breakdown (first 3 areas)
            for area in self.availableAreas.prefix(3) {
                let areaCameras = self.getCameras(forArea: area)
                let areaOnline = areaCameras.filter { $0.isOnline }.count
                DebugLogger.shared.log("      \(area): \(areaCameras.count) total, \(areaOnline) online", emoji: "📍", color: .gray)
            }
            
            DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📹", color: .blue)
            
            // Force UI refresh
            NotificationCenter.default.post(name: NSNotification.Name("CamerasUpdated"), object: nil)
        }
    }
    
    // MARK: - Initial Load (Complete Camera List)
    
    private func performInitialLoad(_ newCameras: [Camera]) {
        DebugLogger.shared.log("📹 INITIAL LOAD: Storing \(newCameras.count) cameras permanently", emoji: "📹", color: .green)
        
        // Store complete camera list
        self.cameras = newCameras
        self.hasInitialData = true
        
        // Save permanently
        saveCameraList()
        
        DebugLogger.shared.log("✅ Initial load complete", emoji: "✅", color: .green)
        DebugLogger.shared.log("   Cameras: \(self.cameras.count)", emoji: "📊", color: .gray)
        DebugLogger.shared.log("   Areas: \(self.availableAreas.joined(separator: ", "))", emoji: "📍", color: .gray)
    }
    
    // MARK: - Status Update (Only Update Online/Offline Status)
    
    private func performStatusUpdate(_ newCameras: [Camera]) {
        var updatedCount = 0
        var newCamerasCount = 0
        
        // Create lookup dictionary for fast status updates
        let statusMap = Dictionary(uniqueKeysWithValues: newCameras.map { ($0.id, $0) })
        
        // Update existing cameras' status
        for i in 0..<cameras.count {
            if let newCamera = statusMap[cameras[i].id] {
                if cameras[i].status != newCamera.status {
                    cameras[i] = cameras[i].withUpdatedStatus(newCamera.status)
                    updatedCount += 1
                }
            }
        }
        
        // Add any NEW cameras not in our list (camera additions are rare but possible)
        let existingIds = Set(cameras.map { $0.id })
        let newCamerasToAdd = newCameras.filter { !existingIds.contains($0.id) }
        
        if !newCamerasToAdd.isEmpty {
            cameras.append(contentsOf: newCamerasToAdd)
            newCamerasCount = newCamerasToAdd.count
            
            DebugLogger.shared.log("➕ Added \(newCamerasCount) new cameras", emoji: "➕", color: .green)
            
            // Save complete list when cameras are added
            saveCameraList()
        }
        
        if updatedCount > 0 {
            DebugLogger.shared.log("📹 Status update: \(updatedCount) cameras changed status", emoji: "📹", color: .blue)
            
            // Save status changes (lighter operation)
            saveCameraStatuses()
        }
    }
    
    // MARK: - Get Cameras by Area
    
    func getCameras(forArea area: String) -> [Camera] {
        let filtered = cameras.filter { $0.area == area }
        
        if filtered.isEmpty && hasInitialData {
            DebugLogger.shared.log("⚠️ No cameras found for area: \(area)", emoji: "⚠️", color: .orange)
            DebugLogger.shared.log("   Available areas: \(availableAreas.joined(separator: ", "))", emoji: "📍", color: .gray)
        }
        
        return filtered
    }
    
    func getOnlineCameras(forArea area: String) -> [Camera] {
        return cameras.filter { $0.area == area && $0.isOnline }
    }
    
    func getCameraById(_ cameraId: String) -> Camera? {
        return cameras.first { $0.id == cameraId }
    }
    
    func getAllCameras() -> [Camera] {
        return cameras
    }
    
    func getOnlineCameras() -> [Camera] {
        return cameras.filter { $0.isOnline }
    }
    
    // MARK: - Statistics
    
    func getStatistics() -> CameraStatistics {
        let total = cameras.count
        let online = onlineCamerasCount
        let offline = total - online
        
        var areaStats: [String: AreaStatistics] = [:]
        for area in availableAreas {
            let areaCameras = getCameras(forArea: area)
            areaStats[area] = AreaStatistics(
                total: areaCameras.count,
                online: areaCameras.filter { $0.isOnline }.count,
                offline: areaCameras.filter { !$0.isOnline }.count
            )
        }
        
        return CameraStatistics(
            totalCameras: total,
            onlineCameras: online,
            offlineCameras: offline,
            areaStatistics: areaStats
        )
    }
    
    func getAreaStatistics(forArea area: String) -> AreaStatistics {
        let areaCameras = getCameras(forArea: area)
        return AreaStatistics(
            total: areaCameras.count,
            online: areaCameras.filter { $0.isOnline }.count,
            offline: areaCameras.filter { !$0.isOnline }.count
        )
    }
    
    // MARK: - Persistence (Separate Storage for List vs Status)
    
    private func saveCameraList() {
        saveQueue.async {
            if let data = try? JSONEncoder().encode(self.cameras) {
                self.userDefaults.set(data, forKey: self.cameraListKey)
                self.userDefaults.set(Date().timeIntervalSince1970, forKey: self.lastUpdateKey)
                DebugLogger.shared.log("💾 Saved complete camera list (\(self.cameras.count) cameras)", emoji: "💾", color: .blue)
            }
        }
    }
    
    private func saveCameraStatuses() {
        saveQueue.async {
            // Only save status data (lighter operation)
            let statusData = self.cameras.map { ["id": $0.id, "status": $0.status] }
            if let data = try? JSONEncoder().encode(statusData) {
                self.userDefaults.set(data, forKey: self.cameraStatusKey)
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
    
    func hasData() -> Bool {
        return hasInitialData && !cameras.isEmpty
    }
    
    func clearCache() {
        cameras.removeAll()
        hasInitialData = false
        userDefaults.removeObject(forKey: cameraListKey)
        userDefaults.removeObject(forKey: cameraStatusKey)
        userDefaults.removeObject(forKey: lastUpdateKey)
        userDefaults.removeObject(forKey: hasInitialDataKey)
        lastUpdateTime = nil
        DebugLogger.shared.log("🗑️ Camera cache cleared", emoji: "🗑️", color: .red)
    }
    
    func forceRefresh() {
        DebugLogger.shared.log("🔄 Force refreshing camera list", emoji: "🔄", color: .orange)
        NotificationCenter.default.post(name: NSNotification.Name("CamerasUpdated"), object: nil)
    }
}

// MARK: - Statistics Models

struct CameraStatistics {
    let totalCameras: Int
    let onlineCameras: Int
    let offlineCameras: Int
    let areaStatistics: [String: AreaStatistics]
}

struct AreaStatistics {
    let total: Int
    let online: Int
    let offline: Int
}