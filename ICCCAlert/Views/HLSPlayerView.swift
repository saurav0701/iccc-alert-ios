// HLSPlayerView.swift
// Renamed but now contains WebRTC-only implementation

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

// MARK: - Unified Camera Player (WebRTC Only)
struct UnifiedCameraPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    
    @State private var playerState: PlayerState = .loading
    @State private var showControls = true
    @State private var hideControlsTask: DispatchWorkItem?
    @State private var isLoading = true
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if let urlString = camera.webrtcStreamURL, let url = URL(string: urlString) {
                ProductionWebRTCPlayerView(
                    streamURL: url,
                    cameraId: camera.id,
                    playerState: $playerState,
                    isLoading: $isLoading
                )
                .edgesIgnoringSafeArea(.all)
            } else {
                errorView(message: "Camera stream not available")
            }
            
            if isLoading {
                loadingOverlay
            }
            
            if case .failed(let message) = playerState {
                failedOverlay(message: message)
            }
            
            if showControls && !isLoading {
                controlsOverlay
                    .transition(.opacity)
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
            scheduleHideControls()
            logCameraInfo()
        }
        .statusBar(hidden: true)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
    }
    
    private var controlsOverlay: some View {
        VStack {
            HStack {
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
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
                    
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        
                        Text(camera.area)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.9))
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
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
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