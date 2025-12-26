import Foundation
import Combine

class CameraManager: ObservableObject {
    static let shared = CameraManager()
    
    @Published var cameras: [Camera] = []
    @Published var selectedArea: String? = nil
    @Published var isLoading = false
    @Published var lastUpdateTime: Date?
    
    private let userDefaults = UserDefaults.standard
    private let cameraListKey = "complete_camera_list"
    private let lastUpdateKey = "cameras_last_full_update"
    private let lastPartialUpdateKey = "cameras_last_partial_update"
    private let saveQueue = DispatchQueue(label: "com.iccc.camerasSaveQueue", qos: .background)
    
    // Camera ID to Camera mapping for fast lookups
    private var cameraDict: [String: Camera] = [:]
    private let dictLock = NSLock()
    
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
        DebugLogger.shared.log("📹 CameraManager initialized with \(cameras.count) cameras", emoji: "📹", color: .blue)
    }
    
    // MARK: - Update Cameras (FIXED: Only updates on structural changes or first load)
    
    func updateCameras(_ newCameras: [Camera]) {
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📹", color: .blue)
        DebugLogger.shared.log("📹 CameraManager.updateCameras() called", emoji: "📹", color: .blue)
        DebugLogger.shared.log("   Received: \(newCameras.count) cameras", emoji: "📊", color: .blue)
        
        let now = Date()
        
        // Build new camera dictionary for fast lookup
        let newCameraDict = Dictionary(uniqueKeysWithValues: newCameras.map { ($0.id, $0) })
        
        DispatchQueue.main.async {
            let isFirstLoad = self.cameras.isEmpty
            let hasStructuralChanges = self.detectStructuralChanges(newCameraDict: newCameraDict)
            
            if isFirstLoad {
                // First load - accept all cameras
                DebugLogger.shared.log("   ✨ First load - storing \(newCameras.count) cameras", emoji: "✨", color: .green)
                self.cameras = newCameras
                self.rebuildDictionary()
                self.lastUpdateTime = now
                self.saveCompleteCameraList()
                
            } else if hasStructuralChanges {
                // Structural changes detected - merge new cameras with existing
                DebugLogger.shared.log("   🔄 Structural changes detected - merging cameras", emoji: "🔄", color: .orange)
                self.mergeCameras(newCameraDict: newCameraDict)
                self.lastUpdateTime = now
                self.saveCompleteCameraList()
                
            } else {
                // No structural changes - just update statuses of cameras we received
                DebugLogger.shared.log("   ⚡ Status-only update for \(newCameras.count) cameras", emoji: "⚡", color: .blue)
                self.updateCameraStatuses(newCameraDict: newCameraDict)
                self.saveStatusesOnly()
                
                // Update last partial update time
                self.userDefaults.set(now.timeIntervalSince1970, forKey: self.lastPartialUpdateKey)
            }
            
            let onlineCount = self.onlineCamerasCount
            let areas = self.availableAreas
            
            DebugLogger.shared.log("   Total cameras: \(self.cameras.count)", emoji: "📊", color: .blue)
            DebugLogger.shared.log("   Online: \(onlineCount)", emoji: "🟢", color: .green)
            DebugLogger.shared.log("   Areas: \(areas.count)", emoji: "📍", color: .blue)
            DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📹", color: .blue)
            
            // Notify UI
            NotificationCenter.default.post(name: NSNotification.Name("CamerasUpdated"), object: nil)
        }
    }
    
    // MARK: - Smart Update Logic
    
    private func detectStructuralChanges(newCameraDict: [String: Camera]) -> Bool {
        dictLock.lock()
        defer { dictLock.unlock() }
        
        // Check if we received new camera IDs that we don't have
        for cameraId in newCameraDict.keys {
            if cameraDict[cameraId] == nil {
                DebugLogger.shared.log("   Found new camera: \(cameraId)", emoji: "🆕", color: .green)
                return true
            }
        }
        
        // No new cameras found
        return false
    }
    
    private func mergeCameras(newCameraDict: [String: Camera]) {
        dictLock.lock()
        
        // Add new cameras
        for (cameraId, newCamera) in newCameraDict {
            if cameraDict[cameraId] == nil {
                // New camera - add it
                cameraDict[cameraId] = newCamera
                DebugLogger.shared.log("   ✅ Added new camera: \(newCamera.displayName)", emoji: "✅", color: .green)
            } else {
                // Existing camera - update all fields
                cameraDict[cameraId] = newCamera
            }
        }
        
        // Rebuild cameras array from dictionary
        cameras = Array(cameraDict.values).sorted { $0.id < $1.id }
        
        dictLock.unlock()
    }
    
    private func updateCameraStatuses(newCameraDict: [String: Camera]) {
        dictLock.lock()
        
        var updatedCount = 0
        
        // Only update statuses for cameras we received
        for (cameraId, newCamera) in newCameraDict {
            if let existingCamera = cameraDict[cameraId] {
                if existingCamera.status != newCamera.status {
                    // Status changed - update it
                    cameraDict[cameraId] = existingCamera.withUpdatedStatus(newCamera.status)
                    updatedCount += 1
                }
            }
        }
        
        // Rebuild cameras array if anything changed
        if updatedCount > 0 {
            cameras = Array(cameraDict.values).sorted { $0.id < $1.id }
            DebugLogger.shared.log("   Updated \(updatedCount) camera statuses", emoji: "📝", color: .blue)
        }
        
        dictLock.unlock()
    }
    
    private func rebuildDictionary() {
        dictLock.lock()
        cameraDict = Dictionary(uniqueKeysWithValues: cameras.map { ($0.id, $0) })
        dictLock.unlock()
    }
    
    // MARK: - Get Cameras by Area
    
    func getCameras(forArea area: String) -> [Camera] {
        return cameras.filter { $0.area == area }
    }
    
    func getOnlineCameras(forArea area: String) -> [Camera] {
        return cameras.filter { $0.area == area && $0.isOnline }
    }
    
    func getCamera(byId cameraId: String) -> Camera? {
        dictLock.lock()
        defer { dictLock.unlock() }
        return cameraDict[cameraId]
    }
    
    // MARK: - Persistence (Complete List + Status Cache)
    
    private func saveCompleteCameraList() {
        saveQueue.async {
            if let data = try? JSONEncoder().encode(self.cameras) {
                self.userDefaults.set(data, forKey: self.cameraListKey)
                self.userDefaults.set(Date().timeIntervalSince1970, forKey: self.lastUpdateKey)
                DebugLogger.shared.log("💾 Saved complete camera list (\(self.cameras.count) cameras)", emoji: "💾", color: .blue)
            }
        }
    }
    
    private func saveStatusesOnly() {
        // Lightweight status-only save (faster)
        saveQueue.async {
            let statusData = self.cameras.map { ["id": $0.id, "status": $0.status, "area": $0.area] }
            if let data = try? JSONEncoder().encode(statusData) {
                self.userDefaults.set(data, forKey: "camera_statuses_cache")
            }
        }
    }
    
    private func loadCachedCameras() {
        // Load complete camera list
        if let data = userDefaults.data(forKey: cameraListKey),
           let cached = try? JSONDecoder().decode([Camera].self, from: data) {
            cameras = cached
            rebuildDictionary()
            
            if let lastUpdate = userDefaults.object(forKey: lastUpdateKey) as? TimeInterval {
                lastUpdateTime = Date(timeIntervalSince1970: lastUpdate)
            }
            
            DebugLogger.shared.log("📦 Loaded \(cached.count) cameras from cache", emoji: "📦", color: .blue)
            DebugLogger.shared.log("   Online: \(onlineCamerasCount)", emoji: "🟢", color: .green)
            DebugLogger.shared.log("   Areas: \(availableAreas.joined(separator: ", "))", emoji: "📍", color: .gray)
            
            if let lastUpdate = lastUpdateTime {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                DebugLogger.shared.log("   Last full update: \(formatter.string(from: lastUpdate))", emoji: "🕐", color: .gray)
            }
            
            if let lastPartial = userDefaults.object(forKey: lastPartialUpdateKey) as? TimeInterval {
                let partialDate = Date(timeIntervalSince1970: lastPartial)
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                DebugLogger.shared.log("   Last partial update: \(formatter.string(from: partialDate))", emoji: "🕐", color: .gray)
            }
        } else {
            DebugLogger.shared.log("⚠️ No cached cameras found", emoji: "⚠️", color: .orange)
        }
    }
    
    func clearCache() {
        cameras.removeAll()
        dictLock.lock()
        cameraDict.removeAll()
        dictLock.unlock()
        
        userDefaults.removeObject(forKey: cameraListKey)
        userDefaults.removeObject(forKey: "camera_statuses_cache")
        userDefaults.removeObject(forKey: lastUpdateKey)
        userDefaults.removeObject(forKey: lastPartialUpdateKey)
        lastUpdateTime = nil
        
        DebugLogger.shared.log("🗑️ Camera cache cleared", emoji: "🗑️", color: .red)
    }
    
    // MARK: - Manual Refresh (for pull-to-refresh)
    
    func requestFullRefresh() {
        DebugLogger.shared.log("🔄 Requesting full camera refresh from server...", emoji: "🔄", color: .blue)
        isLoading = true
        
        // This will be called by WebSocketService when it receives the camera list
        // Just set the flag and let the websocket service know we want a refresh
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            self.isLoading = false
        }
    }
}