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
    }
    
    // MARK: - Update Cameras (from WebSocket)
    
    func updateCameras(_ newCameras: [Camera]) {
        DispatchQueue.main.async {
            self.cameras = newCameras
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("📹 CameraManager: Updated cameras")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("   Total: \(newCameras.count)")
            print("   Online: \(self.onlineCamerasCount)")
            print("   Areas: \(self.availableAreas.count)")
            if !self.availableAreas.isEmpty {
                print("   Area list: \(self.availableAreas.joined(separator: ", "))")
            }
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
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
                print("💾 CameraManager: Saved \(self.cameras.count) cameras to cache")
            }
        }
    }
    
    private func loadCachedCameras() {
        if let data = userDefaults.data(forKey: camerasKey),
           let cached = try? JSONDecoder().decode([Camera].self, from: data) {
            cameras = cached
            print("📦 CameraManager: Loaded \(cached.count) cameras from cache")
            print("   Online: \(onlineCamerasCount)")
            print("   Areas: \(availableAreas.joined(separator: ", "))")
        }
    }
    
    func clearCache() {
        cameras.removeAll()
        userDefaults.removeObject(forKey: camerasKey)
        print("🗑️ CameraManager: Cache cleared")
    }
}