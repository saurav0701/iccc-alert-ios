import SwiftUI
import WebKit

// MARK: - WebRTC Player using WebKit
struct WebRTCPlayerView: UIViewRepresentable {
    let streamURL: URL
    let cameraId: String
    let onError: ((Error) -> Void)?
    
    func makeUIViewController(context: Context) -> WKWebViewController {
        let controller = WKWebViewController(streamURL: streamURL, cameraId: cameraId)
        controller.onError = onError
        return controller
    }
    
    func updateUIViewController(_ uiViewController: WKWebViewController, context: Context) {}
    
    static func dismantleUIViewController(_ uiViewController: WKWebViewController, coordinator: ()) {
        uiViewController.cleanup()
    }
}

// MARK: - WebRTC WebKit Controller
class WKWebViewController: UIViewController {
    private var webView: WKWebView!
    private let streamURL: URL
    private let cameraId: String
    var onError: ((Error) -> Void)?
    
    init(streamURL: URL, cameraId: String) {
        self.streamURL = streamURL
        self.cameraId = cameraId
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .black
        
        // Create WebKit configuration
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        
        // Enable media capture permissions
        if #available(iOS 15.0, *) {
            config.mediaTypesRequiringUserActionForPlayback = []
        }
        
        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.backgroundColor = .black
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)
        
        // Load WebRTC HTML page
        loadWebRTCPage()
    }
    
    private func loadWebRTCPage() {
        let htmlContent = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>WebRTC Stream</title>
            <style>
                body {
                    margin: 0;
                    padding: 0;
                    background-color: black;
                    font-family: Arial, sans-serif;
                    overflow: hidden;
                }
                
                #videoContainer {
                    width: 100vw;
                    height: 100vh;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    background-color: black;
                }
                
                video {
                    width: 100%;
                    height: 100%;
                    object-fit: contain;
                    background-color: black;
                }
                
                #status {
                    position: absolute;
                    top: 10px;
                    left: 10px;
                    color: white;
                    font-size: 14px;
                    background-color: rgba(0, 0, 0, 0.7);
                    padding: 10px;
                    border-radius: 5px;
                }
                
                #error {
                    position: absolute;
                    top: 10px;
                    right: 10px;
                    color: red;
                    font-size: 14px;
                    background-color: rgba(0, 0, 0, 0.9);
                    padding: 10px;
                    border-radius: 5px;
                    max-width: 300px;
                }
            </style>
        </head>
        <body>
            <div id="videoContainer">
                <video id="video" autoplay playsinline controls></video>
            </div>
            <div id="status">Loading...</div>
            <div id="error"></div>
            
            <script>
                const VIDEO_URL = '\(streamURL.absoluteString)';
                const video = document.getElementById('video');
                const statusDiv = document.getElementById('status');
                const errorDiv = document.getElementById('error');
                let reconnectAttempts = 0;
                const MAX_RECONNECT = 6;
                
                async function startStream() {
                    try {
                        statusDiv.textContent = 'Connecting to stream...';
                        errorDiv.textContent = '';
                        
                        // Try to fetch the stream
                        const response = await fetch(VIDEO_URL);
                        
                        if (!response.ok) {
                            throw new Error(`HTTP error! status: ${response.status}`);
                        }
                        
                        const blob = await response.blob();
                        const objectUrl = URL.createObjectURL(blob);
                        
                        video.src = objectUrl;
                        video.play();
                        
                        statusDiv.textContent = '✅ Connected';
                        reconnectAttempts = 0;
                        
                    } catch (error) {
                        console.error('Stream error:', error);
                        handleStreamError(error);
                    }
                }
                
                function handleStreamError(error) {
                    reconnectAttempts++;
                    const message = `Error: ${error.message}`;
                    errorDiv.textContent = message;
                    statusDiv.textContent = `Retrying... (${reconnectAttempts}/${MAX_RECONNECT})`;
                    
                    if (reconnectAttempts < MAX_RECONNECT) {
                        const delay = Math.min(Math.pow(2, reconnectAttempts), 60) * 1000;
                        console.log(`Reconnecting in ${delay/1000}s...`);
                        setTimeout(startStream, delay);
                    } else {
                        statusDiv.textContent = '❌ Stream unavailable';
                        errorDiv.textContent = 'Max retries reached';
                    }
                }
                
                // Handle video play events
                video.addEventListener('play', () => {
                    console.log('Video started playing');
                    statusDiv.textContent = '▶️ Playing';
                });
                
                video.addEventListener('pause', () => {
                    console.log('Video paused');
                    statusDiv.textContent = '⏸️ Paused';
                });
                
                video.addEventListener('ended', () => {
                    console.log('Video ended, reconnecting...');
                    if (reconnectAttempts < MAX_RECONNECT) {
                        startStream();
                    }
                });
                
                video.addEventListener('error', (e) => {
                    console.error('Video error:', e);
                    handleStreamError(new Error('Video playback error'));
                });
                
                // Start stream on load
                window.addEventListener('load', startStream);
                startStream();
            </script>
        </body>
        </html>
        """
        
        webView.loadHTMLString(htmlContent, baseURL: nil)
    }
    
    func cleanup() {
        webView.stopLoading()
        webView.configuration.userContentController.removeAllUserScripts()
    }
    
    deinit {
        cleanup()
    }
}
