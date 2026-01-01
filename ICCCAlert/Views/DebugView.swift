import SwiftUI

// MARK: - Enhanced Debug Logger with Camera Status
class DebugLogger: ObservableObject {
    static let shared = DebugLogger()
    
    @Published var logs: [LogEntry] = []
    @Published var cameraStatus: [String: CameraStreamStatus] = [:] // Camera ID -> Status
    private let maxLogs = 500 // Increased for thumbnail debugging
    
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let emoji: String
        let color: Color
    }
    
    struct CameraStreamStatus: Identifiable {
        let id: String // Camera ID
        var status: String
        var lastUpdate: Date
        var error: String?
        var streamURL: String?
        
        var statusColor: Color {
            if status.contains("Playing") { return .green }
            if status.contains("Codec") || status.contains("Error") { return .red }
            if status.contains("Buffering") || status.contains("retry") { return .orange }
            return .blue
        }
        
        var statusEmoji: String {
            if status.contains("Playing") { return "✅" }
            if status.contains("Codec") { return "🚫" }
            if status.contains("Error") { return "❌" }
            if status.contains("Buffering") { return "⏳" }
            return "📹"
        }
    }
    
    private init() {}
    
    func log(_ message: String, emoji: String = "📋", color: Color = .primary) {
        DispatchQueue.main.async {
            let entry = LogEntry(timestamp: Date(), message: message, emoji: emoji, color: color)
            self.logs.append(entry)
            
            if self.logs.count > self.maxLogs {
                self.logs.removeFirst(self.logs.count - self.maxLogs)
            }
            
            // Also print to console for easier debugging
            print("\(emoji) \(message)")
        }
    }
    
    func updateCameraStatus(cameraId: String, status: String, streamURL: String? = nil, error: String? = nil) {
        DispatchQueue.main.async {
            self.cameraStatus[cameraId] = CameraStreamStatus(
                id: cameraId,
                status: status,
                lastUpdate: Date(),
                error: error,
                streamURL: streamURL
            )
        }
    }
    
    func getCamerasByStatus() -> (working: Int, codec: Int, error: Int, other: Int) {
        var working = 0
        var codec = 0
        var error = 0
        var other = 0
        
        for (_, status) in cameraStatus {
            if status.status.contains("Playing") {
                working += 1
            } else if status.status.contains("Codec") {
                codec += 1
            } else if status.status.contains("Error") {
                error += 1
            } else {
                other += 1
            }
        }
        
        return (working, codec, error, other)
    }
    
    func clear() {
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
    }
    
    func clearCameraStatus() {
        DispatchQueue.main.async {
            self.cameraStatus.removeAll()
        }
    }
}

// MARK: - Enhanced Debug View
struct DebugView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @StateObject private var cameraManager = CameraManager.shared
    @StateObject private var thumbnailCache = ThumbnailCacheManager.shared
    @StateObject private var logger = DebugLogger.shared
    @State private var refreshTrigger = UUID()
    @State private var autoRefreshTimer: Timer?
    @State private var selectedTab = 0
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Tab Selector
                Picker("", selection: $selectedTab) {
                    Text("Overview").tag(0)
                    Text("Thumbnails").tag(1)
                    Text("Cameras").tag(2)
                    Text("Logs").tag(3)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                
                // Content based on selected tab
                TabView(selection: $selectedTab) {
                    overviewTab.tag(0)
                    thumbnailsTab.tag(1)
                    camerasTab.tag(2)
                    logsTab.tag(3)
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            }
            .navigationTitle("Debug")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { refreshTrigger = UUID() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .id(refreshTrigger)
            .onAppear {
                startAutoRefresh()
            }
            .onDisappear {
                stopAutoRefresh()
            }
        }
    }
    
    // MARK: - Overview Tab
    private var overviewTab: some View {
        List {
            // Connection Status
            Section(header: Text("Connection")) {
                HStack {
                    Circle()
                        .fill(webSocketService.isConnected ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(webSocketService.isConnected ? "Connected" : "Disconnected")
                    Spacer()
                    Button("Reconnect") {
                        webSocketService.disconnect()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            webSocketService.connect()
                        }
                    }
                    .font(.caption)
                }
            }
            
            // Camera Statistics
            Section(header: Text("Camera Stream Status")) {
                let _ = logger.getCamerasByStatus()
                
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Total Cameras")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(cameraManager.cameras.count)")
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Online")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(cameraManager.onlineCamerasCount)")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                    }
                }
                .padding(.vertical, 4)
            }
            
            // Subscriptions
            Section(header: Text("Subscriptions (\(subscriptionManager.subscribedChannels.count))")) {
                ForEach(subscriptionManager.subscribedChannels) { channel in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(channel.id)
                            .font(.system(size: 14, weight: .bold))
                        HStack {
                            Text("Events: \(subscriptionManager.getEvents(channelId: channel.id).count)")
                                .font(.caption)
                            Spacer()
                            Text("Unread: \(subscriptionManager.getUnreadCount(channelId: channel.id))")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Thumbnails Tab
    private var thumbnailsTab: some View {
        List {
            // Thumbnail Test Section - FIXED
            Section(header: Text("Thumbnail Capture Test")) {
                Button(action: {
                    // Test with first online camera - use manualRefresh instead
                    if let testCamera = cameraManager.cameras.first(where: { $0.isOnline }) {
                        DebugLogger.shared.log("🧪 Testing thumbnail capture for: \(testCamera.displayName)", emoji: "🧪", color: .blue)
                        thumbnailCache.manualRefresh(for: testCamera) { success in
                            if success {
                                DebugLogger.shared.log("✅ Test capture successful", emoji: "✅", color: .green)
                            } else {
                                DebugLogger.shared.log("❌ Test capture failed", emoji: "❌", color: .red)
                            }
                        }
                    } else {
                        DebugLogger.shared.log("⚠️ No online cameras available for test", emoji: "⚠️", color: .orange)
                    }
                }) {
                    HStack {
                        Image(systemName: "photo.badge.plus")
                        Text("Test Thumbnail Capture")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())
                
                // Show captured thumbnails count
                let thumbnailCount = thumbnailCache.thumbnails.count
                HStack {
                    Text("Captured Thumbnails:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(thumbnailCount)")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(thumbnailCount > 0 ? .green : .gray)
                }
            }
            
            // Show thumbnails grid
            if !thumbnailCache.thumbnails.isEmpty {
                Section(header: HStack {
                    Text("Captured Thumbnails")
                    Spacer()
                    Button("Clear All") {
                        thumbnailCache.clearAllThumbnails()
                        DebugLogger.shared.log("🗑️ Cleared all thumbnails", emoji: "🗑️", color: .red)
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }) {
                    let thumbnails = Array(thumbnailCache.thumbnails)
                    ForEach(0..<thumbnails.count, id: \.self) { index in
                        let (key, image) = thumbnails[index]
                        HStack(spacing: 12) {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 100, height: 75)
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.green, lineWidth: 2)
                                )
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(key)
                                    .font(.system(size: 12, weight: .bold))
                                    .lineLimit(2)
                                
                                Text("\(Int(image.size.width))x\(Int(image.size.height))")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                
                                if let timestamp = thumbnailCache.thumbnailTimestamps[key] {
                                    let age = Date().timeIntervalSince(timestamp)
                                    let isFresh = thumbnailCache.isThumbnailFresh(for: key)
                                    Text(isFresh ? "Fresh ✓" : "Stale (\(Int(age/60))m old)")
                                        .font(.system(size: 9))
                                        .foregroundColor(isFresh ? .green : .orange)
                                }
                            }
                            
                            Spacer()
                            
                            Button(action: {
                                thumbnailCache.clearThumbnail(for: key)
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
    
    // MARK: - Cameras Tab
    private var camerasTab: some View {
        List {
            Section(header: HStack {
                Text("Camera Stream Status (\(logger.cameraStatus.count))")
                Spacer()
                Button("Clear") {
                    logger.clearCameraStatus()
                }
                .font(.caption)
            }) {
                if logger.cameraStatus.isEmpty {
                    Text("No camera stream data yet. Open some camera streams to see their status.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(Array(logger.cameraStatus.values).sorted(by: { $0.lastUpdate > $1.lastUpdate })) { status in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(status.statusEmoji)
                                    .font(.title3)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Camera: \(status.id)")
                                        .font(.system(size: 12, weight: .bold))
                                    
                                    Text(status.status)
                                        .font(.system(size: 11))
                                        .foregroundColor(status.statusColor)
                                    
                                    if let error = status.error {
                                        Text(error)
                                            .font(.system(size: 10))
                                            .foregroundColor(.red)
                                    }
                                    
                                    Text(formatTime(status.lastUpdate))
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                            }
                            
                            if let url = status.streamURL {
                                Text(url)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            
            // Group by Area
            Section(header: Text("By Area")) {
                ForEach(cameraManager.availableAreas, id: \.self) { area in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(area)
                            .font(.headline)
                        
                        let areaCameras = cameraManager.getCameras(forArea: area)
                        let online = areaCameras.filter { $0.isOnline }.count
                        
                        HStack {
                            Text("Total: \(areaCameras.count)")
                                .font(.caption)
                            Spacer()
                            Text("Online: \(online)")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Logs Tab
    private var logsTab: some View {
        List {
            Section(header: HStack {
                Text("All Logs (\(logger.logs.count))")
                Spacer()
                Button("Clear") {
                    logger.clear()
                    refreshTrigger = UUID()
                }
                .font(.caption)
            }) {
                ForEach(logger.logs.reversed()) { log in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(log.emoji)
                            Text(log.message)
                                .font(.system(size: 11))
                                .foregroundColor(log.color)
                            Spacer()
                        }
                        Text(formatTime(log.timestamp))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
    
    private func startAutoRefresh() {
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            refreshTrigger = UUID()
        }
    }
    
    private func stopAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}