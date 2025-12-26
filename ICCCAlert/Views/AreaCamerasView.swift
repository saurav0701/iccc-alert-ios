import SwiftUI

struct AreaCamerasView: View {
    let area: String
    @StateObject private var cameraManager = CameraManager.shared
    
    @State private var searchText = ""
    @State private var showOnlineOnly = false
    @State private var gridLayout: GridLayout = .grid2x2
    
    @Binding var selectedCamera: Camera?
    
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
            // Clean up inactive WebViews when leaving area view
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                WebViewStore.shared.clearInactive()
            }
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
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }

    private var cameraGridView: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: gridLayout.columns),
                spacing: 12
            ) {
                ForEach(cameras) { camera in
                    // ✅ CRITICAL: Use camera.id as stable identifier
                    CameraCard(camera: camera, layout: gridLayout)
                        .id(camera.id) // ✅ Stable ID prevents recreation
                        .equatable() // ✅ Only update when camera actually changes
                        .onTapGesture {
                            if camera.isOnline {
                                selectedCamera = camera
                            } else {
                                DebugLogger.shared.log("⚠️ Cannot play offline camera: \(camera.displayName)", emoji: "⚠️", color: .orange)
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

// MARK: - CameraCard (Optimized with Equatable to prevent re-renders)
struct CameraCard: View, Equatable {
    let camera: Camera
    let layout: AreaCamerasView.GridLayout
    
    // ✅ CRITICAL: Only update when these values actually change
    static func == (lhs: CameraCard, rhs: CameraCard) -> Bool {
        return lhs.camera.id == rhs.camera.id &&
               lhs.camera.status == rhs.camera.status &&
               lhs.camera.streamURL == rhs.camera.streamURL &&
               lhs.layout == rhs.layout
    }
    
    var cardHeight: CGFloat {
        switch layout {
        case .list: return 180
        case .grid2x2: return 140
        case .grid3x3: return 100
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ✅ CRITICAL: CameraThumbnail has stable internal ID
            CameraThumbnail(camera: camera)
                .frame(height: cardHeight)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(camera.isOnline ? Color.blue.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(camera.displayName)
                    .font(layout == .list ? .body : (layout == .grid2x2 ? .caption : .caption2))
                    .fontWeight(.medium)
                    .lineLimit(layout == .grid3x3 ? 1 : 2)
                    .foregroundColor(.primary)
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(camera.isOnline ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                    
                    Text(camera.location.isEmpty ? camera.area : camera.location)
                        .font(.system(size: layout == .grid3x3 ? 9 : 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(layout == .grid3x3 ? 8 : 12)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
        .opacity(camera.isOnline ? 1 : 0.6)
    }
}
