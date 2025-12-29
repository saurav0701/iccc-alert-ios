import SwiftUI

struct AreaCamerasView: View {
    let area: String
    @StateObject private var cameraManager = CameraManager.shared
    
    @State private var searchText = ""
    @State private var showOnlineOnly = true
    @State private var gridLayout: GridLayout = .list
    
    @Binding var selectedCamera: Camera?
    
    @Environment(\.scenePhase) var scenePhase
    
    enum GridLayout: String, CaseIterable, Identifiable {
        case list = "List"
        case grid2x2 = "2×2 Grid"
        case grid3x3 = "3×3 Grid"
        
        var id: String { rawValue }
        
        var columns: Int {
            switch self {
            case .list: return 1
            case .grid2x2: return 2
            case .grid3x3: return 3
            }
        }
        
        var icon: String {
            switch self {
            case .list: return "list.bullet"
            case .grid2x2: return "square.grid.2x2"
            case .grid3x3: return "square.grid.3x3"
            }
        }
    }
    
    var cameras: [Camera] {
        var result = cameraManager.getCameras(forArea: area)
        
        if showOnlineOnly {
            result = result.filter { $0.isOnline }
        }
        
        if !searchText.isEmpty {
            result = result.filter { 
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.location.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        return result.sorted { $0.displayName < $1.displayName }
    }
    
    var onlineCount: Int {
        cameras.filter { $0.isOnline }.count
    }
    
    var totalCount: Int {
        cameraManager.getCameras(forArea: area).count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            statsBar
            filterBar
            
            if cameras.isEmpty {
                emptyView
            } else {
                cameraGridView
            }
        }
        .navigationTitle(area)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Layout", selection: $gridLayout) {
                        ForEach(GridLayout.allCases) { layout in
                            Label(layout.rawValue, systemImage: layout.icon)
                                .tag(layout)
                        }
                    }
                } label: {
                    Image(systemName: gridLayout.icon)
                        .font(.system(size: 18))
                }
            }
        }
        .onAppear {
            DebugLogger.shared.log("📹 AreaCamerasView appeared for \(area)", emoji: "📹", color: .blue)
        }
        .onDisappear {
            DebugLogger.shared.log("📤 AreaCamerasView disappeared for \(area)", emoji: "📤", color: .gray)
            PlayerManager.shared.pauseAll()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                PlayerManager.shared.clearAll()
            }
        }
        .onChange(of: gridLayout) { _ in
            PlayerManager.shared.clearAll()
        }
    }

    private var statsBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "video.fill")
                    .foregroundColor(.blue)
                Text("\(cameras.count) \(cameras.count == 1 ? "camera" : "cameras")")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("\(onlineCount)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)
                    Text("\(totalCount - onlineCount)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 2)
    }

    private var filterBar: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                
                TextField("Search cameras...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(12)
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .padding(.horizontal)

            HStack {
                Toggle(isOn: $showOnlineOnly) {
                    HStack(spacing: 8) {
                        Image(systemName: showOnlineOnly ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(showOnlineOnly ? .green : .gray)
                        Text("Show Online Only")
                            .font(.subheadline)
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

    @ViewBuilder
    private var cameraGridView: some View {
        ScrollView {
            if gridLayout == .list {
                LazyVStack(spacing: 12) {
                    ForEach(cameras, id: \.id) { camera in
                        CameraListItem(camera: camera)
                            .onTapGesture {
                                handleCameraTap(camera)
                            }
                    }
                }
                .padding()
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 12),
                        count: gridLayout.columns
                    ),
                    spacing: 12
                ) {
                    ForEach(cameras, id: \.id) { camera in
                        CameraGridCard(camera: camera, isCompact: gridLayout == .grid3x3)
                            .onTapGesture {
                                handleCameraTap(camera)
                            }
                    }
                }
                .padding()
            }
        }
        .background(Color(.systemGroupedBackground))
    }
    
    private func handleCameraTap(_ camera: Camera) {
        if camera.isOnline {
            PlayerManager.shared.pauseAll()
            selectedCamera = camera
        } else {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
            
            DebugLogger.shared.log(
                "⚠️ Cannot play offline camera: \(camera.displayName)",
                emoji: "⚠️",
                color: .orange
            )
        }
    }

    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: searchText.isEmpty ? "video.slash" : "magnifyingglass")
                    .font(.system(size: 50))
                    .foregroundColor(.gray)
            }
            
            Text(searchText.isEmpty ? "No Cameras" : "No Results")
                .font(.title2)
                .fontWeight(.bold)
            
            Text(searchText.isEmpty ? 
                 (showOnlineOnly ? "No online cameras in this area" : "No cameras found in this area") :
                 "No cameras match your search")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            if !searchText.isEmpty || showOnlineOnly {
                Button(action: {
                    searchText = ""
                    showOnlineOnly = false
                }) {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("Clear Filters")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(10)
                }
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - List View Item
struct CameraListItem: View {
    let camera: Camera
    
    var body: some View {
        HStack(spacing: 16) {
            // Thumbnail
            CameraThumbnail(camera: camera)
                .frame(width: 120, height: 90)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(camera.isOnline ? Color.blue.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1)
                )
            
            // Info
            VStack(alignment: .leading, spacing: 8) {
                Text(camera.displayName)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                
                HStack(spacing: 8) {
                    Circle()
                        .fill(camera.isOnline ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    
                    Text(camera.location.isEmpty ? camera.area : camera.location)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                if camera.isOnline {
                    HStack(spacing: 4) {
                        Image(systemName: "play.circle.fill")
                            .font(.caption)
                            .foregroundColor(.blue)
                        Text("Tap to view")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                } else {
                    Text("Offline")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .italic()
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .foregroundColor(.gray)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
        .opacity(camera.isOnline ? 1 : 0.6)
    }
}

// MARK: - Grid Card (2x2 and 3x3)
struct CameraGridCard: View {
    let camera: Camera
    let isCompact: Bool
    @State private var isPressed = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Video thumbnail
            ZStack {
                CameraThumbnail(camera: camera)
                    .aspectRatio(4/3, contentMode: .fill)
                    .clipped()
                
                // Overlay with status
                VStack {
                    HStack {
                        Spacer()
                        
                        // Online indicator
                        HStack(spacing: 4) {
                            Circle()
                                .fill(camera.isOnline ? Color.green : Color.gray)
                                .frame(width: isCompact ? 5 : 6, height: isCompact ? 5 : 6)
                            
                            if camera.isOnline {
                                Text("LIVE")
                                    .font(.system(size: isCompact ? 7 : 8, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .padding(.horizontal, isCompact ? 4 : 6)
                        .padding(.vertical, isCompact ? 2 : 3)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(4)
                        .padding(isCompact ? 4 : 6)
                    }
                    
                    Spacer()
                }
            }
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(camera.isOnline ? Color.blue.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1)
            )
            
            // Camera info
            VStack(alignment: .leading, spacing: 4) {
                Text(camera.displayName)
                    .font(.system(size: isCompact ? 11 : 12, weight: .semibold))
                    .lineLimit(isCompact ? 1 : 2)
                    .foregroundColor(.primary)
                    .frame(height: isCompact ? 16 : 32, alignment: .topLeading)
                
                if !camera.location.isEmpty && !isCompact {
                    Text(camera.location)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(isCompact ? 6 : 8)
        }
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
        .opacity(camera.isOnline ? 1 : 0.65)
        .scaleEffect(isPressed ? 0.95 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}