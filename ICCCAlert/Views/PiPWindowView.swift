import SwiftUI
import WebKit

// MARK: - Picture-in-Picture Window

struct PiPWindowView: View {
    @StateObject private var pipManager = PiPManager.shared
    @StateObject private var screenshotManager = ScreenshotManager.shared
    @GestureState private var dragState = DragState.inactive
    @State private var viewState = CGSize.zero
    @State private var playerState: PlayerState = .loading
    @State private var isLoading = true
    @State private var showControls = false
    @State private var webView: WKWebView?
    @State private var isExpanded = false
    
    private let minSize = CGSize(width: 120, height: 90)
    private let expandedSize = CGSize(width: 280, height: 210)
    
    var body: some View {
        GeometryReader { geometry in
            if pipManager.isPiPActive, let camera = pipManager.currentCamera {
                ZStack(alignment: .topTrailing) {
                    // Player Content
                    ZStack {
                        if let urlString = camera.webrtcStreamURL, let url = URL(string: urlString) {
                            PiPWebRTCPlayer(
                                streamURL: url,
                                cameraId: camera.id,
                                playerState: $playerState,
                                isLoading: $isLoading,
                                webView: $webView
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            placeholderView
                        }
                        
                        // Loading indicator
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        }
                        
                        // Controls overlay (when expanded)
                        if isExpanded && !isLoading {
                            controlsOverlay(camera: camera, geometry: geometry)
                        }
                    }
                    .frame(width: currentSize.width, height: currentSize.height)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black)
                            .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 6)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    )
                    .position(
                        x: position(in: geometry).x + currentSize.width / 2,
                        y: position(in: geometry).y + currentSize.height / 2
                    )
                    .gesture(
                        DragGesture()
                            .updating($dragState) { value, state, _ in
                                state = .dragging(translation: value.translation)
                            }
                            .onEnded { value in
                                viewState.width += value.translation.width
                                viewState.height += value.translation.height
                                
                                // Save position
                                let finalPos = constrainedPosition(in: geometry)
                                pipManager.updatePosition(finalPos)
                            }
                    )
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            isExpanded.toggle()
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
    
    // MARK: - Computed Properties
    
    private var currentSize: CGSize {
        isExpanded ? expandedSize : minSize
    }
    
    private func position(in geometry: GeometryProxy) -> CGPoint {
        let dragOffset = dragState.translation
        let basePosition: CGPoint
        
        if viewState == .zero {
            // Default position: bottom-right
            basePosition = CGPoint(
                x: geometry.size.width - minSize.width - 20,
                y: geometry.size.height - minSize.height - 100
            )
        } else {
            basePosition = CGPoint(
                x: viewState.width,
                y: viewState.height
            )
        }
        
        let newPosition = CGPoint(
            x: basePosition.x + dragOffset.width,
            y: basePosition.y + dragOffset.height
        )
        
        return constrain(position: newPosition, in: geometry)
    }
    
    private func constrainedPosition(in geometry: GeometryProxy) -> CGPoint {
        return constrain(
            position: CGPoint(x: viewState.width, y: viewState.height),
            in: geometry
        )
    }
    
    private func constrain(position: CGPoint, in geometry: GeometryProxy) -> CGPoint {
        let padding: CGFloat = 10
        
        let maxX = geometry.size.width - currentSize.width - padding
        let maxY = geometry.size.height - currentSize.height - padding
        
        return CGPoint(
            x: min(max(position.x, padding), maxX),
            y: min(max(position.y, padding), maxY)
        )
    }
    
    // MARK: - Controls Overlay
    
    private func controlsOverlay(camera: Camera, geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // Top controls
            HStack(spacing: 8) {
                // Camera name
                Text(camera.displayName)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                Spacer()
                
                // Close button
                Button(action: { pipManager.stopPiP() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.7), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            
            Spacer()
            
            // Bottom controls
            HStack(spacing: 12) {
                // Screenshot button
                Button(action: { captureScreenshot(camera: camera) }) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())
                }
                
                Spacer()
                
                // Expand to fullscreen
                Button(action: { 
                    // This will be handled by navigation
                    NotificationCenter.default.post(
                        name: NSNotification.Name("OpenCameraFullscreen"),
                        object: camera
                    )
                }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }
    
    // MARK: - Placeholder View
    
    private var placeholderView: some View {
        VStack {
            Image(systemName: "video.slash")
                .font(.title3)
                .foregroundColor(.white.opacity(0.6))
            Text("No Stream")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
        }
    }
    
    // MARK: - Screenshot Capture
    
    private func captureScreenshot(camera: Camera) {
        guard let webView = webView else {
            DebugLogger.shared.log("⚠️ WebView not available for screenshot", emoji: "⚠️", color: .orange)
            return
        }
        
        screenshotManager.captureScreenshot(from: webView, camera: camera) { image in
            if image != nil {
                // Haptic feedback
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
            }
        }
    }
}

// MARK: - Drag State

enum DragState {
    case inactive
    case dragging(translation: CGSize)
    
    var translation: CGSize {
        switch self {
        case .inactive:
            return .zero
        case .dragging(let translation):
            return translation
        }
    }
    
    var isDragging: Bool {
        switch self {
        case .inactive:
            return false
        case .dragging:
            return true
        }
    }
}

// MARK: - PiP WebRTC Player

struct PiPWebRTCPlayer: UIViewRepresentable {
    let streamURL: URL
    let cameraId: String
    @Binding var playerState: PlayerState
    @Binding var isLoading: Bool
    @Binding var webView: WKWebView?
    
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.navigationDelegate = context.coordinator
        
        let request = URLRequest(
            url: streamURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        
        webView.load(request)
        
        DispatchQueue.main.async {
            self.webView = webView
        }
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.loadHTMLString("", baseURL: nil)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(playerState: $playerState, isLoading: $isLoading)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var playerState: PlayerState
        @Binding var isLoading: Bool
        
        init(playerState: Binding<PlayerState>, isLoading: Binding<Bool>) {
            self._playerState = playerState
            self._isLoading = isLoading
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.playerState = .playing
                self.isLoading = false
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.playerState = .failed("Connection failed")
                self.isLoading = false
            }
        }
    }
}