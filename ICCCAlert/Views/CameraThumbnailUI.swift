import SwiftUI

// MARK: - Camera Thumbnail (MANUAL LOAD WITH ERROR STATE)
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
                    errorView
                } else {
                    tapToLoadView
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .contentShape(Rectangle())
        .id(viewId)
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
            
            // Show refresh button overlay
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: reloadThumbnail) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: isGridView ? 12 : 16))
                            .foregroundColor(.white)
                            .padding(isGridView ? 6 : 8)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(isGridView ? 4 : 8)
                }
            }
        }
    }
    
    private var tapToLoadView: some View {
        Button(action: loadThumbnail) {
            ZStack {
                LinearGradient(
                    colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                
                VStack(spacing: isGridView ? 4 : 8) {
                    Image(systemName: "photo")
                        .font(.system(size: isGridView ? 20 : 28))
                        .foregroundColor(.blue)
                    
                    Text("Tap to load")
                        .font(isGridView ? .caption2 : .caption)
                        .foregroundColor(.blue)
                        .fontWeight(.medium)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
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
    
    private var errorView: some View {
        Button(action: retryLoad) {
            ZStack {
                LinearGradient(
                    colors: [Color.red.opacity(0.3), Color.red.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                
                VStack(spacing: isGridView ? 4 : 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: isGridView ? 20 : 28))
                        .foregroundColor(.red)
                    
                    Text("Failed")
                        .font(isGridView ? .caption2 : .caption)
                        .foregroundColor(.red)
                        .fontWeight(.medium)
                    
                    if !isGridView {
                        Text("Tap to retry")
                            .font(.caption2)
                            .foregroundColor(.red.opacity(0.7))
                    }
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
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
    
    private func loadThumbnail() {
        guard camera.isOnline else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        if thumbnailCache.loadingCameras.contains(where: { _ in true }) {
            DebugLogger.shared.log("⚠️ Another capture in progress", emoji: "⚠️", color: .orange)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        
        thumbnailCache.manualLoad(for: camera) { success in
            DispatchQueue.main.async {
                if success {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }
    
    private func retryLoad() {
        guard camera.isOnline else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        
        // Check if another capture is in progress
        if thumbnailCache.loadingCameras.contains(where: { _ in true }) {
            DebugLogger.shared.log("⚠️ Another capture in progress - wait", emoji: "⚠️", color: .orange)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        
        // Clear the failure state and retry
        thumbnailCache.clearThumbnail(for: camera.id)
        
        // Small delay to ensure state is cleared
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.thumbnailCache.manualLoad(for: self.camera) { success in
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
    
    private func reloadThumbnail() {
        guard camera.isOnline else { return }
        
        // Check if another capture is in progress
        if thumbnailCache.loadingCameras.contains(where: { _ in true }) {
            DebugLogger.shared.log("⚠️ Another capture in progress", emoji: "⚠️", color: .orange)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        
        // Clear existing thumbnail first
        thumbnailCache.clearThumbnail(for: camera.id)
        
        // Then load new one
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.thumbnailCache.manualLoad(for: self.camera) { success in
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
}

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