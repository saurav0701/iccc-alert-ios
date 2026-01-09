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
    private let lastUpdateKey = "cameras_last_update"
    private let hasInitialDataKey = "has_initial_camera_data"
    private let saveQueue = DispatchQueue(label: "com.iccc.camerasSaveQueue", qos: .background)
    
    private var isFetching = false
    private var cancellables = Set<AnyCancellable>()
    
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
        print("📹 CameraManager initialized")
        print("   Has initial data: \(hasInitialData)")
        print("   Cameras loaded: \(cameras.count)")
        
        // Always fetch fresh data on startup
        fetchAllCameras()
    }
    
    // MARK: - ✅ SIMPLIFIED: Single API Call (No Pagination)
    
    func fetchAllCameras(silent: Bool = false) {
        guard !isFetching else {
            print("⏳ Fetch already in progress")
            return
        }
        
        isFetching = true
        
        if !silent {
            DispatchQueue.main.async {
                self.isLoading = true
            }
        }
        
        print("📡 Fetching ALL cameras from backend cache...")
        
        CameraAPIService.shared.fetchAllCameras { [weak self] result in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.isFetching = false
                
                if !silent {
                    self.isLoading = false
                }
                
                switch result {
                case .success(let cameras):
                    print("✅ Fetched \(cameras.count) cameras from backend")
                    
                    if !self.hasInitialData || self.cameras.isEmpty {
                        self.performInitialLoad(cameras)
                    } else {
                        self.performStatusUpdate(cameras)
                    }
                    
                case .failure(let error):
                    print("❌ Fetch failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - ✅ SIMPLIFIED: Manual Refresh
    
    func manualRefresh(completion: @escaping (Bool) -> Void) {
        guard !isFetching else {
            completion(false)
            return
        }
        
        print("🔄 Manual refresh triggered")
        
        isFetching = true
        
        DispatchQueue.main.async {
            self.isLoading = true
        }
        
        CameraAPIService.shared.fetchAllCameras { [weak self] result in
            guard let self = self else {
                completion(false)
                return
            }
            
            DispatchQueue.main.async {
                self.isFetching = false
                self.isLoading = false
                
                switch result {
                case .success(let cameras):
                    print("✅ Manual refresh: \(cameras.count) cameras")
                    
                    if !self.hasInitialData || self.cameras.isEmpty {
                        self.performInitialLoad(cameras)
                    } else {
                        self.performStatusUpdate(cameras)
                    }
                    
                    completion(true)
                    
                case .failure(let error):
                    print("❌ Manual refresh failed: \(error.localizedDescription)")
                    completion(false)
                }
            }
        }
    }
    
    // MARK: - Update Cameras (Smart Update Strategy)
    
    func updateCameras(_ newCameras: [Camera]) {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📹 CameraManager.updateCameras() called")
        print("   Received: \(newCameras.count) cameras")
        
        DispatchQueue.main.async {
            if !self.hasInitialData || self.cameras.isEmpty {
                self.performInitialLoad(newCameras)
            } else {
                self.performStatusUpdate(newCameras)
            }
            
            self.lastUpdateTime = Date()
            
            print("   Current total: \(self.cameras.count)")
            print("   Online: \(self.onlineCamerasCount)")
            print("   Areas: \(self.availableAreas.count)")
            
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            
            NotificationCenter.default.post(name: NSNotification.Name("CamerasUpdated"), object: nil)
        }
    }
    
    // MARK: - Initial Load
    
    private func performInitialLoad(_ newCameras: [Camera]) {
        print("📹 INITIAL LOAD: Storing \(newCameras.count) cameras permanently")
        
        self.cameras = newCameras
        self.hasInitialData = true
        self.lastUpdateTime = Date()
        
        saveCameraList()
        
        print("✅ Initial load complete")
        print("   Cameras: \(self.cameras.count)")
        print("   Areas: \(self.availableAreas.joined(separator: ", "))")
        
        NotificationCenter.default.post(name: NSNotification.Name("CamerasUpdated"), object: nil)
    }
    
    // MARK: - Status Update
    
    private func performStatusUpdate(_ newCameras: [Camera]) {
        var updatedCount = 0
        var newCamerasCount = 0
        
        let statusMap = Dictionary(uniqueKeysWithValues: newCameras.map { ($0.id, $0) })
        
        // Update existing cameras
        for i in 0..<cameras.count {
            if let newCamera = statusMap[cameras[i].id] {
                if cameras[i].status != newCamera.status {
                    cameras[i] = cameras[i].withUpdatedStatus(newCamera.status)
                    updatedCount += 1
                }
            }
        }
        
        // Add new cameras
        let existingIds = Set(cameras.map { $0.id })
        let newCamerasToAdd = newCameras.filter { !existingIds.contains($0.id) }
        
        if !newCamerasToAdd.isEmpty {
            cameras.append(contentsOf: newCamerasToAdd)
            newCamerasCount = newCamerasToAdd.count
            print("➕ Added \(newCamerasCount) new cameras")
            saveCameraList()
        }
        
        if updatedCount > 0 {
            print("📹 Status update: \(updatedCount) cameras changed")
        }
        
        lastUpdateTime = Date()
        NotificationCenter.default.post(name: NSNotification.Name("CamerasUpdated"), object: nil)
    }
    
    // MARK: - Get Cameras
    
    func getCameras(forArea area: String) -> [Camera] {
        return cameras.filter { $0.area == area }
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
    
    // MARK: - Persistence
    
    private func saveCameraList() {
        saveQueue.async {
            if let data = try? JSONEncoder().encode(self.cameras) {
                self.userDefaults.set(data, forKey: self.cameraListKey)
                self.userDefaults.set(Date().timeIntervalSince1970, forKey: self.lastUpdateKey)
                print("💾 Saved \(self.cameras.count) cameras")
            }
        }
    }
    
    private func loadCachedCameras() {
        if let data = userDefaults.data(forKey: cameraListKey),
           let cached = try? JSONDecoder().decode([Camera].self, from: data) {
            cameras = cached
            
            if let lastUpdate = userDefaults.object(forKey: lastUpdateKey) as? TimeInterval {
                lastUpdateTime = Date(timeIntervalSince1970: lastUpdate)
            }
            
            print("📦 Loaded \(cached.count) cameras from cache")
            print("   Online: \(onlineCamerasCount)")
        }
    }
    
    func hasData() -> Bool {
        return hasInitialData && !cameras.isEmpty
    }
    
    func clearCache() {
        cameras.removeAll()
        hasInitialData = false
        userDefaults.removeObject(forKey: cameraListKey)
        userDefaults.removeObject(forKey: lastUpdateKey)
        userDefaults.removeObject(forKey: hasInitialDataKey)
        lastUpdateTime = nil
        print("🗑️ Cache cleared")
    }
    
    func forceRefresh() {
        print("🔄 Force refreshing camera list")
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