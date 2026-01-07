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
    
    // ✅ FIXED: REST API polling timer - REDUCED TO 2 HOURS
    private var cameraRefreshTimer: Timer?
    private let refreshInterval: TimeInterval = 2 * 60 * 60 // 2 HOURS (cameras don't change frequently)
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
        
        // ✅ Start REST API polling (2 hours interval)
        startPeriodicRefresh()
    }
    
    // MARK: - REST API Polling (2 HOUR INTERVAL)
    
    /// ✅ Start periodic camera refresh via REST API (2 hours)
    private func startPeriodicRefresh() {
        // Initial fetch after 5 seconds (give WebSocket time to connect first)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.fetchCamerasViaREST()
        }
        
        // ✅ CHANGED: Then every 2 HOURS (not 30 seconds!)
        cameraRefreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.fetchCamerasViaREST()
        }
        
        print("✅ Camera REST API polling started (every \(Int(refreshInterval/3600)) hours)")
    }
    
    /// ✅ Fetch cameras via REST API
    private func fetchCamerasViaREST() {
        guard !isFetching else {
            print("⏳ Camera fetch already in progress, skipping")
            return
        }
        
        isFetching = true
        
        print("📡 Fetching cameras via REST API...")
        
        CameraAPIService.shared.fetchAllCameras { [weak self] result in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.isFetching = false
                
                switch result {
                case .success(let cameras):
                    print("✅ REST API: Received \(cameras.count) cameras")
                    self.updateCameras(cameras)
                    
                case .failure(let error):
                    print("❌ REST API failed: \(error.localizedDescription)")
                    // Keep existing cached data on failure
                }
            }
        }
    }
    
    /// ✅ Manual refresh (called from UI pull-to-refresh)
    func manualRefresh(completion: @escaping (Bool) -> Void) {
        guard !isFetching else {
            completion(false)
            return
        }
        
        print("🔄 Manual camera refresh triggered")
        
        isFetching = true
        isLoading = true
        
        CameraAPIService.shared.fetchAllCameras { [weak self] result in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.isFetching = false
                self.isLoading = false
                
                switch result {
                case .success(let cameras):
                    print("✅ Manual refresh: \(cameras.count) cameras")
                    self.updateCameras(cameras)
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
                // FIRST TIME: Store complete camera list permanently
                self.performInitialLoad(newCameras)
            } else {
                // SUBSEQUENT: Only update status + add any new cameras
                self.performStatusUpdate(newCameras)
            }
            
            self.lastUpdateTime = Date()
            
            print("   Current total: \(self.cameras.count)")
            print("   Online: \(self.onlineCamerasCount)")
            print("   Areas: \(self.availableAreas.count)")
            
            // Log per-area breakdown (first 3 areas)
            for area in self.availableAreas.prefix(3) {
                let areaCameras = self.getCameras(forArea: area)
                let areaOnline = areaCameras.filter { $0.isOnline }.count
                print("      \(area): \(areaCameras.count) total, \(areaOnline) online")
            }
            
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            
            // Force UI refresh
            NotificationCenter.default.post(name: NSNotification.Name("CamerasUpdated"), object: nil)
        }
    }
    
    // MARK: - Initial Load (Complete Camera List)
    
    private func performInitialLoad(_ newCameras: [Camera]) {
        print("📹 INITIAL LOAD: Storing \(newCameras.count) cameras permanently")
        
        // Store complete camera list
        self.cameras = newCameras
        self.hasInitialData = true
        
        // Save permanently
        saveCameraList()
        
        print("✅ Initial load complete")
        print("   Cameras: \(self.cameras.count)")
        print("   Areas: \(self.availableAreas.joined(separator: ", "))")
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
            
            print("➕ Added \(newCamerasCount) new cameras")
            
            // Save complete list when cameras are added
            saveCameraList()
        }
        
        if updatedCount > 0 {
            print("📹 Status update: \(updatedCount) cameras changed status")
            
            // Save status changes (lighter operation)
            saveCameraStatuses()
        }
    }
    
    // MARK: - Get Cameras by Area
    
    func getCameras(forArea area: String) -> [Camera] {
        let filtered = cameras.filter { $0.area == area }
        
        if filtered.isEmpty && hasInitialData {
            print("⚠️ No cameras found for area: \(area)")
            print("   Available areas: \(availableAreas.joined(separator: ", "))")
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
                print("💾 Saved complete camera list (\(self.cameras.count) cameras)")
            }
        }
    }
    
    private func saveCameraStatuses() {
        saveQueue.async {
            // Only save status data (lighter operation)
            let statusData = self.cameras.map { ["id": $0.id, "status": $0.status] }
            if let data = try? JSONEncoder().encode(statusData) {
                self.userDefaults.set(data, forKey: self.cameraStatusKey)
                print("💾 Saved camera statuses")
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
            
            print("📦 Loaded \(cached.count) cameras from cache")
            print("   Online: \(onlineCamerasCount)")
            print("   Areas: \(availableAreas.joined(separator: ", "))")
            
            if let lastUpdate = lastUpdateTime {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                print("   Last update: \(formatter.string(from: lastUpdate))")
            }
        } else {
            print("⚠️ No cached cameras found")
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
        print("🗑️ Camera cache cleared")
    }
    
    func forceRefresh() {
        print("🔄 Force refreshing camera list")
        NotificationCenter.default.post(name: NSNotification.Name("CamerasUpdated"), object: nil)
    }
    
    deinit {
        cameraRefreshTimer?.invalidate()
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