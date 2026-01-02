import SwiftUI

struct AreaCamerasView: View {
    let area: String
    @StateObject private var cameraManager = CameraManager.shared
    @StateObject private var thumbnailCache = ThumbnailCacheManager.shared
    @State private var searchText = ""
    @State private var showOnlineOnly = true
    @State private var gridMode: GridViewMode = .grid2x2
    @State private var selectedCamera: Camera? = nil
    @State private var showStreamBlockedAlert = false
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
            ToolbarItemGroup(placement: .navigationBarTrailing) {
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
        }
        .fullScreenCover(item: $selectedCamera) { camera in
            FullscreenPlayerView(camera: camera)
                .onDisappear {
                    // Ensure player is cleaned up when dismissed
                    PlayerManager.shared.releasePlayer(camera.id)
                }
        }
        .alert("Stream Blocked", isPresented: $showStreamBlockedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please wait - a thumbnail is currently being captured. Try again in a few seconds.")
        }
        .onAppear {
            DebugLogger.shared.log("📹 AreaCamerasView appeared: \(area)", emoji: "📹", color: .blue)
        }
        .onDisappear {
            DebugLogger.shared.log("🚪 AreaCamerasView disappeared: \(area)", emoji: "🚪", color: .orange)
            
            // Clean up all active resources
            PlayerManager.shared.clearAll()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                // Ensure cleanup when app goes to background
                PlayerManager.shared.clearAll()
            }
        }
        .onChange(of: gridMode) { _ in
            // Clean up players when changing grid mode
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
                    // Clean up players when filter changes
                    PlayerManager.shared.clearAll()
                }
            }
            .padding(.horizontal)
            
            // Info banner about manual thumbnail loading
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                    .font(.system(size: 14))
                
                Text("Tap camera thumbnails to load preview. Wait for capture to finish before playing streams.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.05))
            .cornerRadius(8)
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
                        .onTapGesture {
                            handleCameraTap(camera)
                        }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }
    
    private func handleCameraTap(_ camera: Camera) {
        guard camera.isOnline else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        
        // CRITICAL: Check if thumbnail is currently being captured
        if thumbnailCache.isLoading(for: camera.id) {
            DebugLogger.shared.log("⚠️ Cannot play stream - thumbnail capture in progress", emoji: "⚠️", color: .orange)
            showStreamBlockedAlert = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        
        // Check if other streams are active
        if PlayerManager.shared.getActiveCount() > 0 {
            DebugLogger.shared.log("⚠️ Another stream is active", emoji: "⚠️", color: .orange)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        
        // CRITICAL: Add 1 second delay before opening player to ensure thumbnail cleanup
        DebugLogger.shared.log("▶️ Opening player for: \(camera.displayName)", emoji: "▶️", color: .green)
        
        // Small delay to ensure any lingering WebViews are destroyed
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.selectedCamera = camera
        }
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
}