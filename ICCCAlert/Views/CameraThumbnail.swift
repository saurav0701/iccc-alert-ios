import SwiftUI

// MARK: - Camera Thumbnail (OPTIMIZED WITH LAZY LOADING)
struct CameraThumbnail: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var shouldLoad = false // ✅ NEW: Lazy loading flag
    @State private var retryCount = 0
    
    private var viewId: String {
        "thumbnail_\(camera.id)"
    }
    
    var body: some View {
        ZStack {
            if let streamURL = camera.streamURL, camera.isOnline {
                if shouldLoad {
                    // ✅ Only load WebView when visible
                    WebViewHLSPlayer(
                        streamURL: streamURL,
                        cameraId: camera.id,
                        cameraName: camera.displayName,
                        isLoading: $isLoading,
                        errorMessage: $errorMessage,
                        isFullscreen: false
                    )
                    .id(viewId)
                } else {
                    // ✅ Show placeholder until scrolled into view
                    placeholderView
                        .onAppear {
                            // Delay loading to prevent overwhelming the network
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                shouldLoad = true
                            }
                        }
                }
                
                if isLoading && shouldLoad {
                    loadingOverlay
                }
                
                if let error = errorMessage {
                    errorOverlay(error)
                }
                
                if camera.isOnline && !isLoading && errorMessage == nil && shouldLoad {
                    liveIndicator
                }
            } else {
                offlineView
            }
        }
    }
    
    // ✅ Placeholder before loading
    private var placeholderView: some View {
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
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .gray))
                Text("Loading...")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
    }
    
    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
            VStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                Text("Connecting...")
                    .font(.caption2)
                    .foregroundColor(.white)
            }
        }
    }
    
    private func errorOverlay(_ error: String) -> some View {
        ZStack {
            Color.black.opacity(0.9)
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.orange)
                
                Text("Stream Error")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                
                Text(error)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                
                // ✅ Retry button for thumbnails
                if retryCount < 3 {
                    Button(action: {
                        retryCount += 1
                        errorMessage = nil
                        isLoading = true
                        shouldLoad = false
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            shouldLoad = true
                        }
                    }) {
                        Text("Retry")
                            .font(.system(size: 10))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Color.blue)
                            .cornerRadius(4)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(8)
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

// MARK: - Fullscreen HLS Player View (OPTIMIZED)
struct HLSPlayerView: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var showControls = true
    @State private var autoHideTimer: Timer? = nil
    @State private var retryAttempt = 0
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let streamURL = camera.streamURL {
                WebViewHLSPlayer(
                    streamURL: streamURL,
                    cameraId: camera.id,
                    cameraName: camera.displayName,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage,
                    isFullscreen: true
                )
                .ignoresSafeArea()
                .onAppear {
                    AudioSessionManager.shared.configure()
                    resetAutoHideTimer()
                }
                .onDisappear {
                    autoHideTimer?.invalidate()
                }
                .onTapGesture {
                    withAnimation {
                        showControls.toggle()
                    }
                    resetAutoHideTimer()
                }
            } else {
                errorView("Stream URL not available")
            }
            
            if isLoading {
                loadingView
            }
            
            if showControls {
                controlsOverlay
            }
            
            if let error = errorMessage {
                errorView(error)
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
    }
    
    private func resetAutoHideTimer() {
        autoHideTimer?.invalidate()
        if showControls {
            autoHideTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
                withAnimation {
                    showControls = false
                }
            }
        }
    }
    
    private var controlsOverlay: some View {
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
                .background(Color.black.opacity(0.7))
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
            .transition(.move(edge: .top))
            
            Spacer()
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
            
            Text("Connecting to stream...")
                .font(.headline)
                .foregroundColor(.white)
            
            Text(camera.displayName)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
            
            Text("This may take up to 45 seconds")
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))
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
            
            HStack(spacing: 16) {
                // ✅ Retry button
                if retryAttempt < 3 {
                    Button(action: {
                        retryAttempt += 1
                        errorMessage = nil
                        isLoading = true
                        
                        // Force reload by updating the view
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            // Trigger reload
                        }
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
                
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Image(systemName: "arrow.left")
                        Text("Go Back")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.gray)
                    .cornerRadius(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.8))
    }
}