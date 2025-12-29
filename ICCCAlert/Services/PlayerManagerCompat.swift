import Foundation

class PlayerManager {
    static let shared = PlayerManager()
    
    private init() {}
    
    func clearAll() {
        // Delegate to NativePlayerManager
        NativePlayerManager.shared.clearAll()
    }
    
    func releaseWebView(_ cameraId: String) {
        // Delegate to NativePlayerManager
        NativePlayerManager.shared.releasePlayer(cameraId)
    }
}