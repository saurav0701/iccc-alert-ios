import Foundation
import UIKit

// MARK: - Memory Monitor (ONLY FOR STREAMING - NOT RUNNING BY DEFAULT)
class MemoryMonitor: ObservableObject {
    static let shared = MemoryMonitor()
    
    @Published var currentMemoryMB: Double = 0.0
    @Published private(set) var isMemoryWarning: Bool = false
    
    private var timer: Timer?
    private var isMonitoring = false
    
    // High thresholds - only for streaming
    private let streamingThresholdMB: Double = 180.0
    
    private init() {
        setupMemoryWarningObserver()
        print("💾 MemoryMonitor initialized (INACTIVE - only starts when streaming)")
    }
    
    private func setupMemoryWarningObserver() {
        // Only respond to system memory warnings
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
    
    // Start monitoring ONLY when streaming starts
    func startMonitoring() {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        print("💾 MemoryMonitor STARTED (streaming active)")
        
        // Check every 10 seconds while streaming
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.updateMemoryUsage()
        }
        
        // Initial check
        updateMemoryUsage()
    }
    
    // Stop monitoring when streaming stops
    func stopMonitoring() {
        guard isMonitoring else { return }
        
        isMonitoring = false
        timer?.invalidate()
        timer = nil
        
        isMemoryWarning = false
        
        print("💾 MemoryMonitor STOPPED (streaming inactive)")
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
            
            // Only check threshold while streaming
            if usedMemoryMB > self.streamingThresholdMB && !self.isMemoryWarning {
                print("⚠️ Memory above streaming threshold: \(String(format: "%.1f", usedMemoryMB))MB")
                self.isMemoryWarning = true
            } else if usedMemoryMB <= (self.streamingThresholdMB - 20) {
                self.isMemoryWarning = false
            }
        }
    }
    
    func forceUpdate() {
        updateMemoryUsage()
    }
    
    deinit {
        timer?.invalidate()
    }
}