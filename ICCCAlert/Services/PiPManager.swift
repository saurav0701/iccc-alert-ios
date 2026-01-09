import Foundation
import SwiftUI
import Combine

// MARK: - Picture-in-Picture Manager

class PiPManager: ObservableObject {
    static let shared = PiPManager()
    
    @Published var isPiPActive = false
    @Published var currentCamera: Camera?
    @Published var pipPosition: CGPoint = .zero
    @Published var pipSize: CGSize = CGSize(width: 120, height: 90)
    
    private var dragOffset: CGSize = .zero
    
    private init() {
        // Load saved PiP settings
        loadPiPSettings()
    }
    
    // MARK: - PiP Control
    
    func startPiP(camera: Camera) {
        currentCamera = camera
        isPiPActive = true
        
        DebugLogger.shared.log("🎬 Started PiP for: \(camera.displayName)", emoji: "🎬", color: .green)
    }
    
    func stopPiP() {
        isPiPActive = false
        currentCamera = nil
        
        DebugLogger.shared.log("⏹️ Stopped PiP", emoji: "⏹️", color: .gray)
    }
    
    func togglePiP() {
        if isPiPActive {
            stopPiP()
        }
    }
    
    // MARK: - Position Management
    
    func updatePosition(_ position: CGPoint) {
        pipPosition = position
        savePiPSettings()
    }
    
    func updateSize(_ size: CGSize) {
        pipSize = size
        savePiPSettings()
    }
    
    // MARK: - Persistence
    
    private func savePiPSettings() {
        UserDefaults.standard.set(pipPosition.x, forKey: "pip_position_x")
        UserDefaults.standard.set(pipPosition.y, forKey: "pip_position_y")
        UserDefaults.standard.set(pipSize.width, forKey: "pip_size_width")
        UserDefaults.standard.set(pipSize.height, forKey: "pip_size_height")
    }
    
    private func loadPiPSettings() {
        let x = UserDefaults.standard.double(forKey: "pip_position_x")
        let y = UserDefaults.standard.double(forKey: "pip_position_y")
        let width = UserDefaults.standard.double(forKey: "pip_size_width")
        let height = UserDefaults.standard.double(forKey: "pip_size_height")
        
        if width > 0 && height > 0 {
            pipSize = CGSize(width: width, height: height)
        }
        
        if x > 0 || y > 0 {
            pipPosition = CGPoint(x: x, y: y)
        }
    }
}