import SwiftUI

// MARK: - Camera Thumbnail (with Proper Lifecycle Management)
struct CameraThumbnail: View {
    let camera: Camera
    let isGridView: Bool
    @StateObject private var thumbnailCache = ThumbnailCacheManager.shared
    @State private var viewId = UUID()
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let thumbnail = thumbnailCache.getThumbnail(for: camera.id) {
                    thumbnailImageView(thumbnail, geometry: geometry)
                } else if !camera.isOnline {
                    offlineView
                } else if thumbnailCache.isLoading(for: camera.id) {
                    loadingView
                } else if thumbnailCache.hasFailed(for: camera.id) {
                    failedView
                } else {
                    loadingView
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .contentShape(Rectangle())
        .id(viewId) // Force recreation on camera change
        .onAppear {
            // Only auto-load if we don't have a thumbnail
            if camera.isOnline && thumbnailCache.getThumbnail(for: camera.id) == nil {
                thumbnailCache.autoFetchThumbnail(for: camera)
            }
        }
        .onDisappear {
            // Don't cancel - let it finish in queue
        }
    }
    
    private func thumbnailImageView(_ image: UIImage, geometry: GeometryProxy) -> some View {
        let imageSize = image.size
        let containerSize = geometry.size
        
        let widthRatio = containerSize.width / imageSize.width
        let heightRatio = containerSize.height / imageSize.height
        let scale = min(widthRatio, heightRatio)
        
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        
        return ZStack {
            Color.black.opacity(0.05)
            
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
    
    private var failedView: some View {
        ZStack {
            LinearGradient(
                colors: [Color.orange.opacity(0.3), Color.orange.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            Button(action: retryLoad) {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: isGridView ? 24 : 32))
                        .foregroundColor(.orange)
                    
                    if !isGridView {
                        Text("Tap to load")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
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
    
    private func retryLoad() {
        guard camera.isOnline else { return }
        
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        
        thumbnailCache.manualRefresh(for: camera) { success in
            DispatchQueue.main.async {
                if success {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }
}

// MARK: - Camera Grid Card (No Changes Needed)
struct CameraGridCardFixed: View {
    let camera: Camera
    let mode: GridViewMode
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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