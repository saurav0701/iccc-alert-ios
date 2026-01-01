import SwiftUI

struct AreaCamerasView: View {
    let area: String
    @StateObject private var cameraManager = CameraManager.shared
    @StateObject private var thumbnailCache = ThumbnailCacheManager.shared
    @State private var searchText = ""
    @State private var showOnlineOnly = true
    @State private var gridMode: GridViewMode = .grid2x2
    @State private var selectedCamera: Camera? = nil
    @State private var isRefreshing = false
    @State private var visibleCameras: Set<String> = []
    @State private var loadedThumbnails: Set<String> = []
    @Environment(\.scenePhase) var scenePhase
    
    // ✅ Limit how many thumbnails we load at once
    private let maxSimultaneousLoads = 5  // Only 5 at a time
    
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
                Button(action: refreshVisibleThumbnails) {
                    HStack(spacing: 6) {
                        if isRefreshing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16))
                            Text("Refresh")
                                .font(.caption)
                        }
                    }
                }
                .disabled(isRefreshing)
            }
        }
        .fullScreenCover(item: $selectedCamera) { FullscreenPlayerView(camera: $0) }
        .onAppear {
            DebugLogger.shared.log("📹 AreaCamerasView appeared: \(area)", emoji: "📹", color: .blue)
            
            // ✅ Small delay before loading thumbnails
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                loadVisibleThumbnails()
            }
        }
        .onDisappear {
            DebugLogger.shared.log("🚪 AreaCamerasView disappeared: \(area)", emoji: "🚪", color: .orange)
            cleanupResources()
        }
        .onChange(of: scenePhase) { phase in
            handleScenePhaseChange(phase)
        }
        .onChange(of: gridMode) { _ in
            PlayerManager.shared.clearAll()
            visibleCameras.removeAll()
            loadedThumbnails.removeAll()
            
            // ✅ Longer delay after mode change
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                loadVisibleThumbnails()
            }
        }
        .onChange(of: showOnlineOnly) { _ in
            PlayerManager.shared.clearAll()
            visibleCameras.removeAll()
            loadedThumbnails.removeAll()
            
            // ✅ Longer delay after filter change
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                loadVisibleThumbnails()
            }
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
                    CameraGridCardFixed(camera: camera, mode: gridMode)
                        .onAppear {
                            handleCameraAppear(camera)
                        }
                        .onDisappear {
                            handleCameraDisappear(camera)
                        }
                        .onTapGesture {
                            if camera.isOnline {
                                selectedCamera = camera
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

    // MARK: - Handle Camera Appear/Disappear
    
    private func handleCameraAppear(_ camera: Camera) {
        // Track visibility
        visibleCameras.insert(camera.id)
        
        // ✅ Only load if not already loaded and within limit
        guard !loadedThumbnails.contains(camera.id) else { return }
        guard loadedThumbnails.count < maxSimultaneousLoads else { return }
        
        loadedThumbnails.insert(camera.id)
        
        // ✅ Random delay between 0.5-2 seconds to stagger loading
        let delay = Double.random(in: 0.5...2.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            thumbnailCache.autoFetchThumbnail(for: camera)
        }
    }
    
    private func handleCameraDisappear(_ camera: Camera) {
        visibleCameras.remove(camera.id)
    }

    // MARK: - Load Visible Thumbnails (Ultra Safe)
    
    private func loadVisibleThumbnails() {
        // ✅ Only load first 5 cameras max
        let maxInitialLoad = 5
        let onlineCameras = cameras.filter { $0.isOnline }.prefix(maxInitialLoad)
        
        loadedThumbnails.removeAll()
        
        for (index, camera) in onlineCameras.enumerated() {
            loadedThumbnails.insert(camera.id)
            
            // ✅ Stagger by 2 seconds each (very conservative)
            let delay = Double(index) * 2.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                thumbnailCache.autoFetchThumbnail(for: camera)
            }
        }
        
        DebugLogger.shared.log("📸 Loading \(onlineCameras.count) thumbnails (ultra-safe mode)", emoji: "📸", color: .blue)
    }
    
    // MARK: - Refresh Visible Thumbnails
    
    private func refreshVisibleThumbnails() {
        guard !isRefreshing else { return }
        
        isRefreshing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        // ✅ Only refresh visible cameras (max 5)
        let camerasToRefresh = cameras.filter { 
            $0.isOnline && visibleCameras.contains($0.id) 
        }.prefix(5)
        
        DebugLogger.shared.log("🔄 Refreshing \(camerasToRefresh.count) visible thumbnails", emoji: "🔄", color: .blue)
        
        // Clear thumbnails
        for camera in camerasToRefresh {
            thumbnailCache.clearThumbnail(for: camera.id)
        }
        
        // Reload with stagger
        for (index, camera) in camerasToRefresh.enumerated() {
            let delay = Double(index) * 2.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                thumbnailCache.autoFetchThumbnail(for: camera)
            }
        }
        
        // Reset refresh state
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.isRefreshing = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            DebugLogger.shared.log("✅ Refresh complete", emoji: "✅", color: .green)
        }
    }
    
    // MARK: - Cleanup Resources
    
    private func cleanupResources() {
        // ✅ Stop all video players
        PlayerManager.shared.clearAll()
        
        // ✅ Stop all thumbnail captures
        thumbnailCache.stopAllCaptures()
        
        // ✅ Clear memory cache (keep disk cache)
        thumbnailCache.clearChannelThumbnails()
        
        visibleCameras.removeAll()
        loadedThumbnails.removeAll()
        
        DebugLogger.shared.log("🧹 Cleaned up area view resources", emoji: "🧹", color: .orange)
    }
    
    // MARK: - Scene Phase Change
    
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // Resume thumbnail loading for visible cameras (with delay)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                loadVisibleThumbnails()
            }
            
        case .inactive, .background:
            // Immediately stop all captures and players
            PlayerManager.shared.clearAll()
            thumbnailCache.stopAllCaptures()
            
        @unknown default:
            break
        }
    }
}