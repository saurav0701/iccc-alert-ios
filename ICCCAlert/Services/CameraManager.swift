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
    
    // ✅ NEW: Parallel fetching configuration
    private let parallelFetchCount = 4 // Fetch 4 areas at once
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
        
        if !hasInitialData || cameras.isEmpty {
            fetchAllCamerasParallel()
        }
    }
    
    // MARK: - ✅ NEW: Parallel Camera Fetch by Area
    
    func fetchAllCamerasParallel() {
        guard !isFetching else {
            print("⏳ Fetch already in progress")
            return
        }
        
        isFetching = true
        isLoading = true
        loadingProgress = 0.0
        
        print("📡 Starting PARALLEL camera fetch (4 areas at a time)...")
        
        // Get all unique areas from backend
        fetchAvailableAreas { [weak self] areas in
            guard let self = self else { return }
            
            if areas.isEmpty {
                print("⚠️ No areas found, falling back to paginated fetch")
                self.fetchAllCamerasPaginated()
                return
            }
            
            print("📋 Found \(areas.count) areas to fetch")
            self.fetchAreasInParallel(areas: areas)
        }
    }
    
    private func fetchAvailableAreas(completion: @escaping ([String]) -> Void) {
        // Get areas from cached cameras or fetch from API
        let cachedAreas = Array(Set(cameras.map { $0.area }))
        
        if !cachedAreas.isEmpty {
            completion(cachedAreas)
            return
        }
        
        // If no cached areas, fetch stats endpoint to get area list
        CameraAPIService.shared.fetchCameraStats { result in
            switch result {
            case .success(let stats):
                let areas = Array(stats.keys).sorted()
                completion(areas)
            case .failure:
                // Fallback to known areas
                let knownAreas = [
                    "BARORA", "BLOCK2", "GOVINDPUR", "KATRAS", 
                    "SIJUA", "KUSUNDA", "PB Area", "BASTACOLLA", 
                    "LODNA", "EJ Area", "CV Area", "CCWO Area", "WJ Area"
                ]
                completion(knownAreas)
            }
        }
    }
    
    private func fetchAreasInParallel(areas: [String]) {
        let totalAreas = areas.count
        var allCameras: [Camera] = []
        var completedAreas = 0
        let lock = NSLock()
        
        // Process areas in batches of 4
        let batches = stride(from: 0, to: areas.count, by: parallelFetchCount).map {
            Array(areas[$0..<min($0 + parallelFetchCount, areas.count)])
        }
        
        func fetchNextBatch(batchIndex: Int) {
            guard batchIndex < batches.count else {
                // All batches complete
                self.handleFetchComplete(allCameras)
                return
            }
            
            let batch = batches[batchIndex]
            print("📦 Fetching batch \(batchIndex + 1)/\(batches.count): \(batch.joined(separator: ", "))")
            
            let group = DispatchGroup()
            
            for area in batch {
                group.enter()
                
                CameraAPIService.shared.fetchCamerasByArea(area) { result in
                    defer { group.leave() }
                    
                    switch result {
                    case .success(let cameras):
                        lock.lock()
                        allCameras.append(contentsOf: cameras)
                        completedAreas += 1
                        
                        DispatchQueue.main.async {
                            self.loadingProgress = Double(completedAreas) / Double(totalAreas)
                        }
                        lock.unlock()
                        
                        print("✅ Fetched \(area): \(cameras.count) cameras")
                        
                    case .failure(let error):
                        lock.lock()
                        completedAreas += 1
                        lock.unlock()
                        
                        print("❌ Failed to fetch \(area): \(error.localizedDescription)")
                    }
                }
            }
            
            group.notify(queue: .main) {
                print("📋 Batch \(batchIndex + 1) complete (\(completedAreas)/\(totalAreas) areas)")
                
                // Small delay before next batch to avoid overwhelming server
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    fetchNextBatch(batchIndex: batchIndex + 1)
                }
            }
        }
        
        fetchNextBatch(batchIndex: 0)
    }
    
    // MARK: - Fallback: Paginated Fetch
    
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
        let pageSize = 100
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