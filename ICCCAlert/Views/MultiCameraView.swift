import SwiftUI

// MARK: - Multi-Camera View (Quad View Support)

struct MultiCameraView: Codable, Identifiable {
    let id: String
    var name: String
    var cameraIds: [String] // Max 4 cameras
    var createdAt: Date
    
    init(id: String = UUID().uuidString, name: String, cameraIds: [String]) {
        self.id = id
        self.name = name
        self.cameraIds = Array(cameraIds.prefix(4)) // Limit to 4 cameras
        self.createdAt = Date()
    }
}

// MARK: - Multi-Camera Manager

class MultiCameraManager: ObservableObject {
    static let shared = MultiCameraManager()
    
    @Published var savedViews: [MultiCameraView] = []
    
    private let viewsKey = "saved_multi_camera_views"
    private let userDefaults = UserDefaults.standard
    
    private init() {
        loadViews()
    }
    
    // MARK: - CRUD Operations
    
    func createView(name: String, cameraIds: [String]) {
        let view = MultiCameraView(name: name, cameraIds: cameraIds)
        savedViews.append(view)
        saveViews()
        DebugLogger.shared.log("✅ Created view: \(name) with \(cameraIds.count) cameras", emoji: "✅", color: .green)
    }
    
    func updateView(_ view: MultiCameraView) {
        if let index = savedViews.firstIndex(where: { $0.id == view.id }) {
            savedViews[index] = view
            saveViews()
            DebugLogger.shared.log("✅ Updated view: \(view.name)", emoji: "✅", color: .blue)
        }
    }
    
    func deleteView(_ view: MultiCameraView) {
        savedViews.removeAll { $0.id == view.id }
        saveViews()
        DebugLogger.shared.log("🗑️ Deleted view: \(view.name)", emoji: "🗑️", color: .red)
    }
    
    func getView(by id: String) -> MultiCameraView? {
        return savedViews.first { $0.id == id }
    }
    
    // MARK: - Persistence
    
    private func saveViews() {
        if let encoded = try? JSONEncoder().encode(savedViews) {
            userDefaults.set(encoded, forKey: viewsKey)
        }
    }
    
    private func loadViews() {
        if let data = userDefaults.data(forKey: viewsKey),
           let decoded = try? JSONDecoder().decode([MultiCameraView].self, from: data) {
            savedViews = decoded
            DebugLogger.shared.log("📦 Loaded \(decoded.count) saved views", emoji: "📦", color: .blue)
        }
    }
}

// MARK: - Multi-Camera Views List

struct MultiCameraViewsListView: View {
    @StateObject private var multiCameraManager = MultiCameraManager.shared
    @StateObject private var cameraManager = CameraManager.shared
    @State private var showCreateSheet = false
    @State private var selectedView: MultiCameraView?
    
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 16) {
                    // Header
                    headerSection
                    
                    // Views List
                    if multiCameraManager.savedViews.isEmpty {
                        emptyStateView
                    } else {
                        viewsList
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Multi-Camera Views")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showCreateSheet = true }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.blue)
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateMultiCameraViewSheet()
        }
        .fullScreenCover(item: $selectedView) { view in
            QuadCameraPlayerView(multiView: view)
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [.blue.opacity(0.2), .blue.opacity(0.1)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 60, height: 60)
                
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.blue)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Quad View")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("View up to 4 cameras simultaneously")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
        )
    }
    
    // MARK: - Views List
    
    private var viewsList: some View {
        LazyVStack(spacing: 12) {
            ForEach(multiCameraManager.savedViews) { view in
                MultiCameraViewCard(view: view) {
                    selectedView = view
                }
                .contextMenu {
                    // iOS 14 compatible delete button
                    Button(action: {
                        multiCameraManager.deleteView(view)
                    }) {
                        Label("Delete", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [.blue.opacity(0.2), .blue.opacity(0.05)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 50, weight: .light))
                    .foregroundColor(.blue)
            }
            
            VStack(spacing: 8) {
                Text("No Views Created")
                    .font(.system(size: 24, weight: .bold))
                
                Text("Create a view to watch up to 4 cameras at once")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            Button(action: { showCreateSheet = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("Create View")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(Color.blue)
                )
            }
        }
        .padding(.top, 60)
    }
}

// MARK: - Multi-Camera View Card

struct MultiCameraViewCard: View {
    let view: MultiCameraView
    let onTap: () -> Void
    
    @StateObject private var cameraManager = CameraManager.shared
    
    var cameras: [Camera] {
        view.cameraIds.compactMap { cameraManager.getCameraById($0) }
    }
    
    var onlineCameras: Int {
        cameras.filter { $0.isOnline }.count
    }
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(view.name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 12))
                                Text("\(cameras.count)")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .foregroundColor(.blue)
                            
                            if onlineCameras > 0 {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 6, height: 6)
                                    Text("\(onlineCameras) online")
                                        .font(.system(size: 14, weight: .medium))
                                }
                                .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.blue)
                }
                
                // Camera Thumbnails Grid
                if !cameras.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                        ForEach(cameras.prefix(4), id: \.id) { camera in
                            cameraThumbnail(camera)
                        }
                        
                        // Fill empty slots
                        ForEach(cameras.count..<4, id: \.self) { _ in
                            emptySlot
                        }
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func cameraThumbnail(_ camera: Camera) -> some View {
        VStack(spacing: 4) {
            ZStack {
                if camera.isOnline {
                    LinearGradient(
                        gradient: Gradient(colors: [.green.opacity(0.25), .green.opacity(0.08)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    
                    Image(systemName: "video.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.green)
                } else {
                    LinearGradient(
                        gradient: Gradient(colors: [.gray.opacity(0.2), .gray.opacity(0.08)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.gray)
                }
            }
            .frame(height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            Text(camera.displayName)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
    
    private var emptySlot: some View {
        VStack(spacing: 4) {
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [.gray.opacity(0.1), .gray.opacity(0.05)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                
                Image(systemName: "plus")
                    .font(.system(size: 20))
                    .foregroundColor(.gray.opacity(0.5))
            }
            .frame(height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            Text("Empty")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Create Multi-Camera View Sheet

struct CreateMultiCameraViewSheet: View {
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var cameraManager = CameraManager.shared
    @StateObject private var multiCameraManager = MultiCameraManager.shared
    
    @State private var viewName = ""
    @State private var selectedCameraIds: Set<String> = []
    @State private var searchText = ""
    @State private var selectedArea: String?
    
    var availableAreas: [String] {
        cameraManager.availableAreas
    }
    
    var filteredCameras: [Camera] {
        var cameras = cameraManager.cameras
        
        if let area = selectedArea {
            cameras = cameras.filter { $0.area == area }
        }
        
        if !searchText.isEmpty {
            cameras = cameras.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.location.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        return cameras.filter { $0.isOnline }
    }
    
    var canCreate: Bool {
        !viewName.isEmpty && !selectedCameraIds.isEmpty && selectedCameraIds.count <= 4
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // View Name
                        VStack(alignment: .leading, spacing: 8) {
                            Text("View Name")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)
                            
                            TextField("e.g., Main Entrance Cameras", text: $viewName)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(size: 16))
                        }
                        .padding(.horizontal)
                        
                        // Selected Count
                        HStack {
                            Text("Selected Cameras: \(selectedCameraIds.count)/4")
                                .font(.system(size: 14))
                                .bold()
                                .foregroundColor(selectedCameraIds.count > 4 ? .red : .secondary)
                            
                            Spacer()
                            
                            if !selectedCameraIds.isEmpty {
                                Button("Clear") {
                                    selectedCameraIds.removeAll()
                                }
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.red)
                            }
                        }
                        .padding(.horizontal)
                        
                        // Area Filter
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                areaFilterButton(area: nil, label: "All Areas")
                                
                                ForEach(availableAreas, id: \.self) { area in
                                    areaFilterButton(area: area, label: area)
                                }
                            }
                            .padding(.horizontal)
                        }
                        
                        // Search
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            
                            TextField("Search cameras", text: $searchText)
                            
                            if !searchText.isEmpty {
                                Button(action: { searchText = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.systemBackground))
                        )
                        .padding(.horizontal)
                        
                        // Camera List
                        LazyVStack(spacing: 12) {
                            ForEach(filteredCameras, id: \.id) { camera in
                                cameraSelectionRow(camera)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("Create View")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        createView()
                    }
                    .disabled(!canCreate)
                    .font(.system(size: 17, weight: .semibold))
                }
            }
        }
    }
    
    private func areaFilterButton(area: String?, label: String) -> some View {
        Button(action: {
            withAnimation {
                selectedArea = area
            }
        }) {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(selectedArea == area ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(selectedArea == area ? Color.blue : Color(.systemBackground))
                )
        }
    }
    
    private func cameraSelectionRow(_ camera: Camera) -> some View {
        Button(action: {
            if selectedCameraIds.contains(camera.id) {
                selectedCameraIds.remove(camera.id)
            } else if selectedCameraIds.count < 4 {
                selectedCameraIds.insert(camera.id)
            }
        }) {
            HStack(spacing: 12) {
                // Selection indicator
                ZStack {
                    Circle()
                        .strokeBorder(selectedCameraIds.contains(camera.id) ? Color.blue : Color.gray.opacity(0.3), lineWidth: 2)
                        .frame(width: 24, height: 24)
                    
                    if selectedCameraIds.contains(camera.id) {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 16, height: 16)
                        
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                
                // Camera info
                VStack(alignment: .leading, spacing: 4) {
                    Text(camera.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                    
                    Text(camera.location.isEmpty ? camera.area : camera.location)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Status
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Online")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.green)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                selectedCameraIds.contains(camera.id) ? Color.blue : Color.clear,
                                lineWidth: 2
                            )
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(selectedCameraIds.count >= 4 && !selectedCameraIds.contains(camera.id))
        .opacity((selectedCameraIds.count >= 4 && !selectedCameraIds.contains(camera.id)) ? 0.5 : 1)
    }
    
    private func createView() {
        multiCameraManager.createView(name: viewName, cameraIds: Array(selectedCameraIds))
        presentationMode.wrappedValue.dismiss()
    }
}