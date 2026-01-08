import SwiftUI

// MARK: - Enhanced Debug Logger
class DebugLogger: ObservableObject {
    static let shared = DebugLogger()
    
    @Published var logs: [LogEntry] = []
    private let maxLogs = 200
    
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let emoji: String
        let color: Color
    }
    
    private init() {}
    
    func log(_ message: String, emoji: String = "📋", color: Color = .primary) {
        DispatchQueue.main.async {
            let entry = LogEntry(timestamp: Date(), message: message, emoji: emoji, color: color)
            self.logs.append(entry)
            
            if self.logs.count > self.maxLogs {
                self.logs.removeFirst(self.logs.count - self.maxLogs)
            }
        }
    }
    
    func clear() {
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
    }
}

// MARK: - Debug View
struct DebugView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @StateObject private var cameraManager = CameraManager.shared
    // @StateObject private var playerManager = HLSPlayerManager.shared
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
                    Text("Cameras").tag(1)
                    Text("Logs").tag(2)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                
                // Content based on selected tab
                TabView(selection: $selectedTab) {
                    overviewTab.tag(0)
                    camerasTab.tag(1)
                    logsTab.tag(2)
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
            
            // HLS Player Status
            Section(header: Text("HLS Video Players")) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Active Players")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(playerManager.activePlayerCount) / 2")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(playerManager.activePlayerCount >= 2 ? .orange : .green)
                    }
                    
                    Spacer()
                    
                    if playerManager.activePlayerCount > 0 {
                        Button("Release All") {
                            playerManager.releaseAllPlayers()
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.2))
                        .cornerRadius(6)
                    }
                }
                .padding(.vertical, 4)
                
                if playerManager.activePlayerCount >= 2 {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                        HStack(alignment: .top, spacing: 8) {
                            Text("⚠️")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Player Limit Reached")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.orange)
                                Text("Maximum 2 concurrent streams allowed. Release a player before opening another.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
            }
            
            // Camera Statistics
            Section(header: Text("Camera Status")) {
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
            
            // Memory Info
            Section(header: Text("System")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Memory Status")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Monitoring")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    
                    Text("App will automatically release video players on memory warnings")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Cameras Tab
    private var camerasTab: some View {
        List {
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
            
            Section(header: Text("Stream Protocol")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Protocol")
                            .font(.caption)
                        Spacer()
                        Text("HLS (HTTP Live Streaming)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.blue)
                    }
                    
                    Text("Using native iOS AVPlayer with HLS for maximum stability and battery efficiency")
                        .font(.caption2)
                        .foregroundColor(.secondary)
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
                if logger.logs.isEmpty {
                    Text("No logs yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding()
                } else {
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
    }
    
    private func startAutoRefresh() {
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            refreshTrigger = UUID()
        }
    }
    
    private func stopAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}