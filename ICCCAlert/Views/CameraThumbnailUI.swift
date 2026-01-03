import SwiftUI

// MARK: - Camera Card WITHOUT Thumbnails (Icon Only)
struct CameraGridCardFixed: View {
    let camera: Camera
    let mode: GridViewMode
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // REMOVED: CameraThumbnail - replaced with simple icon
            iconPlaceholder
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
    
    // Simple icon placeholder (NO WebView creation)
    private var iconPlaceholder: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: camera.isOnline ? 
                    [Color.blue.opacity(0.3), Color.blue.opacity(0.1)] :
                    [Color.gray.opacity(0.3), Color.gray.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 8) {
                // Icon
                Image(systemName: camera.isOnline ? "video.fill" : "video.slash.fill")
                    .font(.system(size: iconSize))
                    .foregroundColor(camera.isOnline ? .blue : .gray)
                
                // Status text
                if mode == .list || mode == .grid2x2 {
                    Text(camera.isOnline ? "Tap to stream" : "Offline")
                        .font(.caption2)
                        .foregroundColor(camera.isOnline ? .blue : .gray)
                }
            }
        }
    }
    
    private var thumbnailHeight: CGFloat {
        switch mode {
        case .list: return 140
        case .grid2x2: return 120
        case .grid3x3: return 100
        case .grid4x4: return 80
        }
    }
    
    private var iconSize: CGFloat {
        switch mode {
        case .list: return 40
        case .grid2x2: return 32
        case .grid3x3: return 28
        case .grid4x4: return 24
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