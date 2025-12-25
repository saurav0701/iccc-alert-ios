import Foundation
import Combine

class CameraManager: ObservableObject {
    static let shared = CameraManager()
    
    @Published var cameras: [Camera] = []
    @Published var selectedArea: String? = nil
    @Published var isLoading = false
    
    private let userDefaults = UserDefaults.standard
    private let camerasKey = "cached_cameras"
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
    
    // MARK: - Update Cameras (from WebSocket)
    
    func updateCameras(_ newCameras: [Camera]) {
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📹", color: .blue)
        DebugLogger.shared.log("📹 CameraManager.updateCameras() called", emoji: "📹", color: .blue)
        DebugLogger.shared.log("   Received: \(newCameras.count) cameras", emoji: "📊", color: .blue)
        
        DispatchQueue.main.async {
            let oldCount = self.cameras.count
            self.cameras = newCameras
            
            DebugLogger.shared.log("   Updated: \(oldCount) → \(newCameras.count)", emoji: "🔄", color: .blue)
            DebugLogger.shared.log("   Online: \(self.onlineCamerasCount)", emoji: "🟢", color: .green)
            DebugLogger.shared.log("   Areas: \(self.availableAreas.count)", emoji: "📍", color: .blue)
            
            if !self.availableAreas.isEmpty {
                DebugLogger.shared.log("   Area list: \(self.availableAreas.joined(separator: ", "))", emoji: "📍", color: .gray)
            }
            
            // Log per-area breakdown
            for area in self.availableAreas {
                let areaCameras = self.getCameras(forArea: area)
                let areaOnline = areaCameras.filter { $0.isOnline }.count
                DebugLogger.shared.log("      \(area): \(areaCameras.count) total, \(areaOnline) online", emoji: "📍", color: .gray)
            }
            
            DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📹", color: .blue)
            
            // Force UI refresh by posting notification
            NotificationCenter.default.post(name: NSNotification.Name("CamerasUpdated"), object: nil)
        }
        
        saveCameras()
    }
    
    // MARK: - Get Cameras by Area
    
    func getCameras(forArea area: String) -> [Camera] {
        return cameras.filter { $0.area == area }
    }
    
    func getOnlineCameras(forArea area: String) -> [Camera] {
        return cameras.filter { $0.area == area && $0.isOnline }
    }
    
    // MARK: - Persistence
    
    private func saveCameras() {
        saveQueue.async {
            if let data = try? JSONEncoder().encode(self.cameras) {
                self.userDefaults.set(data, forKey: self.camerasKey)
                DebugLogger.shared.log("💾 Saved \(self.cameras.count) cameras to cache", emoji: "💾", color: .blue)
            }
        }
    }
    
    private func loadCachedCameras() {
        if let data = userDefaults.data(forKey: camerasKey),
           let cached = try? JSONDecoder().decode([Camera].self, from: data) {
            cameras = cached
            DebugLogger.shared.log("📦 Loaded \(cached.count) cameras from cache", emoji: "📦", color: .blue)
            DebugLogger.shared.log("   Online: \(onlineCamerasCount)", emoji: "🟢", color: .green)
            DebugLogger.shared.log("   Areas: \(availableAreas.joined(separator: ", "))", emoji: "📍", color: .gray)
        } else {
            DebugLogger.shared.log("⚠️ No cached cameras found", emoji: "⚠️", color: .orange)
        }
    }
    
    func clearCache() {
        cameras.removeAll()
        userDefaults.removeObject(forKey: camerasKey)
        DebugLogger.shared.log("🗑️ Camera cache cleared", emoji: "🗑️", color: .red)
    }
}