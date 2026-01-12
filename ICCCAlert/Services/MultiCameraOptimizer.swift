import Foundation
import Combine
import UIKit

// MARK: - Multi-Camera Performance Optimizer
// Manages memory and loading for quad camera views

class MultiCameraOptimizer: ObservableObject {
    static let shared = MultiCameraOptimizer()
    
    // MARK: - Published Properties
    @Published var memoryUsageMB: Double = 0
    @Published var activeStreamCount: Int = 0
    @Published var isMemoryWarning: Bool = false
    @Published var optimizationMode: OptimizationMode = .balanced
    
    // MARK: - Models
    
    enum OptimizationMode: String, CaseIterable {
        case performance = "Performance"
        case balanced = "Balanced"
        case efficiency = "Efficiency"
        
        var description: String {
            switch self {
            case .performance:
                return "Best quality, higher memory usage"
            case .balanced:
                return "Good quality, moderate memory"
            case .efficiency:
                return "Lower quality, minimal memory"
            }
        }
        
        var maxConcurrentStreams: Int {
            switch self {
            case .performance: return 4
            case .balanced: return 3
            case .efficiency: return 2
            }
        }
        
        var frameRateLimit: Int {
            switch self {
            case .performance: return 30
            case .balanced: return 24
            case .efficiency: return 15
            }
        }
        
        var bufferSize: Int {
            switch self {
            case .performance: return 10
            case .balanced: return 5
            case .efficiency: return 3
            }
        }
    }
    
    struct StreamLoadingStrategy {
        let cameraId: String
        let priority: LoadingPriority
        let loadDelay: TimeInterval
        
        enum LoadingPriority: Int, Comparable {
            case immediate = 0
            case high = 1
            case normal = 2
            case low = 3
            
            static func < (lhs: LoadingPriority, rhs: LoadingPriority) -> Bool {
                return lhs.rawValue < rhs.rawValue
            }
        }
    }
    
    // MARK: - Configuration
    private let memoryWarningThresholdMB: Double = 300
    private let criticalMemoryThresholdMB: Double = 400
    private let memoryCheckInterval: TimeInterval = 2.0
    private let progressiveLoadDelay: TimeInterval = 0.5 // Delay between loading cameras
    
    // MARK: - Private Properties
    private var memoryMonitorTimer: Timer?
    private var activeStreams: Set<String> = []
    private var streamPriorities: [String: StreamLoadingStrategy.LoadingPriority] = [:]
    private var cancellables = Set<AnyCancellable>()
    
    private var memoryWarningObserver: NSObjectProtocol?
    
    private init() {
        setupMemoryMonitoring()
        setupMemoryWarningNotification()
        determineOptimizationMode()
    }
    
    // MARK: - Memory Monitoring
    
    private func setupMemoryMonitoring() {
        memoryMonitorTimer = Timer.scheduledTimer(
            withTimeInterval: memoryCheckInterval,
            repeats: true
        ) { [weak self] _ in
            self?.checkMemoryUsage()
        }
    }
    
    private func checkMemoryUsage() {
        let usage = getMemoryUsage()
        
        DispatchQueue.main.async {
            self.memoryUsageMB = usage
            
            if usage > self.criticalMemoryThresholdMB {
                self.handleCriticalMemory()
            } else if usage > self.memoryWarningThresholdMB {
                self.handleMemoryWarning()
            } else {
                self.isMemoryWarning = false
            }
        }
    }
    
    private func getMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        
        if kerr == KERN_SUCCESS {
            return Double(info.resident_size) / 1_048_576 // Convert to MB
        }
        
        return 0
    }
    
    private func setupMemoryWarningNotification() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleCriticalMemory()
        }
    }
    
    private func handleMemoryWarning() {
        isMemoryWarning = true
        
        DebugLogger.shared.log(
            "⚠️ Memory Warning: \(String(format: "%.1f", memoryUsageMB)) MB",
            emoji: "⚠️",
            color: .orange
        )
        
        // Switch to efficiency mode
        if optimizationMode != .efficiency {
            optimizationMode = .efficiency
            DebugLogger.shared.log("🔧 Switched to Efficiency mode", emoji: "🔧", color: .yellow)
        }
    }
    
    private func handleCriticalMemory() {
        DebugLogger.shared.log(
            "🚨 CRITICAL MEMORY: \(String(format: "%.1f", memoryUsageMB)) MB",
            emoji: "🚨",
            color: .red
        )
        
        // Aggressive cleanup
        performAggressiveCleanup()
    }
    
    private func performAggressiveCleanup() {
        // Clear image caches
        EventImageLoader.shared.clearCache()
        
        // Request lowest streams to pause
        let lowPriorityStreams = streamPriorities
            .filter { $0.value == .low || $0.value == .normal }
            .map { $0.key }
        
        for streamId in lowPriorityStreams {
            NotificationCenter.default.post(
                name: NSNotification.Name("PauseStreamForMemory"),
                object: nil,
                userInfo: ["cameraId": streamId]
            )
        }
        
        DebugLogger.shared.log("🧹 Aggressive cleanup completed", emoji: "🧹", color: .blue)
    }
    
    // MARK: - Optimization Mode
    
    private func determineOptimizationMode() {
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        let totalRAMGB = Double(totalRAM) / 1_073_741_824
        
        // Auto-detect based on device capability
        if totalRAMGB >= 4 {
            optimizationMode = .performance
        } else if totalRAMGB >= 2 {
            optimizationMode = .balanced
        } else {
            optimizationMode = .efficiency
        }
        
        DebugLogger.shared.log(
            "📱 Device RAM: \(String(format: "%.1f", totalRAMGB)) GB → \(optimizationMode.rawValue) mode",
            emoji: "📱",
            color: .blue
        )
    }
    
    func setOptimizationMode(_ mode: OptimizationMode) {
        optimizationMode = mode
        DebugLogger.shared.log("🔧 Optimization mode set to: \(mode.rawValue)", emoji: "🔧", color: .blue)
    }
    
    // MARK: - Stream Management
    
    func registerStream(cameraId: String, priority: StreamLoadingStrategy.LoadingPriority = .normal) {
        activeStreams.insert(cameraId)
        streamPriorities[cameraId] = priority
        activeStreamCount = activeStreams.count
        
        DebugLogger.shared.log(
            "📹 Stream registered: \(cameraId) (Priority: \(priority), Total: \(activeStreamCount))",
            emoji: "📹",
            color: .blue
        )
    }
    
    func unregisterStream(cameraId: String) {
        activeStreams.remove(cameraId)
        streamPriorities.removeValue(forKey: cameraId)
        activeStreamCount = activeStreams.count
        
        DebugLogger.shared.log(
            "📹 Stream unregistered: \(cameraId) (Remaining: \(activeStreamCount))",
            emoji: "📹",
            color: .gray
        )
    }
    
    // MARK: - Progressive Loading Strategy
    
    func getProgressiveLoadingStrategy(for cameraIds: [String]) -> [StreamLoadingStrategy] {
        var strategies: [StreamLoadingStrategy] = []
        
        for (index, cameraId) in cameraIds.enumerated() {
            let priority: StreamLoadingStrategy.LoadingPriority
            let delay: TimeInterval
            
            switch index {
            case 0:
                priority = .immediate
                delay = 0
            case 1:
                priority = .high
                delay = progressiveLoadDelay
            case 2:
                priority = .normal
                delay = progressiveLoadDelay * 2
            default:
                priority = .low
                delay = progressiveLoadDelay * 3
            }
            
            strategies.append(StreamLoadingStrategy(
                cameraId: cameraId,
                priority: priority,
                loadDelay: delay
            ))
        }
        
        return strategies.sorted { $0.priority < $1.priority }
    }
    
    func shouldThrottle() -> Bool {
        return activeStreamCount >= optimizationMode.maxConcurrentStreams || isMemoryWarning
    }
    
    func canLoadMoreStreams() -> Bool {
        return activeStreamCount < optimizationMode.maxConcurrentStreams && !isMemoryWarning
    }
    
    // MARK: - Frame Rate Control
    
    func getRecommendedFrameRate(for cameraCount: Int) -> Int {
        let baseFrameRate = optimizationMode.frameRateLimit
        
        switch cameraCount {
        case 1:
            return baseFrameRate
        case 2:
            return max(baseFrameRate - 6, 15)
        case 3:
            return max(baseFrameRate - 10, 12)
        case 4...:
            return max(baseFrameRate - 15, 10)
        default:
            return 15
        }
    }
    
    // MARK: - Buffer Management
    
    func getRecommendedBufferSize(for cameraCount: Int) -> Int {
        let baseBuffer = optimizationMode.bufferSize
        
        return max(baseBuffer - cameraCount, 1)
    }
    
    // MARK: - Statistics & Reporting
    
    func getOptimizationReport() -> String {
        var report = "=== Multi-Camera Optimization Report ===\n"
        report += "Mode: \(optimizationMode.rawValue)\n"
        report += "Memory Usage: \(String(format: "%.1f", memoryUsageMB)) MB\n"
        report += "Active Streams: \(activeStreamCount)\n"
        report += "Max Concurrent: \(optimizationMode.maxConcurrentStreams)\n"
        report += "Frame Rate Limit: \(optimizationMode.frameRateLimit) fps\n"
        report += "Memory Warning: \(isMemoryWarning ? "⚠️ YES" : "✅ No")\n"
        
        if !streamPriorities.isEmpty {
            report += "\nStream Priorities:\n"
            for (id, priority) in streamPriorities.sorted(by: { $0.value < $1.value }) {
                report += "  \(id): \(priority)\n"
            }
        }
        
        return report
    }
    
    func getPerformanceMetrics() -> [String: Any] {
        return [
            "memoryMB": memoryUsageMB,
            "activeStreams": activeStreamCount,
            "mode": optimizationMode.rawValue,
            "memoryWarning": isMemoryWarning,
            "maxConcurrent": optimizationMode.maxConcurrentStreams,
            "frameRateLimit": optimizationMode.frameRateLimit
        ]
    }
    
    // MARK: - Recommendations
    
    func getRecommendation(for cameraCount: Int) -> String {
        if cameraCount <= 1 {
            return "Single camera - full performance available"
        }
        
        if cameraCount >= 4 && optimizationMode == .performance {
            return "4 cameras detected. Consider Balanced mode for better stability."
        }
        
        if isMemoryWarning {
            return "⚠️ Memory usage high. Reduce active cameras or switch to Efficiency mode."
        }
        
        if memoryUsageMB > memoryWarningThresholdMB * 0.8 {
            return "Memory usage approaching limit. Consider reducing camera count."
        }
        
        return "System running optimally"
    }
    
    deinit {
        memoryMonitorTimer?.invalidate()
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}