import SwiftUI

struct AreaCamerasView: View {
    let area: String
    @StateObject private var cameraManager = CameraManager.shared
    
    @State private var searchText = ""
    @State private var showOnlineOnly = false
    @State private var selectedCamera: Camera? = nil
    @State private var gridLayout: GridLayout = .grid2x2
    
    enum GridLayout: String, CaseIterable {
        case list = "List"
        case grid2x2 = "2×2"
        case grid3x3 = "3×3"
        
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
    
    var body: some View {
        VStack(spacing: 0) {
            // Stats Bar
            statsBar
            
            // Search & Filter
            filterBar
            
            // Camera Grid/List
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
                    ForEach(GridLayout.allCases, id: \.self) { layout in
                        Button(action: { gridLayout = layout }) {
                            HStack {
                                Text(layout.rawValue)
                                if gridLayout == layout {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: gridLayout.icon)
                        .font(.system(size: 18))
                }
            }
        }
        .fullScreenCover(item: $selectedCamera) { camera in
            HLSPlayerView(camera: camera)
        }
    }
    
    // MARK: - Stats Bar
    
    private var statsBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "video.fill")
                    .foregroundColor(.blue)
                Text("\(cameras.count) cameras")
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
                    Text("\(cameras.count - onlineCount)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 2)
    }
    
    // MARK: - Filter Bar
    
    private var filterBar: some View {
        VStack(spacing: 12) {
            // Search
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
            
            // Online Toggle
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
    
    // MARK: - Camera Grid
    
    private var cameraGridView: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: gridLayout.columns),
                spacing: 12
            ) {
                ForEach(cameras) { camera in
                    CameraCard(camera: camera, layout: gridLayout)
                        .onTapGesture {
                            if camera.isOnline {
                                selectedCamera = camera
                            }
                        }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }
    
    // MARK: - Empty View
    
    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: searchText.isEmpty ? "video.slash" : "magnifyingglass")
                .font(.system(size: 50))
                .foregroundColor(.gray)
            
            Text(searchText.isEmpty ? "No Cameras" : "No Results")
                .font(.title2)
                .fontWeight(.bold)
            
            Text(searchText.isEmpty ? 
                 (showOnlineOnly ? "No online cameras in this area" : "No cameras found in this area") :
                 "No cameras match your search")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            if !searchText.isEmpty || showOnlineOnly {
                Button(action: {
                    searchText = ""
                    showOnlineOnly = false
                }) {
                    Text("Clear Filters")
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

// MARK: - Camera Card

struct CameraCard: View {
    let camera: Camera
    let layout: AreaCamerasView.GridLayout
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Camera Preview/Thumbnail
            ZStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.gray.opacity(0.3),
                                Color.gray.opacity(0.1)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                VStack(spacing: 12) {
                    Image(systemName: camera.isOnline ? "video.fill" : "video.slash.fill")
                        .font(.system(size: layout == .list ? 40 : 30))
                        .foregroundColor(camera.isOnline ? .blue : .gray)
                    
                    if !camera.isOnline {
                        Text("Offline")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
            .frame(height: layout == .list ? 120 : 100)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(camera.isOnline ? Color.blue.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1)
            )
            
            // Camera Info
            VStack(alignment: .leading, spacing: 4) {
                Text(camera.displayName)
                    .font(layout == .list ? .body : .caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(camera.isOnline ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                    
                    Text(camera.location)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
        .opacity(camera.isOnline ? 1 : 0.6)
    }
}