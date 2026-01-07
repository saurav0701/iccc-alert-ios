import Foundation
import Combine

class CameraManager: ObservableObject {
    static let shared = CameraManager()
    
    @Published var cameras: [Camera] = []
    @Published var selectedArea: String? = nil
    @Published var isLoading = false
    @Published var lastUpdateTime: Date?
    @Published var loadingProgress: Double = 0.0
    
    private let userDefaults = UserDefaults.standard
    private let cameraListKey = "camera_list_permanent"
    private let lastUpdateKey = "cameras_last_update"
    private let hasInitialDataKey = "has_initial_camera_data"
    private let saveQueue = DispatchQueue(label: "com.iccc.camerasSaveQueue", qos: .background)
    
    // Pagination settings
    private let pageSize = 100
    private var isFetching = false
    
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
        
        if !hasInitialData || cameras.isEmpty {
            fetchAllCamerasPaginated()
        }
    }
    
    // MARK: - Paginated Camera Fetch
    
    func fetchAllCamerasPaginated() {
        guard !isFetching else {
            print("⏳ Fetch already in progress")
            return
        }
        
        isFetching = true
        isLoading = true
        loadingProgress = 0.0
        
        var allCameras: [Camera] = []
        var currentPage = 1
        var hasMore = true
        
        print("📡 Starting paginated camera fetch...")
        
        func fetchNextPage() {
            CameraAPIService.shared.fetchCameras(page: currentPage, pageSize: pageSize) { [weak self] result in
                guard let self = self else { return }
                
                DispatchQueue.main.async {
                    switch result {
                    case .success(let response):
                        allCameras.append(contentsOf: response.cameras)
                        
                        self.loadingProgress = Double(allCameras.count) / Double(response.total)
                        
                        print("📦 Fetched page \(currentPage): \(response.cameras.count) cameras (total: \(allCameras.count)/\(response.total))")
                        
                        hasMore = response.hasMore
                        currentPage += 1
                        
                        if hasMore {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                fetchNextPage()
                            }
                        } else {
                            self.handleFetchComplete(allCameras)
                        }
                        
                    case .failure(let error):
                        print("❌ Fetch failed on page \(currentPage): \(error.localizedDescription)")
                        
                        if !allCameras.isEmpty {
                            self.handleFetchComplete(allCameras)
                        } else {
                            self.isFetching = false
                            self.isLoading = false
                            self.loadingProgress = 0.0
                        }
                    }
                }
            }
        }
        
        fetchNextPage()
    }
    
    private func handleFetchComplete(_ cameras: [Camera]) {
        print("✅ Fetch complete: \(cameras.count) cameras")
        
        if !hasInitialData || self.cameras.isEmpty {
            performInitialLoad(cameras)
        } else {
            performStatusUpdate(cameras)
        }
        
        isFetching = false
        isLoading = false
        loadingProgress = 1.0
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.loadingProgress = 0.0
        }
    }
    
    // MARK: - Manual Refresh (Status Only)
    
    func manualRefresh(completion: @escaping (Bool) -> Void) {
        guard !isFetching else {
            completion(false)
            return
        }
        
        print("🔄 Manual refresh triggered")
        
        isFetching = true
        
        CameraAPIService.shared.fetchCameras(page: 1, pageSize: 200) { [weak self] result in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.isFetching = false
                
                switch result {
                case .success(let response):
                    print("✅ Manual refresh: \(response.cameras.count) cameras")
                    self.performStatusUpdate(response.cameras)
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
        
        for i in 0..<cameras.count {
            if let newCamera = statusMap[cameras[i].id] {
                if cameras[i].status != newCamera.status {
                    cameras[i] = cameras[i].withUpdatedStatus(newCamera.status)
                    updatedCount += 1
                }
            }
        }
        
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