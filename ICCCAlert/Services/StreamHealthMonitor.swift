import Foundation
import Combine
import Network

// MARK: - Stream Health Monitor
// Monitors WebRTC stream health and triggers auto-recovery

class StreamHealthMonitor: ObservableObject {
    static let shared = StreamHealthMonitor()
    
    // MARK: - Published Properties
    @Published var streamHealths: [String: StreamHealth] = [:] // cameraId -> health
    @Published var globalConnectionQuality: ConnectionQuality = .unknown
    
    // MARK: - Stream Health Model
    struct StreamHealth {
        let cameraId: String
        var connectionQuality: ConnectionQuality
        var lastPacketTime: Date
        var reconnectAttempts: Int
        var isStalled: Bool
        var latencyMs: Double
        var bufferHealth: BufferHealth
        var bitrateKbps: Double
        
        var isHealthy: Bool {
            return connectionQuality != .poor && 
                   !isStalled && 
                   latencyMs < 3000 &&
                   bufferHealth != .critical
        }
    }
    
    enum ConnectionQuality: String {
        case excellent = "Excellent"
        case good = "Good"
        case fair = "Fair"
        case poor = "Poor"
        case unknown = "Unknown"
        
        var color: String {
            switch self {
            case .excellent: return "green"
            case .good: return "blue"
            case .fair: return "orange"
            case .poor: return "red"
            case .unknown: return "gray"
            }
        }
        
        var icon: String {
            switch self {
            case .excellent: return "antenna.radiowaves.left.and.right"
            case .good: return "wifi"
            case .fair: return "wifi.slash"
            case .poor: return "exclamationmark.triangle"
            case .unknown: return "questionmark"
            }
        }
    }
    
    enum BufferHealth {
        case healthy
        case warning
        case critical
        
        var description: String {
            switch self {
            case .healthy: return "Buffering OK"
            case .warning: return "Low Buffer"
            case .critical: return "Buffer Critical"
            }
        }
    }
    
    // MARK: - Configuration
    private let stallDetectionInterval: TimeInterval = 5.0
    private let maxReconnectAttempts = 3
    private let healthCheckInterval: TimeInterval = 2.0
    private let latencyThresholds = (excellent: 500.0, good: 1000.0, fair: 2000.0)
    
    // MARK: - Private Properties
    private var healthCheckTimers: [String: Timer] = [:]
    private var stallDetectionTimers: [String: Timer] = [:]
    private var reconnectCallbacks: [String: () -> Void] = [:]
    private var cancellables = Set<AnyCancellable>()
    
    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.iccc.networkMonitor")
    
    private init() {
        setupNetworkMonitoring()
    }
    
    // MARK: - Network Monitoring
    
    private func setupNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if path.status == .satisfied {
                    if path.usesInterfaceType(.wifi) {
                        self.globalConnectionQuality = .excellent
                    } else if path.usesInterfaceType(.cellular) {
                        self.globalConnectionQuality = .good
                    } else {
                        self.globalConnectionQuality = .fair
                    }
                } else {
                    self.globalConnectionQuality = .poor
                    self.handleNetworkLoss()
                }
            }
        }
        
        networkMonitor.start(queue: monitorQueue)
    }
    
    private func handleNetworkLoss() {
        DebugLogger.shared.log("📡 Network connection lost", emoji: "📡", color: .red)
        
        // Mark all streams as stalled
        for cameraId in streamHealths.keys {
            streamHealths[cameraId]?.isStalled = true
            streamHealths[cameraId]?.connectionQuality = .poor
        }
    }
    
    // MARK: - Stream Registration
    
    func registerStream(cameraId: String, onReconnect: @escaping () -> Void) {
        DebugLogger.shared.log("📹 Registering stream health monitor: \(cameraId)", emoji: "📹", color: .blue)
        
        streamHealths[cameraId] = StreamHealth(
            cameraId: cameraId,
            connectionQuality: .unknown,
            lastPacketTime: Date(),
            reconnectAttempts: 0,
            isStalled: false,
            latencyMs: 0,
            bufferHealth: .healthy,
            bitrateKbps: 0
        )
        
        reconnectCallbacks[cameraId] = onReconnect
        
        startHealthChecking(for: cameraId)
        startStallDetection(for: cameraId)
    }
    
    func unregisterStream(cameraId: String) {
        DebugLogger.shared.log("📹 Unregistering stream health monitor: \(cameraId)", emoji: "📹", color: .gray)
        
        healthCheckTimers[cameraId]?.invalidate()
        stallDetectionTimers[cameraId]?.invalidate()
        
        healthCheckTimers.removeValue(forKey: cameraId)
        stallDetectionTimers.removeValue(forKey: cameraId)
        streamHealths.removeValue(forKey: cameraId)
        reconnectCallbacks.removeValue(forKey: cameraId)
    }
    
    // MARK: - Health Checking
    
    private func startHealthChecking(for cameraId: String) {
        let timer = Timer.scheduledTimer(withTimeInterval: healthCheckInterval, repeats: true) { [weak self] _ in
            self?.performHealthCheck(for: cameraId)
        }
        
        healthCheckTimers[cameraId] = timer
    }
    
    private func performHealthCheck(for cameraId: String) {
        guard var health = streamHealths[cameraId] else { return }
        
        // Calculate latency (simulated - in real app, measure from WebRTC stats)
        let timeSinceLastPacket = Date().timeIntervalSince(health.lastPacketTime)
        health.latencyMs = timeSinceLastPacket * 1000
        
        // Update connection quality based on latency
        health.connectionQuality = calculateConnectionQuality(latencyMs: health.latencyMs)
        
        // Update buffer health
        health.bufferHealth = calculateBufferHealth(latencyMs: health.latencyMs)
        
        streamHealths[cameraId] = health
        
        // Log poor health
        if !health.isHealthy {
            DebugLogger.shared.log(
                "⚠️ Stream \(cameraId): Quality=\(health.connectionQuality.rawValue), Latency=\(Int(health.latencyMs))ms",
                emoji: "⚠️",
                color: .orange
            )
        }
    }
    
    private func calculateConnectionQuality(latencyMs: Double) -> ConnectionQuality {
        if latencyMs < latencyThresholds.excellent {
            return .excellent
        } else if latencyMs < latencyThresholds.good {
            return .good
        } else if latencyMs < latencyThresholds.fair {
            return .fair
        } else {
            return .poor
        }
    }
    
    private func calculateBufferHealth(latencyMs: Double) -> BufferHealth {
        if latencyMs < 1000 {
            return .healthy
        } else if latencyMs < 2000 {
            return .warning
        } else {
            return .critical
        }
    }
    
    // MARK: - Stall Detection
    
    private func startStallDetection(for cameraId: String) {
        let timer = Timer.scheduledTimer(withTimeInterval: stallDetectionInterval, repeats: true) { [weak self] _ in
            self?.checkForStall(cameraId: cameraId)
        }
        
        stallDetectionTimers[cameraId] = timer
    }
    
    private func checkForStall(cameraId: String) {
        guard var health = streamHealths[cameraId] else { return }
        
        let timeSinceLastPacket = Date().timeIntervalSince(health.lastPacketTime)
        
        if timeSinceLastPacket > stallDetectionInterval {
            if !health.isStalled {
                health.isStalled = true
                streamHealths[cameraId] = health
                
                DebugLogger.shared.log("⚠️ Stream stalled: \(cameraId)", emoji: "⚠️", color: .red)
                
                // Trigger auto-recovery
                attemptRecovery(for: cameraId)
            }
        } else {
            if health.isStalled {
                health.isStalled = false
                health.reconnectAttempts = 0
                streamHealths[cameraId] = health
                
                DebugLogger.shared.log("✅ Stream recovered: \(cameraId)", emoji: "✅", color: .green)
            }
        }
    }
    
    // MARK: - Auto Recovery
    
    private func attemptRecovery(for cameraId: String) {
        guard var health = streamHealths[cameraId] else { return }
        
        health.reconnectAttempts += 1
        streamHealths[cameraId] = health
        
        if health.reconnectAttempts > maxReconnectAttempts {
            DebugLogger.shared.log(
                "❌ Max reconnect attempts reached for: \(cameraId)",
                emoji: "❌",
                color: .red
            )
            return
        }
        
        DebugLogger.shared.log(
            "🔄 Auto-recovery attempt \(health.reconnectAttempts)/\(maxReconnectAttempts) for: \(cameraId)",
            emoji: "🔄",
            color: .yellow
        )
        
        // Exponential backoff
        let delay = TimeInterval(pow(2.0, Double(health.reconnectAttempts - 1)))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.reconnectCallbacks[cameraId]?()
        }
    }
    
    // MARK: - Stream Updates
    
    func updateStreamPacket(cameraId: String, bitrateKbps: Double = 0) {
        guard var health = streamHealths[cameraId] else { return }
        
        health.lastPacketTime = Date()
        health.bitrateKbps = bitrateKbps
        
        // Reset stall flag if packet received
        if health.isStalled {
            health.isStalled = false
            health.reconnectAttempts = 0
            DebugLogger.shared.log("✅ Stream recovered: \(cameraId)", emoji: "✅", color: .green)
        }
        
        streamHealths[cameraId] = health
    }
    
    func forceReconnect(cameraId: String) {
        guard var health = streamHealths[cameraId] else { return }
        
        health.reconnectAttempts = 0
        streamHealths[cameraId] = health
        
        DebugLogger.shared.log("🔄 Force reconnecting: \(cameraId)", emoji: "🔄", color: .blue)
        reconnectCallbacks[cameraId]?()
    }
    
    // MARK: - Statistics
    
    func getStreamStatistics(for cameraId: String) -> String? {
        guard let health = streamHealths[cameraId] else { return nil }
        
        return """
        Camera: \(cameraId)
        Quality: \(health.connectionQuality.rawValue)
        Latency: \(Int(health.latencyMs))ms
        Bitrate: \(Int(health.bitrateKbps)) Kbps
        Buffer: \(health.bufferHealth.description)
        Stalled: \(health.isStalled ? "Yes" : "No")
        Reconnects: \(health.reconnectAttempts)
        """
    }
    
    func getAllStreamStatistics() -> String {
        var stats = "=== Stream Health Report ===\n"
        stats += "Global Connection: \(globalConnectionQuality.rawValue)\n"
        stats += "Active Streams: \(streamHealths.count)\n\n"
        
        for (cameraId, health) in streamHealths {
            stats += "[\(cameraId)]\n"
            stats += "  Quality: \(health.connectionQuality.rawValue)\n"
            stats += "  Latency: \(Int(health.latencyMs))ms\n"
            stats += "  Healthy: \(health.isHealthy ? "✅" : "❌")\n\n"
        }
        
        return stats
    }
    
    deinit {
        networkMonitor.cancel()
        healthCheckTimers.values.forEach { $0.invalidate() }
        stallDetectionTimers.values.forEach { $0.invalidate() }
    }
}