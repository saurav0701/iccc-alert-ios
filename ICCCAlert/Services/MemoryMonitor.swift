import Foundation
import UIKit

// MARK: - Disabled Memory Monitor (Keep for compatibility, does nothing)
class MemoryMonitor: ObservableObject {
    static let shared = MemoryMonitor()
    
    @Published var currentMemoryMB: Double = 0.0
    @Published var isMemoryWarning: Bool = false
    
    private init() {
        print("💾 MemoryMonitor initialized (DISABLED)")
    }
    
    // These methods do nothing - just kept for compatibility
    func startMonitoring() {
        // Disabled
    }
    
    func stopMonitoring() {
        // Disabled
    }
    
    func forceUpdate() {
        // Disabled
    }
}