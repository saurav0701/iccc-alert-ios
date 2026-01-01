import SwiftUI

// MARK: - Area Cameras View (Auto-Loading Visible Thumbnails)
struct AreaCamerasView: View {
    let area: String
    @StateObject private var cameraManager = CameraManager.shared
    @StateObject private var thumbnailCache = ThumbnailCacheManager.shared
    @State private var searchText = ""
    @State private var showOnlineOnly = true
    @State private var gridMode: GridViewMode = .grid2x2
    @State private var selectedCamera: Camera? = nil
    @Environment(\.scenePhase) var scenePhase
    
    var cameras: [Camera] {
        var result = cameraManager.getCameras(forArea: area)
        if showOnlineOnly { result = result.filter { $0.isOnline } }
        if !searchText.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.location.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result.sorted { $0.displayName < $1.displayName }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            statsBar
            filterBar
            cameras.isEmpty ? AnyView(emptyView) : AnyView(cameraGridView)
        }
        .navigationTitle(area)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Layout", selection: $gridMode) {
                        ForEach(GridViewMode.allCases) { mode in
                            Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: gridMode.icon).font(.system(size: 18))
                }
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: refreshThumbnails) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18))
                }
            }
        }
        .fullScreenCover(item: $selectedCamera) { camera in
            FullscreenPlayerView(camera: camera)
                .onDisappear {
                    // Resume thumbnail captures when closing player
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        ThumbnailCacheManager.shared.resumeCaptures()
                    }
                }
        }
        .onAppear {
            DebugLogger.shared.log("📹 AreaCamerasView appeared: \(area)", emoji: "📹", color: .blue)
        }
        .onDisappear {
            DebugLogger.shared.log("🚪 AreaCamerasView disappeared: \(area)", emoji: "🚪", color: .orange)
            // Clean up all active streams
            PlayerManager.shared.clearAll()
            // Clear thumbnails from memory (keep on disk)
            thumbnailCache.clearChannelThumbnails()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                PlayerManager.shared.clearAll()
            }
        }
        .onChange(of: gridMode) { _ in
            PlayerManager.shared.clearAll()
        }
    }
    
    private var statsBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "video.fill").foregroundColor(.blue)
                Text("\(cameras.count) camera\(cameras.count == 1 ? "" : "s")")
                    .font(.subheadline).fontWeight(.medium)
            }
            Spacer()
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("\(cameras.filter { $0.isOnline }.count)").font(.subheadline).foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    Circle().fill(Color.gray).frame(width: 8, height: 8)
                    Text("\(cameras.filter { !$0.isOnline }.count)").font(.subheadline).foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 2)
    }
    
    private var filterBar: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.gray)
                TextField("Search cameras...", text: $searchText).textFieldStyle(PlainTextFieldStyle())
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                    }
                }
            }
            .padding(12).background(Color(.systemGray6)).cornerRadius(10).padding(.horizontal)
            
            HStack {
                Toggle(isOn: $showOnlineOnly) {
                    HStack(spacing: 8) {
                        Image(systemName: showOnlineOnly ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(showOnlineOnly ? .green : .gray)
                        Text("Show Online Only").font(.subheadline)
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: .green))
                .onChange(of: showOnlineOnly) { _ in
                    PlayerManager.shared.clearAll()
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }
    
    private var cameraGridView: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: gridMode.columns), spacing: 12) {
                ForEach(cameras, id: \.id) { camera in
                    CameraGridCard(camera: camera, mode: gridMode)
                        .onTapGesture {
                            if camera.isOnline {
                                // Stop any thumbnail captures before opening player
                                ThumbnailCacheManager.shared.pauseCaptures()
                                
                                // Haptic feedback
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                
                                // Small delay to ensure smooth transition
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    selectedCamera = camera
                                }
                            } else {
                                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            }
                        }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }
    
    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle().fill(Color.gray.opacity(0.1)).frame(width: 100, height: 100)
                Image(systemName: searchText.isEmpty ? "video.slash" : "magnifyingglass")
                    .font(.system(size: 50)).foregroundColor(.gray)
            }
            Text(searchText.isEmpty ? "No Cameras" : "No Results").font(.title2).fontWeight(.bold)
            Text(searchText.isEmpty ? (showOnlineOnly ? "No online cameras" : "No cameras found") : "No matches")
                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
    
    // MARK: - Refresh Thumbnails
    
    private func refreshThumbnails() {
        // Clear all visible camera thumbnails
        for camera in cameras where camera.isOnline {
            thumbnailCache.clearThumbnail(for: camera.id)
        }
        
        // Trigger haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        DebugLogger.shared.log("🔄 Thumbnails cleared, will reload as you scroll", emoji: "🔄", color: .blue)
    }
}