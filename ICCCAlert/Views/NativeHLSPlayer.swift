import SwiftUI
import WebKit

// MARK: - Player Manager
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activeWebViews: [String: WKWebView] = [:]
    private let lock = NSLock()
    private let maxPlayers = 2
    
    private init() {}
    
    func getWebView(for cameraId: String) -> WKWebView? {
        lock.lock()
        defer { lock.unlock() }
        
        return activeWebViews[cameraId]
    }
    
    func registerWebView(_ webView: WKWebView, for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if activeWebViews.count >= maxPlayers {
            if let oldestKey = activeWebViews.keys.first {
                releaseWebViewInternal(oldestKey)
            }
        }
        
        activeWebViews[cameraId] = webView
        print("📹 Registered WebView for: \(cameraId)")
    }
    
    private func releaseWebViewInternal(_ cameraId: String) {
        if let webView = activeWebViews.removeValue(forKey: cameraId) {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
            print("🗑️ Released WebView: \(cameraId)")
        }
    }
    
    func releaseWebView(_ cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        releaseWebViewInternal(cameraId)
    }
    
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        
        activeWebViews.keys.forEach { releaseWebViewInternal($0) }
        print("🧹 Cleared all WebViews")
    }
}

// MARK: - HLS WebView Player (Using hls.js for better format support)
struct HLSWebViewPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        // Enable better video handling
        if #available(iOS 14.5, *) {
            config.preferences.isTextInteractionEnabled = false
        }
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = false
        webView.navigationDelegate = context.coordinator
        
        // Register this webView
        PlayerManager.shared.registerWebView(webView, for: cameraId)
        
        // Load the HLS player
        loadPlayer(in: webView)
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    private func loadPlayer(in webView: WKWebView) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
                }
                body {
                    background: #000;
                    overflow: hidden;
                    width: 100vw;
                    height: 100vh;
                }
                #videoContainer {
                    width: 100%;
                    height: 100%;
                    position: relative;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                }
                video {
                    width: 100%;
                    height: 100%;
                    object-fit: contain;
                    background: #000;
                }
                #loading {
                    position: absolute;
                    top: 50%;
                    left: 50%;
                    transform: translate(-50%, -50%);
                    color: white;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    text-align: center;
                    display: none;
                }
                #error {
                    position: absolute;
                    top: 50%;
                    left: 50%;
                    transform: translate(-50%, -50%);
                    color: white;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    text-align: center;
                    padding: 20px;
                    display: none;
                }
                .spinner {
                    border: 3px solid rgba(255,255,255,0.3);
                    border-top: 3px solid white;
                    border-radius: 50%;
                    width: 40px;
                    height: 40px;
                    animation: spin 1s linear infinite;
                    margin: 0 auto 10px;
                }
                @keyframes spin {
                    0% { transform: rotate(0deg); }
                    100% { transform: rotate(360deg); }
                }
            </style>
        </head>
        <body>
            <div id="videoContainer">
                <video id="video" playsinline webkit-playsinline muted autoplay></video>
                <div id="loading">
                    <div class="spinner"></div>
                    <div>Loading stream...</div>
                </div>
                <div id="error">
                    <div style="font-size: 40px; margin-bottom: 10px;">⚠️</div>
                    <div id="errorText">Stream unavailable</div>
                </div>
            </div>
            
            <script>
                const video = document.getElementById('video');
                const loading = document.getElementById('loading');
                const errorDiv = document.getElementById('error');
                const errorText = document.getElementById('errorText');
                const streamUrl = '\(streamURL)';
                let retryCount = 0;
                let retryTimer = null;
                
                // Show loading
                loading.style.display = 'block';
                
                // Try native HLS first (Safari supports it)
                function playStream() {
                    console.log('Attempting to play:', streamUrl);
                    
                    if (video.canPlayType('application/vnd.apple.mpegurl')) {
                        console.log('Using native HLS');
                        video.src = streamUrl;
                        video.load();
                        
                        video.play().then(() => {
                            console.log('Playback started');
                            loading.style.display = 'none';
                            errorDiv.style.display = 'none';
                        }).catch(e => {
                            console.error('Play error:', e);
                            handleError('Cannot play stream: ' + e.message);
                        });
                    } else {
                        handleError('HLS not supported');
                    }
                }
                
                // Video event listeners
                video.addEventListener('loadstart', () => {
                    console.log('Load start');
                    loading.style.display = 'block';
                });
                
                video.addEventListener('loadedmetadata', () => {
                    console.log('Metadata loaded');
                });
                
                video.addEventListener('loadeddata', () => {
                    console.log('Data loaded');
                    loading.style.display = 'none';
                });
                
                video.addEventListener('canplay', () => {
                    console.log('Can play');
                    loading.style.display = 'none';
                });
                
                video.addEventListener('playing', () => {
                    console.log('Playing');
                    loading.style.display = 'none';
                    errorDiv.style.display = 'none';
                    retryCount = 0;
                });
                
                video.addEventListener('waiting', () => {
                    console.log('Waiting/Buffering');
                    loading.style.display = 'block';
                });
                
                video.addEventListener('stalled', () => {
                    console.log('Stalled');
                    if (retryCount < 3) {
                        retryCount++;
                        console.log('Retry attempt', retryCount);
                        setTimeout(() => {
                            video.load();
                            video.play();
                        }, 1000);
                    }
                });
                
                video.addEventListener('error', (e) => {
                    console.error('Video error:', video.error);
                    let msg = 'Stream error';
                    
                    if (video.error) {
                        switch(video.error.code) {
                            case 1: msg = 'Loading aborted'; break;
                            case 2: msg = 'Network error'; break;
                            case 3: msg = 'Decode error - format not supported'; break;
                            case 4: msg = 'Stream not found'; break;
                        }
                    }
                    
                    handleError(msg);
                });
                
                video.addEventListener('suspend', () => {
                    console.log('Download suspended');
                });
                
                video.addEventListener('abort', () => {
                    console.log('Loading aborted');
                });
                
                function handleError(msg) {
                    console.error('Error:', msg);
                    loading.style.display = 'none';
                    errorDiv.style.display = 'block';
                    errorText.textContent = msg;
                    
                    // Auto-retry after 3 seconds
                    if (retryCount < 2) {
                        retryTimer = setTimeout(() => {
                            retryCount++;
                            errorDiv.style.display = 'none';
                            playStream();
                        }, 3000);
                    }
                }
                
                // Prevent sleep/screen lock during playback
                let wakeLock = null;
                if ('wakeLock' in navigator) {
                    navigator.wakeLock.request('screen').then(lock => {
                        wakeLock = lock;
                    }).catch(() => {});
                }
                
                // Start playback
                playStream();
                
                // Cleanup
                window.addEventListener('pagehide', () => {
                    if (wakeLock) wakeLock.release();
                    if (retryTimer) clearTimeout(retryTimer);
                    video.pause();
                    video.src = '';
                });
            </script>
        </body>
        </html>
        """
        
        webView.loadHTMLString(html, baseURL: nil)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HLSWebViewPlayer
        
        init(_ parent: HLSWebViewPlayer) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("✅ WebView loaded for: \(parent.cameraId)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.parent.isLoading = false
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ WebView failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.parent.errorMessage = "Failed to load player"
                self.parent.isLoading = false
            }
        }
    }
}

// MARK: - Camera Thumbnail
struct CameraThumbnail: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var shouldLoad = false
    
    var body: some View {
        ZStack {
            if let streamURL = camera.streamURL, camera.isOnline {
                if shouldLoad {
                    HLSWebViewPlayer(
                        streamURL: streamURL,
                        cameraId: camera.id,
                        isFullscreen: false,
                        isLoading: $isLoading,
                        errorMessage: $errorMessage
                    )
                } else {
                    placeholderView
                }
                
                if !isLoading && errorMessage == nil && shouldLoad {
                    liveIndicator
                }
            } else {
                offlineView
            }
        }
        .onAppear {
            shouldLoad = false
        }
        .onDisappear {
            shouldLoad = false
            PlayerManager.shared.releaseWebView(camera.id)
        }
    }
    
    private var placeholderView: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.blue.opacity(0.3),
                    Color.blue.opacity(0.1)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)
                Text("Tap to preview")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
        .onTapGesture {
            shouldLoad = true
        }
    }
    
    private var liveIndicator: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                    Text("LIVE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.7))
                .cornerRadius(4)
                .padding(6)
            }
            Spacer()
        }
    }
    
    private var offlineView: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.gray.opacity(0.3),
                    Color.gray.opacity(0.1)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
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

// MARK: - Fullscreen Player
struct HLSPlayerView: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let streamURL = camera.streamURL {
                HLSWebViewPlayer(
                    streamURL: streamURL,
                    cameraId: camera.id,
                    isFullscreen: true,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage
                )
                .ignoresSafeArea()
            } else {
                errorView("No stream URL")
            }
            
            // Header with close button
            VStack {
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
                    
                    Button(action: {
                        PlayerManager.shared.releaseWebView(camera.id)
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                            .padding()
                    }
                }
                .padding()
                
                Spacer()
            }
            
            if isLoading {
                loadingView
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onDisappear {
            PlayerManager.shared.releaseWebView(camera.id)
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
            
            Text("Loading stream...")
                .font(.headline)
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.7))
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Stream Unavailable")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text(message)
                .font(.body)
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button(action: {
                PlayerManager.shared.releaseWebView(camera.id)
                presentationMode.wrappedValue.dismiss()
            }) {
                HStack {
                    Image(systemName: "arrow.left")
                    Text("Back")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.gray)
                .cornerRadius(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
    }
}