import SwiftUI

// MARK: - Camera Thumbnail (Manual Refresh Only - No Auto-Load)
struct CameraThumbnail: View {
    let camera: Camera
    let isGridView: Bool
    @StateObject private var thumbnailCache = ThumbnailCacheManager.shared
    @State private var isLoading = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let thumbnail = thumbnailCache.getThumbnail(for: camera.id) {
                    // Show cached thumbnail with proper aspect ratio
                    thumbnailImageView(thumbnail, geometry: geometry)
                } else if !camera.isOnline {
                    // Offline state
                    offlineView
                } else if isLoading {
                    // Loading state
                    loadingView
                } else {
                    // Manual refresh button
                    manualRefreshView
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .contentShape(Rectangle())
    }
    
    private func thumbnailImageView(_ image: UIImage, geometry: GeometryProxy) -> some View {
        let imageSize = image.size
        let containerSize = geometry.size
        
        // Calculate aspect fit scale
        let widthRatio = containerSize.width / imageSize.width
        let heightRatio = containerSize.height / imageSize.height
        let scale = min(widthRatio, heightRatio)
        
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        
        return ZStack {
            // Background color
            Color.black.opacity(0.05)
            
            // Image centered and properly sized
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: scaledWidth, height: scaledHeight)
                .clipped()
        }
    }
    
    private var loadingView: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                    .scaleEffect(isGridView ? 0.8 : 1.0)
                
                if !isGridView {
                    Text("Loading...")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            }
        }
    }
    
    private var manualRefreshView: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue.opacity(0.2), Color.blue.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 8) {
                Button(action: loadThumbnail) {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: isGridView ? 28 : 36))
                            .foregroundColor(.blue)
                        
                        if !isGridView {
                            Text("Tap to load")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
    
    private var offlineView: some View {
        ZStack {
            LinearGradient(
                colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 6) {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: isGridView ? 20 : 24))
                    .foregroundColor(.gray)
                
                Text("Offline")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
    }
    
    // MARK: - Load Thumbnail (Manual Only)
    
    private func loadThumbnail() {
        guard !isLoading, camera.isOnline else { return }
        
        // Haptic feedback
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        
        isLoading = true
        
        DebugLogger.shared.log("🔄 Manual load: \(camera.displayName)", emoji: "🔄", color: .blue)
        
        thumbnailCache.manualRefresh(for: camera) { success in
            DispatchQueue.main.async {
                self.isLoading = false
                
                if success {
                    DebugLogger.shared.log("✅ Loaded: \(camera.displayName)", emoji: "✅", color: .green)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else {
                    DebugLogger.shared.log("❌ Failed: \(camera.displayName)", emoji: "❌", color: .red)
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }
}

// MARK: - Camera Grid Card (Fixed Thumbnail Container)
// NOTE: Remove the old CameraGridCard from WebRTCPlayer.swift and use this one
struct CameraGridCardFixed: View {
    let camera: Camera
    let mode: GridViewMode
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Fixed size thumbnail container
            CameraThumbnail(camera: camera, isGridView: mode != .list)
                .frame(height: thumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(camera.isOnline ? Color.blue.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1)
                )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(camera.displayName)
                    .font(titleFont)
                    .fontWeight(.medium)
                    .lineLimit(mode == .list ? 2 : 1)
                    .foregroundColor(.primary)
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(camera.isOnline ? Color.green : Color.gray)
                        .frame(width: dotSize, height: dotSize)
                    
                    Text(camera.location.isEmpty ? camera.area : camera.location)
                        .font(subtitleFont)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, mode == .list ? 0 : 4)
        }
        .padding(padding)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
        .opacity(camera.isOnline ? 1 : 0.6)
    }
    
    private var thumbnailHeight: CGFloat {
        switch mode {
        case .list: return 140
        case .grid2x2: return 120
        case .grid3x3: return 100
        case .grid4x4: return 80
        }
    }
    
    private var padding: CGFloat {
        switch mode {
        case .list: return 12
        case .grid2x2: return 10
        case .grid3x3: return 8
        case .grid4x4: return 6
        }
    }
    
    private var titleFont: Font {
        switch mode {
        case .list: return .subheadline
        case .grid2x2: return .caption
        case .grid3x3: return .caption2
        case .grid4x4: return .system(size: 10)
        }
    }
    
    private var subtitleFont: Font {
        switch mode {
        case .list: return .caption
        case .grid2x2: return .caption2
        case .grid3x3: return .system(size: 10)
        case .grid4x4: return .system(size: 9)
        }
    }
    
    private var dotSize: CGFloat {
        switch mode {
        case .list: return 6
        case .grid2x2: return 5
        case .grid3x3, .grid4x4: return 4
        }
    }
}