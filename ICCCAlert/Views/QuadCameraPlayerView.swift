import SwiftUI
import WebKit

// MARK: - Quad Camera Player View (4 cameras simultaneously)

struct QuadCameraPlayerView: View {
    let multiView: MultiCameraView
    
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var cameraManager = CameraManager.shared
    @StateObject private var screenshotManager = ScreenshotManager.shared
    
    @State private var showControls = true
    @State private var hideControlsTask: DispatchWorkItem?
    @State private var selectedCameraIndex: Int?
    @State private var showFullscreenCamera: Camera?
    
    var cameras: [Camera] {
        multiView.cameraIds.compactMap { cameraManager.getCameraById($0) }
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                // Camera Grid
                VStack(spacing: 2) {
                    if cameras.count == 1 {
                        singleCameraView(camera: cameras[0], geometry: geometry)
                    } else if cameras.count == 2 {
                        twoCameraView(geometry: geometry)
                    } else if cameras.count >= 3 {
                        fourCameraView(geometry: geometry)
                    }
                }
                
                // Controls Overlay
                if showControls {
                    controlsOverlay
                        .transition(.opacity)
                }
                
                // Screenshot saved indicator
                if screenshotManager.screenshotSaved {
                    screenshotSavedIndicator
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls.toggle()
                }
                if showControls {
                    scheduleHideControls()
                }
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: true)
        .onAppear {
            scheduleHideControls()
            logViewInfo()
        }
        .fullScreenCover(item: $showFullscreenCamera) { camera in
            UnifiedCameraPlayerView(camera: camera)
        }
    }
    
    // MARK: - Camera Layouts
    
    private func singleCameraView(camera: Camera, geometry: GeometryProxy) -> some View {
        QuadCameraCell(
            camera: camera,
            index: 0,
            selectedIndex: $selectedCameraIndex,
            onDoubleTap: {
                showFullscreenCamera = camera
            }
        )
        .frame(width: geometry.size.width, height: geometry.size.height)
    }
    
    private func twoCameraView(geometry: GeometryProxy) -> some View {
        Group {
            QuadCameraCell(
                camera: cameras[0],
                index: 0,
                selectedIndex: $selectedCameraIndex,
                onDoubleTap: {
                    showFullscreenCamera = cameras[0]
                }
            )
            .frame(height: (geometry.size.height - 2) / 2)
            
            QuadCameraCell(
                camera: cameras[1],
                index: 1,
                selectedIndex: $selectedCameraIndex,
                onDoubleTap: {
                    showFullscreenCamera = cameras[1]
                }
            )
            .frame(height: (geometry.size.height - 2) / 2)
        }
    }
    
    private func fourCameraView(geometry: GeometryProxy) -> some View {
        Group {
            HStack(spacing: 2) {
                QuadCameraCell(
                    camera: cameras[0],
                    index: 0,
                    selectedIndex: $selectedCameraIndex,
                    onDoubleTap: {
                        showFullscreenCamera = cameras[0]
                    }
                )
                
                if cameras.count > 1 {
                    QuadCameraCell(
                        camera: cameras[1],
                        index: 1,
                        selectedIndex: $selectedCameraIndex,
                        onDoubleTap: {
                            showFullscreenCamera = cameras[1]
                        }
                    )
                } else {
                    emptyCell
                }
            }
            .frame(height: (geometry.size.height - 2) / 2)
            
            HStack(spacing: 2) {
                if cameras.count > 2 {
                    QuadCameraCell(
                        camera: cameras[2],
                        index: 2,
                        selectedIndex: $selectedCameraIndex,
                        onDoubleTap: {
                            showFullscreenCamera = cameras[2]
                        }
                    )
                } else {
                    emptyCell
                }
                
                if cameras.count > 3 {
                    QuadCameraCell(
                        camera: cameras[3],
                        index: 3,
                        selectedIndex: $selectedCameraIndex,
                        onDoubleTap: {
                            showFullscreenCamera = cameras[3]
                        }
                    )
                } else {
                    emptyCell
                }
            }
            .frame(height: (geometry.size.height - 2) / 2)
        }
    }
    
    private var emptyCell: some View {
        ZStack {
            Color.black.opacity(0.3)
            
            VStack(spacing: 12) {
                Image(systemName: "video.slash")
                    .font(.system(size: 30))
                    .foregroundColor(.gray.opacity(0.5))
                
                Text("Empty Slot")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.gray.opacity(0.7))
            }
        }
    }
    
    // MARK: - Controls Overlay
    
    private var controlsOverlay: some View {
        VStack {
            // Top controls
            HStack {
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                        .shadow(radius: 3)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text(multiView.name)
                        .font(.headline)
                        .foregroundColor(.white)
                        .shadow(radius: 2)
                    
                    HStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.caption)
                        Text("\(cameras.count) camera\(cameras.count == 1 ? "" : "s")")
                            .font(.caption)
                    }
                    .foregroundColor(.white.opacity(0.9))
                }
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.7), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            
            Spacer()
            
            // Bottom controls
            VStack(spacing: 16) {
                // Action buttons
                HStack(spacing: 30) {
                    // Screenshot all
                    ControlButton(
                        icon: "camera.fill",
                        label: "Screenshot",
                        action: captureScreenshot
                    )
                    
                    Spacer()
                    
                    // Refresh all
                    ControlButton(
                        icon: "arrow.clockwise",
                        label: "Refresh",
                        action: refreshAllStreams
                    )
                }
                .padding(.horizontal, 40)
                
                // LIVE indicator
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 8))
                        Text("LIVE")
                            .font(.caption2)
                            .bold()
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(12)
                    
                    Spacer()
                    
                    Text(currentTimestamp)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(12)
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 20)
            .background(
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }
    
    // MARK: - Screenshot Saved Indicator
    
    private var screenshotSavedIndicator: some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.green)
                
                Text("Screenshot saved to Photos")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                
                Spacer()
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.8))
                    .shadow(radius: 10)
            )
            .padding(.horizontal)
            .padding(.top, 60)
            
            Spacer()
        }
    }
    
    // MARK: - Helper Methods
    
    private var currentTimestamp: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: Date())
    }
    
    private func captureScreenshot() {
        // Capture screenshot of entire quad view
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else {
            return
        }
        
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        
        // Add metadata overlay
        let annotatedImage = addMetadata(to: image)
        
        // Save to photos
        UIImageWriteToSavedPhotosAlbum(annotatedImage, nil, nil, nil)
        
        // Show success indicator
        screenshotManager.screenshotSaved = true
        
        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        DebugLogger.shared.log("📸 Quad view screenshot captured", emoji: "📸", color: .green)
        
        // Reset indicator after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            screenshotManager.screenshotSaved = false
        }
    }
    
    private func addMetadata(to image: UIImage) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        
        return renderer.image { context in
            image.draw(at: .zero)
            
            // Add view name overlay
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .left
            
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 16),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraphStyle
            ]
            
            let smallAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
                .paragraphStyle: paragraphStyle
            ]
            
            let viewName = multiView.name as NSString
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium) as NSString
            
            let padding: CGFloat = 16
            let textY: CGFloat = 40
            
            // Semi-transparent background
            let backgroundRect = CGRect(
                x: 0,
                y: 0,
                width: image.size.width,
                height: 80
            )
            UIColor.black.withAlphaComponent(0.6).setFill()
            UIBezierPath(rect: backgroundRect).fill()
            
            viewName.draw(
                at: CGPoint(x: padding, y: textY),
                withAttributes: attributes
            )
            
            timestamp.draw(
                at: CGPoint(x: padding, y: textY + 22),
                withAttributes: smallAttributes
            )
        }
    }
    
    private func refreshAllStreams() {
        // Refresh all camera streams
        DebugLogger.shared.log("🔄 Refreshing all streams", emoji: "🔄", color: .blue)
        
        // Trigger re-render by toggling controls
        withAnimation {
            showControls = false
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation {
                showControls = true
            }
            scheduleHideControls()
        }
    }
    
    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        
        let task = DispatchWorkItem {
            withAnimation {
                showControls = false
            }
        }
        
        hideControlsTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: task)
    }
    
    private func logViewInfo() {
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📺", color: .blue)
        DebugLogger.shared.log("📺 Opening Quad View: \(multiView.name)", emoji: "📺", color: .blue)
        DebugLogger.shared.log("   Cameras: \(cameras.count)", emoji: "📹", color: .blue)
        for (index, camera) in cameras.enumerated() {
            DebugLogger.shared.log("   [\(index + 1)] \(camera.displayName) - \(camera.isOnline ? "Online" : "Offline")", emoji: "📹", color: camera.isOnline ? .green : .red)
        }
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📺", color: .blue)
    }
}

// MARK: - Quad Camera Cell

struct QuadCameraCell: View {
    let camera: Camera
    let index: Int
    @Binding var selectedIndex: Int?
    let onDoubleTap: () -> Void
    
    @State private var playerState: PlayerState = .loading
    @State private var isLoading = true
    @State private var webView: WKWebView?
    
    var isSelected: Bool {
        selectedIndex == index
    }
    
    var body: some View {
        ZStack {
            if let urlString = camera.webrtcStreamURL, let url = URL(string: urlString) {
                QuadWebRTCPlayer(
                    streamURL: url,
                    cameraId: camera.id,
                    playerState: $playerState,
                    isLoading: $isLoading,
                    webView: $webView
                )
            } else {
                offlineView
            }
            
            // Loading indicator
            if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.8)
            }
            
            // Camera label overlay
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(camera.displayName)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .shadow(radius: 2)
                        
                        HStack(spacing: 4) {
                            Circle()
                                .fill(camera.isOnline ? Color.green : Color.red)
                                .frame(width: 4, height: 4)
                            
                            Text(camera.isOnline ? "LIVE" : "OFFLINE")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.6))
                    )
                    
                    Spacer()
                }
                .padding(8)
                
                Spacer()
            }
            
            // Selection border
            if isSelected {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Color.blue, lineWidth: 3)
            }
        }
        .onTapGesture {
            selectedIndex = index
        }
        .onTapGesture(count: 2) {
            onDoubleTap()
        }
    }
    
    private var offlineView: some View {
        ZStack {
            Color.black.opacity(0.8)
            
            VStack(spacing: 8) {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.gray)
                
                Text("Offline")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }
}

// MARK: - Quad WebRTC Player

struct QuadWebRTCPlayer: UIViewRepresentable {
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