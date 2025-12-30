import SwiftUI

// MARK: - Area Cameras View (with Thumbnail Prefetching)
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
                Button(action: {
                    refreshThumbnails()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16))
                }
            }
        }
        .fullScreenCover(item: $selectedCamera) { FullscreenPlayerView(camera: $0) }
        .onAppear {
            prefetchVisibleThumbnails()
        }
        .onDisappear { 
            PlayerManager.shared.clearAll() 
        }
        .onChange(of: scenePhase) { 
            if $0 == .background { 
                PlayerManager.shared.clearAll() 
            } else if $0 == .active {
                prefetchVisibleThumbnails()
            }
        }
        .onChange(of: gridMode) { _ in 
            PlayerManager.shared.clearAll()
            prefetchVisibleThumbnails()
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
                    prefetchVisibleThumbnails()
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
                                selectedCamera = camera
                            } else {
                                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            }
                        }
                        .onAppear {
                            // Prefetch thumbnail for cameras that come into view
                            if camera.isOnline && thumbnailCache.getThumbnail(for: camera.id) == nil {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    thumbnailCache.fetchThumbnail(for: camera)
                                }
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
    
    // MARK: - Thumbnail Management
    
    private func prefetchVisibleThumbnails() {
        // Only prefetch first 10 visible cameras to avoid overwhelming the system
        let visibleCameras = Array(cameras.prefix(10))
        
        // Stagger the prefetch requests
        for (index, camera) in visibleCameras.enumerated() {
            if camera.isOnline && thumbnailCache.getThumbnail(for: camera.id) == nil {
                let delay = Double(index) * 0.5 // 500ms between each request
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    thumbnailCache.fetchThumbnail(for: camera)
                }
            }
        }
    }
    
    private func refreshThumbnails() {
        // Clear and refresh thumbnails for visible cameras
        let visibleCameras = Array(cameras.prefix(10))
        
        for camera in visibleCameras where camera.isOnline {
            thumbnailCache.clearThumbnail(for: camera.id)
        }
        
        // Trigger haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        // Prefetch again
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            prefetchVisibleThumbnails()
        }
    }
}