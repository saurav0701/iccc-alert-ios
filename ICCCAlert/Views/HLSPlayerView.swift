import SwiftUI
import WebKit

// MARK: - Player State
enum PlayerState {
    case loading
    case playing
    case paused
    case failed(String)
    case retrying(Int)
}

// MARK: - WebRTC Player (iOS 14+ Compatible)
struct ProductionWebRTCPlayerView: UIViewRepresentable {
    let streamURL: URL
    let cameraId: String
    @Binding var playerState: PlayerState
    @Binding var isLoading: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        DebugLogger.shared.log("🌐 Creating WebRTC player: \(cameraId)", emoji: "🌐", color: .blue)
        DebugLogger.shared.log("   URL: \(streamURL.absoluteString)", emoji: "🔗", color: .blue)
        
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.maximumZoomScale = 1.0
        webView.scrollView.bouncesZoom = false
        
        let request = URLRequest(
            url: streamURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        
        webView.load(request)
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        DebugLogger.shared.log("🗑️ Cleaning up WebRTC player: \(coordinator.cameraId)", emoji: "🗑️", color: .gray)
        uiView.stopLoading()
        uiView.loadHTMLString("", baseURL: nil)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(cameraId: cameraId, playerState: $playerState, isLoading: $isLoading)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        let cameraId: String
        @Binding var playerState: PlayerState
        @Binding var isLoading: Bool
        private var loadTimeout: Timer?
        
        init(cameraId: String, playerState: Binding<PlayerState>, isLoading: Binding<Bool>) {
            self.cameraId = cameraId
            self._playerState = playerState
            self._isLoading = isLoading
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DebugLogger.shared.log("🔄 Loading WebRTC page: \(cameraId)", emoji: "🔄", color: .yellow)
            DispatchQueue.main.async {
                self.playerState = .loading
                self.isLoading = true
            }
            
            loadTimeout?.invalidate()
            loadTimeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                DebugLogger.shared.log("⏰ WebRTC load timeout", emoji: "⏰", color: .red)
                DispatchQueue.main.async {
                    self.playerState = .failed("Connection timeout. Please try again.")
                    self.isLoading = false
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loadTimeout?.invalidate()
            
            DebugLogger.shared.log("✅ WebRTC page loaded: \(cameraId)", emoji: "✅", color: .green)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.playerState = .playing
                self.isLoading = false
                DebugLogger.shared.log("🎥 WebRTC stream playing", emoji: "🎥", color: .green)
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loadTimeout?.invalidate()
            
            DebugLogger.shared.log("❌ WebRTC page failed: \(error.localizedDescription)", emoji: "❌", color: .red)
            DispatchQueue.main.async {
                self.playerState = .failed("Connection failed: \(error.localizedDescription)")
                self.isLoading = false
            }
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loadTimeout?.invalidate()
            
            let nsError = error as NSError
            DebugLogger.shared.log("❌ WebRTC provisional failed", emoji: "❌", color: .red)
            DebugLogger.shared.log("   Code: \(nsError.code)", emoji: "🔢", color: .red)
            DebugLogger.shared.log("   Domain: \(nsError.domain)", emoji: "🔍", color: .red)
            
            let message: String
            switch nsError.code {
            case -1003:
                message = "Camera server not reachable. Check network."
            case -1009:
                message = "No internet connection"
            case -1001:
                message = "Request timeout. Camera may be offline."
            default:
                message = "Cannot connect. Camera may be offline."
            }
            
            DispatchQueue.main.async {
                self.playerState = .failed(message)
                self.isLoading = false
            }
        }
        
        deinit {
            loadTimeout?.invalidate()
        }
    }
}

struct UnifiedCameraPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    
    @StateObject private var pipManager = PiPManager.shared
    @StateObject private var screenshotManager = ScreenshotManager.shared
    @StateObject private var healthMonitor = StreamHealthMonitor.shared
    @StateObject private var bandwidthManager = BandwidthManager.shared
    
    @State private var playerState: PlayerState = .loading
    @State private var showControls = true
    @State private var hideControlsTask: DispatchWorkItem?
    @State private var isLoading = true
    @State private var webView: WKWebView?
    @State private var showScreenshotOptions = false
    @State private var showRecordingIndicator = false
    @State private var playbackSpeed: Float = 1.0
    @State private var selectedQuality: BandwidthManager.StreamQuality = .auto
    @State private var shouldReconnect = false
    @State private var showQualitySelector = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                if let urlString = camera.webrtcStreamURL, let url = URL(string: urlString) {
                    EnhancedWebRTCPlayerView(
                        streamURL: url,
                        cameraId: camera.id,
                        playerState: $playerState,
                        isLoading: $isLoading,
                        webView: $webView
                    )
                    .edgesIgnoringSafeArea(.all)
                } else {
                    errorView(message: "Camera stream not available")
                }
                
                // NEW: Stream status overlay
                VStack {
                    HStack {
                        StreamStatusOverlay(cameraId: camera.id, compact: false)
                            .padding(.top, 60)
                            .padding(.leading, 16)
                        Spacer()
                    }
                    Spacer()
                }
                .opacity(showControls ? 1 : 0)
                
                if isLoading {
                    loadingOverlay
                }
                
                if case .failed(let message) = playerState {
                    failedOverlay(message: message)
                }
                
                // NEW: Reconnecting overlay
                if case .retrying(let attempt) = playerState {
                    ReconnectingOverlay(attempt: attempt, maxAttempts: 3)
                }
                
                if showControls && !isLoading {
                    controlsOverlay(geometry: geometry)
                        .transition(.opacity)
                }
                
                // Screenshot preview
                if screenshotManager.showScreenshotPreview, let screenshot = screenshotManager.lastScreenshot {
                    screenshotPreviewOverlay(screenshot: screenshot)
                }
                
                // Screenshot saved indicator
                if screenshotManager.screenshotSaved {
                    screenshotSavedIndicator
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                // NEW: Quality selector sheet
                if showQualitySelector {
                    Color.black.opacity(0.4)
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture {
                            withAnimation {
                                showQualitySelector = false
                            }
                        }
                    
                    VStack {
                        Spacer()
                        StreamQualitySelector(selectedQuality: $selectedQuality)
                            .padding()
                            .transition(.move(edge: .bottom))
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .onTapGesture {
            withAnimation {
                showControls.toggle()
            }
            if showControls {
                scheduleHideControls()
            }
        }
        .onAppear {
            setupHealthMonitoring()
            applyRecommendedQuality()
            scheduleHideControls()
            logCameraInfo()
        }
        .onDisappear {
            cleanupHealthMonitoring()
        }
        .onChange(of: shouldReconnect) { _ in
            if shouldReconnect {
                reconnectStream()
                shouldReconnect = false
            }
        }
        .statusBar(hidden: true)
    }
    
    // MARK: - Enhanced Controls Overlay
    
    private func controlsOverlay(geometry: GeometryProxy) -> some View {
        VStack {
            // Top controls
            HStack {
                Button(action: { 
                    if pipManager.isPiPActive {
                        pipManager.stopPiP()
                    }
                    presentationMode.wrappedValue.dismiss() 
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                        .shadow(radius: 3)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text(camera.displayName)
                        .font(.headline)
                        .foregroundColor(.white)
                        .shadow(radius: 2)
                        .lineLimit(1)
                        .frame(maxWidth: geometry.size.width * 0.5, alignment: .trailing)
                    
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        
                        Text(camera.area)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text("WebRTC")
                }
                .font(.caption)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.8))
                .cornerRadius(16)
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
                // Action buttons row
                HStack(spacing: 40) {
                    // Screenshot button
                    ControlButton(
                        icon: "camera.fill",
                        label: "Capture",
                        action: captureScreenshot
                    )
                    
                    Spacer()
                    
                    // NEW: Quality button
                    ControlButton(
                        icon: "wand.and.stars",
                        label: "Quality",
                        action: {
                            withAnimation {
                                showQualitySelector.toggle()
                            }
                        }
                    )
                    
                    Spacer()
                    
                    // PiP button
                    ControlButton(
                        icon: pipManager.isPiPActive ? "pip.fill" : "pip",
                        label: "PiP",
                        action: togglePiP
                    )
                }
                .padding(.horizontal, 60)
                
                // LIVE indicator with network badge
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
                    
                    // NEW: Network status badge
                    NetworkStatusBadge()
                    
                    Spacer()
                    
                    // Timestamp
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
            .padding(.bottom, max(20, geometry.safeAreaInsets.bottom))
            .background(
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }
    
    // MARK: - Screenshot Preview Overlay
    
    private func screenshotPreviewOverlay(screenshot: UIImage) -> some View {
        ZStack {
            Color.black.opacity(0.9)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    screenshotManager.dismissPreview()
                }
            
            VStack(spacing: 20) {
                HStack {
                    Text("Screenshot Preview")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Button(action: { screenshotManager.dismissPreview() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal)
                
                Image(uiImage: screenshot)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: UIScreen.main.bounds.height * 0.6)
                    .cornerRadius(12)
                    .shadow(radius: 10)
                
                HStack(spacing: 20) {
                    Button(action: { saveScreenshot(screenshot) }) {
                        VStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.down.fill")
                                .font(.title2)
                            Text("Save")
                                .font(.caption)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(12)
                    }
                    
                    Button(action: { shareScreenshot(screenshot) }) {
                        VStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up.fill")
                                .font(.title2)
                            Text("Share")
                                .font(.caption)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 40)
        }
        .transition(.opacity)
    }
    
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
    
    // MARK: - Loading & Error Views
    
    private var loadingOverlay: some View {
        VStack(spacing: 20) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)
            
            Text("Connecting to camera...")
                .foregroundColor(.white)
                .font(.headline)
            
            Text("Loading WebRTC stream")
                .foregroundColor(.white.opacity(0.7))
                .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.7))
    }
    
    private func failedOverlay(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Connection Failed")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            HStack(spacing: 16) {
                Button(action: { reconnectStream() }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("Close")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
    }
    
    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.red)
            
            Text("Stream Unavailable")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
    
    // MARK: - Helper Methods
    
    private var currentTimestamp: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: Date())
    }
    
    private func setupHealthMonitoring() {
        healthMonitor.registerStream(cameraId: camera.id) { [self] in
            DispatchQueue.main.async {
                self.shouldReconnect = true
            }
        }
        
        DebugLogger.shared.log(
            "✅ Health monitoring enabled for: \(camera.displayName)",
            emoji: "✅",
            color: .green
        )
    }
    
    private func cleanupHealthMonitoring() {
        healthMonitor.unregisterStream(cameraId: camera.id)
        
        DebugLogger.shared.log(
            "🔚 Health monitoring stopped for: \(camera.displayName)",
            emoji: "🔚",
            color: .gray
        )
    }
    
    private func applyRecommendedQuality() {
        selectedQuality = bandwidthManager.getRecommendedQuality(forCameraCount: 1)
        
        DebugLogger.shared.log(
            "🎬 Recommended quality: \(selectedQuality.rawValue) (\(bandwidthManager.currentBandwidth.rawValue))",
            emoji: "🎬",
            color: .blue
        )
    }
    
    private func reconnectStream() {
        let attempts = healthMonitor.streamHealths[camera.id]?.reconnectAttempts ?? 1
        playerState = .retrying(attempts)
        
        DebugLogger.shared.log(
            "🔄 Reconnecting stream (attempt \(attempts)): \(camera.displayName)",
            emoji: "🔄",
            color: .yellow
        )
        
        // Force reload WebView
        if let webView = webView, let urlString = camera.webrtcStreamURL, let url = URL(string: urlString) {
            let request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 30
            )
            webView.load(request)
        }
    }
    
    private func captureScreenshot() {
        guard let webView = webView else {
            DebugLogger.shared.log("⚠️ WebView not available", emoji: "⚠️", color: .orange)
            return
        }
        
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls = false
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            screenshotManager.captureScreenshot(from: webView, camera: camera) { _ in
                let successGenerator = UINotificationFeedbackGenerator()
                successGenerator.notificationOccurred(.success)
            }
        }
    }
    
    private func saveScreenshot(_ image: UIImage) {
        screenshotManager.saveToPhotos(image) { success in
            if success {
                screenshotManager.dismissPreview()
            }
        }
    }
    
    private func shareScreenshot(_ image: UIImage) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            return
        }
        
        screenshotManager.shareScreenshot(image, from: rootViewController)
        screenshotManager.dismissPreview()
    }
    
    private func togglePiP() {
        if pipManager.isPiPActive {
            pipManager.stopPiP()
        } else {
            pipManager.startPiP(camera: camera)
            presentationMode.wrappedValue.dismiss()
        }
    }
    
    private func logCameraInfo() {
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📹", color: .blue)
        DebugLogger.shared.log("📹 Opening Camera (WebRTC)", emoji: "📹", color: .blue)
        DebugLogger.shared.log("   Name: \(camera.displayName)", emoji: "📝", color: .blue)
        DebugLogger.shared.log("   ID: \(camera.id)", emoji: "🆔", color: .blue)
        DebugLogger.shared.log("   IP: \(camera.ip.isEmpty ? "MISSING!" : camera.ip)", emoji: camera.ip.isEmpty ? "⚠️" : "🌐", color: camera.ip.isEmpty ? .red : .blue)
        DebugLogger.shared.log("   Group: \(camera.groupId)", emoji: "👥", color: .blue)
        DebugLogger.shared.log("   WebRTC: \(camera.webrtcStreamURL ?? "nil")", emoji: "🌐", color: camera.webrtcStreamURL != nil ? .green : .red)
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📹", color: .blue)
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
}

struct ControlButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(.white)
                
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.9))
            }
            .frame(width: 70)
        }
    }
}

struct EnhancedWebRTCPlayerView: UIViewRepresentable {
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
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        
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
        coordinator.stopHealthTracking()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(cameraId: cameraId, playerState: $playerState, isLoading: $isLoading)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        let cameraId: String
        @Binding var playerState: PlayerState
        @Binding var isLoading: Bool
        private var loadTimeout: Timer?
        private var healthTrackingTimer: Timer?
        
        init(cameraId: String, playerState: Binding<PlayerState>, isLoading: Binding<Bool>) {
            self.cameraId = cameraId
            self._playerState = playerState
            self._isLoading = isLoading
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.playerState = .loading
                self.isLoading = true
            }
            
            loadTimeout?.invalidate()
            loadTimeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.playerState = .failed("Connection timeout")
                    self.isLoading = false
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loadTimeout?.invalidate()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.playerState = .playing
                self.isLoading = false
                
                // NEW: Start health tracking
                self.startHealthTracking()
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loadTimeout?.invalidate()
            
            DispatchQueue.main.async {
                self.playerState = .failed("Connection failed: \(error.localizedDescription)")
                self.isLoading = false
            }
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loadTimeout?.invalidate()
            
            let nsError = error as NSError
            let message: String
            switch nsError.code {
            case -1003:
                message = "Camera server not reachable"
            case -1009:
                message = "No internet connection"
            case -1001:
                message = "Request timeout"
            default:
                message = "Cannot connect to camera"
            }
            
            DispatchQueue.main.async {
                self.playerState = .failed(message)
                self.isLoading = false
            }
        }
        
        // NEW: Health tracking
        private func startHealthTracking() {
            healthTrackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                // Simulate bitrate (in real app, get from WebRTC stats)
                StreamHealthMonitor.shared.updateStreamPacket(
                    cameraId: self.cameraId,
                    bitrateKbps: Double.random(in: 1200...1800)
                )
            }
        }
        
        func stopHealthTracking() {
            healthTrackingTimer?.invalidate()
            healthTrackingTimer = nil
        }
        
        deinit {
            loadTimeout?.invalidate()
            stopHealthTracking()
        }
    }
}