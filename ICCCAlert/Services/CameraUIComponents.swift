import SwiftUI

// MARK: - Camera Thumbnail (Auto-Loading When Visible)
struct CameraThumbnail: View {
    let camera: Camera
    let isGridView: Bool
    @StateObject private var thumbnailCache = ThumbnailCacheManager.shared
    @State private var isLoading = false
    @State private var hasFailed = false
    @State private var hasAttemptedLoad = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background color
                Color.black
                
                // Content
                contentView
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(4/3, contentMode: .fit)
        .clipped()
        .onAppear {
            // Auto-load when thumbnail appears in view
            if camera.isOnline && !hasAttemptedLoad {
                loadThumbnail()
            }
        }
    }
    
    @ViewBuilder
    private var contentView: some View {
        if let thumbnail = thumbnailCache.getThumbnail(for: camera.id) {
            thumbnailImageView(thumbnail)
        } else if !camera.isOnline {
            offlineView
        } else if hasFailed {
            failedView
        } else if isLoading {
            loadingView
        } else {
            placeholderView
        }
    }
    
    private func thumbnailImageView(_ image: UIImage) -> some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
    }
    
    private var loadingView: some View {
        ZStack {
            Color.black
            
            VStack(spacing: isGridView ? 6 : 10) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(isGridView ? 0.7 : 1.0)
                
                Text("Loading...")
                    .font(.system(size: isGridView ? 10 : 12))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }
    
    private var placeholderView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.blue.opacity(0.4),
                    Color.blue.opacity(0.2)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: isGridView ? 4 : 8) {
                Image(systemName: "photo.fill")
                    .font(.system(size: isGridView ? 20 : 32))
                    .foregroundColor(.white.opacity(0.7))
                
                if !isGridView {
                    Text("Loading...")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
    }
    
    private var failedView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.orange.opacity(0.4),
                    Color.orange.opacity(0.2)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: isGridView ? 4 : 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: isGridView ? 18 : 24))
                    .foregroundColor(.white.opacity(0.8))
                
                Text(isGridView ? "Retry" : "Tap to retry")
                    .font(.system(size: isGridView ? 9 : 11))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .onTapGesture {
            hasFailed = false
            hasAttemptedLoad = false
            loadThumbnail()
        }
    }
    
    private var offlineView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.gray.opacity(0.4),
                    Color.gray.opacity(0.2)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: isGridView ? 4 : 6) {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: isGridView ? 18 : 24))
                    .foregroundColor(.white.opacity(0.6))
                
                Text("Offline")
                    .font(.system(size: isGridView ? 9 : 11))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }
    
    private func loadThumbnail() {
        guard !isLoading, !hasAttemptedLoad, camera.isOnline else { return }
        
        hasAttemptedLoad = true
        isLoading = true
        hasFailed = false
        
        // Request thumbnail from cache manager
        thumbnailCache.fetchThumbnail(for: camera)
        
        // Check after timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) {
            if isLoading && thumbnailCache.getThumbnail(for: camera.id) == nil {
                isLoading = false
                hasFailed = true
            } else {
                isLoading = false
            }
        }
    }
}

// MARK: - Camera Grid Card (Same as before)
struct CameraGridCard: View {
    let camera: Camera
    let mode: GridViewMode
    
    var body: some View {
        VStack(alignment: .leading, spacing: cardSpacing) {
            // Thumbnail with fixed aspect ratio
            CameraThumbnail(camera: camera, isGridView: mode != .list)
                .cornerRadius(cornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(borderColor, lineWidth: 1)
                )
                .overlay(
                    // Status badge overlay
                    VStack {
                        HStack {
                            Spacer()
                            statusBadge
                        }
                        Spacer()
                    }
                    .padding(6)
                )
            
            // Camera info
            VStack(alignment: .leading, spacing: infoSpacing) {
                Text(camera.displayName)
                    .font(titleFont)
                    .fontWeight(.medium)
                    .lineLimit(mode == .list ? 2 : 1)
                    .foregroundColor(.primary)
                
                HStack(spacing: 6) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: iconSize))
                        .foregroundColor(.secondary)
                    
                    Text(camera.location.isEmpty ? camera.area : camera.location)
                        .font(subtitleFont)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, infoHorizontalPadding)
        }
        .padding(cardPadding)
        .background(
            RoundedRectangle(cornerRadius: cardCornerRadius)
                .fill(Color(.systemBackground))
                .shadow(
                    color: Color.black.opacity(shadowOpacity),
                    radius: shadowRadius,
                    x: 0,
                    y: shadowY
                )
        )
        .opacity(camera.isOnline ? 1 : 0.6)
    }
    
    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(camera.isOnline ? Color.green : Color.red)
                .frame(width: badgeDotSize, height: badgeDotSize)
            
            if mode == .list {
                Text(camera.isOnline ? "LIVE" : "OFFLINE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, badgePadding)
        .padding(.vertical, badgePadding - 2)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.7))
        )
    }
    
    // MARK: - Computed Properties for Sizing
    
    private var cardSpacing: CGFloat {
        switch mode {
        case .list: return 12
        case .grid2x2: return 10
        case .grid3x3: return 8
        case .grid4x4: return 6
        }
    }
    
    private var cardPadding: CGFloat {
        switch mode {
        case .list: return 12
        case .grid2x2: return 10
        case .grid3x3: return 8
        case .grid4x4: return 6
        }
    }
    
    private var cardCornerRadius: CGFloat {
        switch mode {
        case .list: return 16
        case .grid2x2: return 14
        case .grid3x3: return 12
        case .grid4x4: return 10
        }
    }
    
    private var cornerRadius: CGFloat {
        switch mode {
        case .list: return 12
        case .grid2x2: return 10
        case .grid3x3: return 8
        case .grid4x4: return 6
        }
    }
    
    private var infoSpacing: CGFloat {
        switch mode {
        case .list: return 6
        case .grid2x2: return 4
        case .grid3x3: return 3
        case .grid4x4: return 2
        }
    }
    
    private var infoHorizontalPadding: CGFloat {
        mode == .list ? 0 : 4
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
    
    private var iconSize: CGFloat {
        switch mode {
        case .list: return 10
        case .grid2x2: return 9
        case .grid3x3, .grid4x4: return 8
        }
    }
    
    private var badgeDotSize: CGFloat {
        switch mode {
        case .list: return 6
        case .grid2x2: return 5
        case .grid3x3, .grid4x4: return 4
        }
    }
    
    private var badgePadding: CGFloat {
        switch mode {
        case .list: return 6
        case .grid2x2: return 5
        case .grid3x3, .grid4x4: return 4
        }
    }
    
    private var borderColor: Color {
        camera.isOnline ? Color.blue.opacity(0.3) : Color.gray.opacity(0.3)
    }
    
    private var shadowOpacity: Double {
        switch mode {
        case .list: return 0.1
        case .grid2x2: return 0.08
        case .grid3x3, .grid4x4: return 0.06
        }
    }
    
    private var shadowRadius: CGFloat {
        switch mode {
        case .list: return 8
        case .grid2x2: return 6
        case .grid3x3, .grid4x4: return 4
        }
    }
    
    private var shadowY: CGFloat {
        switch mode {
        case .list: return 3
        case .grid2x2: return 2
        case .grid3x3, .grid4x4: return 1
        }
    }
}