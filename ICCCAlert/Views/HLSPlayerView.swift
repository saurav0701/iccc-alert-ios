import SwiftUI
import WebKit

// MARK: - WebView HLS Player (Replaces AVPlayer)
struct WebViewHLSPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraName: String
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * { margin: 0; padding: 0; }
                body { 
                    background: #000;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    height: 100vh;
                    overflow: hidden;
                }
                video {
                    width: 100%;
                    height: 100%;
                    object-fit: contain;
                }
                .error {
                    color: white;
                    text-align: center;
                    padding: 20px;
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                }
            </style>
        </head>
        <body>
            <video id="player" autoplay playsinline muted controls></video>
            <script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
            <script>
                const video = document.getElementById('player');
                const videoSrc = '\(streamURL)';
                
                if (Hls.isSupported()) {
                    const hls = new Hls({
                        enableWorker: true,
                        lowLatencyMode: true,
                        backBufferLength: 90
                    });
                    
                    hls.loadSource(videoSrc);
                    hls.attachMedia(video);
                    
                    hls.on(Hls.Events.MANIFEST_PARSED, function() {
                        video.play().catch(e => console.log('Play error:', e));
                        window.webkit.messageHandlers.streamReady.postMessage('ready');
                    });
                    
                    hls.on(Hls.Events.ERROR, function(event, data) {
                        if (data.fatal) {
                            window.webkit.messageHandlers.streamError.postMessage(data.type + ': ' + data.details);
                        }
                    });
                } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                    video.src = videoSrc;
                    video.addEventListener('loadedmetadata', function() {
                        video.play();
                        window.webkit.messageHandlers.streamReady.postMessage('ready');
                    });
                    video.addEventListener('error', function() {
                        window.webkit.messageHandlers.streamError.postMessage('Native playback error');
                    });
                }
            </script>
        </body>
        </html>
        """
        
        webView.loadHTMLString(html, baseURL: nil)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebViewHLSPlayer
        
        init(_ parent: WebViewHLSPlayer) {
            self.parent = parent
            super.init()
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            DispatchQueue.main.async {
                if message.name == "streamReady" {
                    self.parent.isLoading = false
                    self.parent.errorMessage = nil
                } else if message.name == "streamError" {
                    self.parent.isLoading = false
                    self.parent.errorMessage = message.body as? String ?? "Stream error"
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Add message handlers
            webView.configuration.userContentController.add(self, name: "streamReady")
            webView.configuration.userContentController.add(self, name: "streamError")
        }
    }
}

// MARK: - Updated HLS Player View
struct HLSPlayerView: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String?
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let streamURL = camera.streamURL {
                WebViewHLSPlayer(
                    streamURL: streamURL,
                    cameraName: camera.displayName,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage
                )
                .ignoresSafeArea()
            } else {
                errorView("Stream URL not available")
            }
            
            // Loading overlay
            if isLoading {
                loadingView
            }
            
            // Header overlay
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(camera.displayName)
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        HStack(spacing: 8) {
                            Text(camera.area)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                            
                            Circle()
                                .fill(camera.isOnline ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            
                            Text(camera.isOnline ? "Live" : "Offline")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .padding()
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(10)
                    
                    Spacer()
                    
                    Button(action: {
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
            
            // Error view
            if let error = errorMessage {
                errorView(error)
            }
        }
        .navigationBarHidden(true)
    }
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            
            Text("Loading stream...")
                .font(.headline)
                .foregroundColor(.white)
            
            Text(camera.displayName)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.8))
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Stream Error")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text(message)
                .font(.body)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button(action: {
                errorMessage = nil
                isLoading = true
            }) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.blue)
                .cornerRadius(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.8))
    }
}