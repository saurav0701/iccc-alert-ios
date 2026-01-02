import Foundation
import UIKit

// MARK: - Memory Monitor (Singleton for tracking app memory usage)
class MemoryMonitor: ObservableObject {
    static let shared = MemoryMonitor()
    
    @Published private(set) var currentMemoryMB: Double = 0.0
    @Published private(set) var isMemoryWarning: Bool = false
    
    private var timer: Timer?
    private let memoryThresholdMB: Double = 200.0 // Warning threshold
    
    private init() {
        startMonitoring()
        setupMemoryWarningObserver()
        
        print("💾 MemoryMonitor initialized")
    }
    
    private func startMonitoring() {
        // Check memory every 10 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.updateMemoryUsage()
        }
        
        // Initial check
        updateMemoryUsage()
    }
    
    private func setupMemoryWarningObserver() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("⚠️ System memory warning received")
            self?.isMemoryWarning = true
            
            // Reset warning after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
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
            
            // Trigger warning if above threshold
            if usedMemoryMB > self.memoryThresholdMB && !self.isMemoryWarning {
                print("⚠️ Memory threshold exceeded: \(String(format: "%.1f", usedMemoryMB))MB")
                self.isMemoryWarning = true
            } else if usedMemoryMB <= self.memoryThresholdMB {
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