import Foundation
import UIKit

// MARK: - Memory Monitor (PASSIVE - Only tracks, doesn't trigger actions)
class MemoryMonitor: ObservableObject {
    static let shared = MemoryMonitor()
    
    @Published var currentMemoryMB: Double = 0.0
    @Published private(set) var isMemoryWarning: Bool = false
    
    private var timer: Timer?
    
    // ✅ FIXED: Much higher thresholds - only for streaming scenarios
    private let normalThresholdMB: Double = 250.0      // Normal ops (was 150)
    private let streamingThresholdMB: Double = 180.0   // When streaming video
    
    private var isStreamingActive = false
    
    private init() {
        startPassiveMonitoring()
        setupMemoryWarningObserver()
        
        print("💾 MemoryMonitor initialized (passive mode)")
        print("   Normal threshold: \(normalThresholdMB)MB")
        print("   Streaming threshold: \(streamingThresholdMB)MB")
    }
    
    private func startPassiveMonitoring() {
        // ✅ FIXED: Check less frequently (30s instead of 10s)
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.updateMemoryUsage()
        }
        
        // Initial check
        updateMemoryUsage()
    }
    
    private func setupMemoryWarningObserver() {
        // System memory warnings only
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("⚠️ System memory warning received")
            self?.isMemoryWarning = true
            
            // Reset warning after 10 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                self?.isMemoryWarning = false
            }
        }
    }
    
    private func updateMemoryUsage() {
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
        
        guard kerr == KERN_SUCCESS else {
            return
        }
        
        let usedMemoryMB = Double(info.resident_size) / 1024 / 1024
        
        DispatchQueue.main.async {
            self.currentMemoryMB = usedMemoryMB
            
            // ✅ FIXED: Use appropriate threshold based on streaming state
            let threshold = self.isStreamingActive ? self.streamingThresholdMB : self.normalThresholdMB
            
            // Only trigger warning if significantly above threshold
            if usedMemoryMB > threshold && !self.isMemoryWarning {
                print("⚠️ Memory above threshold: \(String(format: "%.1f", usedMemoryMB))MB (threshold: \(threshold)MB)")
                self.isMemoryWarning = true
            } else if usedMemoryMB <= (threshold - 20) { // 20MB hysteresis
                self.isMemoryWarning = false
            }
        }
    }
    
    // ✅ NEW: Update streaming state
    func setStreamingActive(_ active: Bool) {
        isStreamingActive = active
        print("💾 Streaming state: \(active ? "ACTIVE" : "INACTIVE")")
        
        // Immediate check when streaming starts
        if active {
            updateMemoryUsage()
        }
    }
    
    func forceUpdate() {
        updateMemoryUsage()
    }
    
    deinit {
        timer?.invalidate()
    }
}