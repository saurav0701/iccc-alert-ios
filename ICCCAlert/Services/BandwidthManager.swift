import Foundation
import Network
import Combine

// MARK: - Bandwidth Manager
// Detects network speed and provides adaptive quality recommendations

class BandwidthManager: ObservableObject {
    static let shared = BandwidthManager()
    
    // MARK: - Published Properties
    @Published var currentBandwidth: NetworkSpeed = .unknown
    @Published var recommendedQuality: StreamQuality = .auto
    @Published var isMeteredConnection: Bool = false
    @Published var networkType: NetworkType = .unknown
    
    // MARK: - Models
    
    enum NetworkSpeed: String, CaseIterable {
        case veryFast = "Very Fast (50+ Mbps)"
        case fast = "Fast (10-50 Mbps)"
        case moderate = "Moderate (5-10 Mbps)"
        case slow = "Slow (1-5 Mbps)"
        case verySlow = "Very Slow (<1 Mbps)"
        case unknown = "Unknown"
        
        var icon: String {
            switch self {
            case .veryFast: return "bolt.fill"
            case .fast: return "hare.fill"
            case .moderate: return "tortoise.fill"
            case .slow: return "tortoise"
            case .verySlow: return "exclamationmark.triangle"
            case .unknown: return "wifi.slash"
            }
        }
        
        var color: String {
            switch self {
            case .veryFast: return "green"
            case .fast: return "blue"
            case .moderate: return "orange"
            case .slow: return "orange"
            case .verySlow: return "red"
            case .unknown: return "gray"
            }
        }
        
        var mbps: Double {
            switch self {
            case .veryFast: return 50
            case .fast: return 25
            case .moderate: return 7.5
            case .slow: return 3
            case .verySlow: return 0.5
            case .unknown: return 0
            }
        }
    }
    
    enum StreamQuality: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case high = "High (1080p)"
        case medium = "Medium (720p)"
        case low = "Low (480p)"
        case veryLow = "Very Low (360p)"
        
        var id: String { rawValue }
        
        var resolution: String {
            switch self {
            case .auto: return "Auto"
            case .high: return "1920x1080"
            case .medium: return "1280x720"
            case .low: return "854x480"
            case .veryLow: return "640x360"
            }
        }
        
        var bitrateKbps: Int {
            switch self {
            case .auto: return 0 // Dynamic
            case .high: return 3000
            case .medium: return 1500
            case .low: return 800
            case .veryLow: return 400
            }
        }
        
        var requiredMbps: Double {
            switch self {
            case .auto: return 0
            case .high: return 5.0
            case .medium: return 3.0
            case .low: return 1.5
            case .veryLow: return 0.8
            }
        }
        
        var icon: String {
            switch self {
            case .auto: return "wand.and.stars"
            case .high: return "4k.tv"
            case .medium: return "tv"
            case .low: return "rectangle.compress.vertical"
            case .veryLow: return "rectangle.compress.vertical"
            }
        }
    }
    
    enum NetworkType: String {
        case wifi = "WiFi"
        case cellular5G = "5G"
        case cellular4G = "4G"
        case cellular3G = "3G"
        case ethernet = "Ethernet"
        case unknown = "Unknown"
        
        var icon: String {
            switch self {
            case .wifi: return "wifi"
            case .cellular5G: return "antenna.radiowaves.left.and.right"
            case .cellular4G: return "antenna.radiowaves.left.and.right"
            case .cellular3G: return "antenna.radiowaves.left.and.right"
            case .ethernet: return "cable.connector"
            case .unknown: return "questionmark"
            }
        }
    }
    
    // MARK: - Configuration
    private let speedTestInterval: TimeInterval = 30.0 // Test every 30 seconds
    private let speedTestURL = "https://httpbin.org/bytes/1000000" // 1MB test file
    private let multiCameraQualityPenalty = 0.7 // Reduce quality to 70% for multi-cam
    
    // MARK: - Private Properties
    private var speedTestTimer: Timer?
    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.iccc.bandwidthMonitor")
    private var cancellables = Set<AnyCancellable>()
    
    // Speed test cache
    private var lastSpeedTest: Date?
    private var speedTestResults: [Double] = []
    private let maxSpeedTestResults = 5
    
    private init() {
        setupNetworkMonitoring()
        startPeriodicSpeedTest()
    }
    
    // MARK: - Network Monitoring
    
    private func setupNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.isMeteredConnection = path.isExpensive
                
                // Detect network type
                if path.usesInterfaceType(.wifi) {
                    self.networkType = .wifi
                } else if path.usesInterfaceType(.cellular) {
                    self.detectCellularType(path: path)
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.networkType = .ethernet
                } else {
                    self.networkType = .unknown
                }
                
                // Initial quality recommendation
                self.updateRecommendedQuality()
                
                DebugLogger.shared.log(
                    "📡 Network: \(self.networkType.rawValue), Metered: \(self.isMeteredConnection)",
                    emoji: "📡",
                    color: .blue
                )
            }
        }
        
        networkMonitor.start(queue: monitorQueue)
    }
    
    private func detectCellularType(path: NWPath) {
        // In a real app, you'd use CoreTelephony to detect exact cellular type
        // For now, assume 4G as default
        networkType = .cellular4G
    }
    
    // MARK: - Speed Testing
    
    private func startPeriodicSpeedTest() {
        speedTestTimer = Timer.scheduledTimer(
            withTimeInterval: speedTestInterval,
            repeats: true
        ) { [weak self] _ in
            self?.performSpeedTest()
        }
        
        // Initial speed test
        performSpeedTest()
    }
    
    func performSpeedTest() {
        // Skip if on metered connection to save data
        if isMeteredConnection {
            DebugLogger.shared.log("⚠️ Skipping speed test on metered connection", emoji: "⚠️", color: .orange)
            estimateSpeedFromNetworkType()
            return
        }
        
        guard let url = URL(string: speedTestURL) else { return }
        
        let startTime = Date()
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                DebugLogger.shared.log("❌ Speed test failed: \(error.localizedDescription)", emoji: "❌", color: .red)
                self.estimateSpeedFromNetworkType()
                return
            }
            
            guard let data = data else { return }
            
            let duration = Date().timeIntervalSince(startTime)
            let bytesReceived = Double(data.count)
            let bitsReceived = bytesReceived * 8
            let mbps = (bitsReceived / duration) / 1_000_000
            
            DispatchQueue.main.async {
                self.updateSpeedTest(mbps: mbps)
            }
        }.resume()
    }
    
    private func updateSpeedTest(mbps: Double) {
        speedTestResults.append(mbps)
        
        if speedTestResults.count > maxSpeedTestResults {
            speedTestResults.removeFirst()
        }
        
        let avgMbps = speedTestResults.reduce(0, +) / Double(speedTestResults.count)
        
        currentBandwidth = classifySpeed(mbps: avgMbps)
        updateRecommendedQuality()
        
        DebugLogger.shared.log(
            "📊 Speed Test: \(String(format: "%.2f", avgMbps)) Mbps → \(currentBandwidth.rawValue)",
            emoji: "📊",
            color: .green
        )
    }
    
    private func classifySpeed(mbps: Double) -> NetworkSpeed {
        if mbps >= 50 {
            return .veryFast
        } else if mbps >= 10 {
            return .fast
        } else if mbps >= 5 {
            return .moderate
        } else if mbps >= 1 {
            return .slow
        } else {
            return .verySlow
        }
    }
    
    private func estimateSpeedFromNetworkType() {
        let estimatedSpeed: NetworkSpeed
        
        switch networkType {
        case .wifi:
            estimatedSpeed = .fast
        case .cellular5G:
            estimatedSpeed = .veryFast
        case .cellular4G:
            estimatedSpeed = .moderate
        case .cellular3G:
            estimatedSpeed = .slow
        case .ethernet:
            estimatedSpeed = .veryFast
        case .unknown:
            estimatedSpeed = .unknown
        }
        
        DispatchQueue.main.async {
            self.currentBandwidth = estimatedSpeed
            self.updateRecommendedQuality()
        }
    }
    
    // MARK: - Quality Recommendation
    
    private func updateRecommendedQuality() {
        let speedMbps = currentBandwidth.mbps
        
        let quality: StreamQuality
        if speedMbps >= 10 {
            quality = .high
        } else if speedMbps >= 5 {
            quality = .medium
        } else if speedMbps >= 2 {
            quality = .low
        } else {
            quality = .veryLow
        }
        
        recommendedQuality = quality
    }
    
    func getRecommendedQuality(forCameraCount count: Int) -> StreamQuality {
        guard count > 0 else { return .auto }
        
        let speedMbps = currentBandwidth.mbps
        
        // Adjust for multiple cameras
        let adjustedSpeed = count > 1 ? speedMbps * multiCameraQualityPenalty : speedMbps
        
        if count >= 4 {
            // Quad view - very conservative
            if adjustedSpeed >= 20 {
                return .medium
            } else if adjustedSpeed >= 10 {
                return .low
            } else {
                return .veryLow
            }
        } else if count >= 2 {
            // Dual view
            if adjustedSpeed >= 15 {
                return .high
            } else if adjustedSpeed >= 8 {
                return .medium
            } else {
                return .low
            }
        } else {
            // Single camera - full quality
            return recommendedQuality
        }
    }
    
    func canSupport(quality: StreamQuality, cameraCount: Int = 1) -> Bool {
        let requiredSpeed = quality.requiredMbps * Double(cameraCount)
        let availableSpeed = currentBandwidth.mbps
        
        return availableSpeed >= requiredSpeed
    }
    
    // MARK: - Data Saver Mode
    
    func shouldEnableDataSaver() -> Bool {
        return isMeteredConnection || currentBandwidth == .slow || currentBandwidth == .verySlow
    }
    
    func getDataSaverRecommendation() -> String {
        if isMeteredConnection {
            return "You're on a metered connection. Consider using lower quality to save data."
        } else if currentBandwidth == .slow || currentBandwidth == .verySlow {
            return "Your connection is slow. Lower quality will improve playback stability."
        }
        return ""
    }
    
    // MARK: - Statistics
    
    func getBandwidthReport() -> String {
        var report = "=== Bandwidth Report ===\n"
        report += "Network: \(networkType.rawValue)\n"
        report += "Speed: \(currentBandwidth.rawValue)\n"
        report += "Recommended Quality: \(recommendedQuality.rawValue)\n"
        report += "Metered: \(isMeteredConnection ? "Yes" : "No")\n"
        
        if !speedTestResults.isEmpty {
            let avg = speedTestResults.reduce(0, +) / Double(speedTestResults.count)
            report += "Avg Speed: \(String(format: "%.2f", avg)) Mbps\n"
        }
        
        return report
    }
    
    deinit {
        networkMonitor.cancel()
        speedTestTimer?.invalidate()
    }
}