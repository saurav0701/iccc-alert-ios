import SwiftUI
import UIKit

// MARK: - App Delegate for Orientation Support
class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.portrait
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
}

// MARK: - Orientation Manager
class OrientationManager: ObservableObject {
    static let shared = OrientationManager()
    
    @Published var currentOrientation: UIDeviceOrientation = .portrait
    
    private init() {
        setupOrientationObserver()
    }
    
    private func setupOrientationObserver() {
        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.currentOrientation = UIDevice.current.orientation
        }
    }
    
    func lockOrientation(_ orientation: UIInterfaceOrientationMask) {
        AppDelegate.orientationLock = orientation
    }
    
    func unlockOrientation() {
        AppDelegate.orientationLock = .all
    }
    
    func rotateToLandscape() {
        lockOrientation(.landscape)
        UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    }
    
    func rotateToPortrait() {
        lockOrientation(.portrait)
        UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

// MARK: - Landscape View Modifier
struct LandscapeModifier: ViewModifier {
    @StateObject private var orientationManager = OrientationManager.shared
    let allowLandscape: Bool
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                if allowLandscape {
                    orientationManager.unlockOrientation()
                }
            }
            .onDisappear {
                if allowLandscape {
                    orientationManager.rotateToPortrait()
                }
            }
    }
}

extension View {
    func supportLandscape(_ allow: Bool = true) -> some View {
        modifier(LandscapeModifier(allowLandscape: allow))
    }
}

// MARK: - Device Orientation Extension
extension UIDeviceOrientation {
    var isLandscape: Bool {
        return self == .landscapeLeft || self == .landscapeRight
    }
    
    var isPortrait: Bool {
        return self == .portrait || self == .portraitUpsideDown
    }
}

// MARK: - Updated FullscreenPlayerView with Proper Orientation Support
struct LandscapeFullscreenPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var orientationManager = OrientationManager.shared
    @State private var showControls = true
    @State private var preferredOrientation: UIInterfaceOrientationMask = .portrait
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                
                if let url = camera.webrtcStreamURL {
                    WebRTCPlayerView(streamURL: url, cameraId: camera.id, isFullscreen: true)
                        .ignoresSafeArea()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .onTapGesture {
                            withAnimation { showControls.toggle() }
                        }
                }
                
                if showControls {
                    controlsOverlay(geometry: geometry)
                }
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
        .supportLandscape(true)
        .onAppear {
            orientationManager.unlockOrientation()
        }
        .onDisappear {
            PlayerManager.shared.releasePlayer(camera.id)
            orientationManager.rotateToPortrait()
        }
    }
    
    private func controlsOverlay(geometry: GeometryProxy) -> some View {
        VStack {
            // Top Controls
            HStack {
                Button(action: {
                    PlayerManager.shared.releasePlayer(camera.id)
                    orientationManager.rotateToPortrait()
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Back")
                            .font(.headline)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(10)
                }
                
                Spacer()
                
                // Orientation Toggle
                Button(action: toggleOrientation) {
                    Image(systemName: isCurrentlyLandscape ? "rectangle.portrait" : "rectangle.landscape")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(10)
                }
            }
            .padding()
            
            Spacer()
            
            // Bottom Info
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(camera.displayName)
                        .font(.headline)
                        .foregroundColor(.white)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(camera.isOnline ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(camera.area)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding()
                .background(Color.black.opacity(0.6))
                .cornerRadius(10)
                
                Spacer()
            }
            .padding()
        }
        .transition(.opacity)
    }
    
    private var isCurrentlyLandscape: Bool {
        let orientation = orientationManager.currentOrientation
        return orientation.isLandscape || UIDevice.current.orientation.isLandscape
    }
    
    private func toggleOrientation() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        if isCurrentlyLandscape {
            orientationManager.rotateToPortrait()
        } else {
            orientationManager.rotateToLandscape()
        }
        
        // Hide controls briefly during rotation
        showControls = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            showControls = true
        }
    }
}