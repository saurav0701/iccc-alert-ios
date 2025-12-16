import SwiftUI

struct DebugView: View {
    @State private var logContents = ""
    @State private var showShareSheet = false
    @State private var autoRefresh = false
    @State private var refreshTimer: Timer?
    
    private let logger = DebugLogger.shared
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Controls
                HStack(spacing: 12) {
                    Button(action: refreshLogs) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh")
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    
                    Toggle("Auto", isOn: $autoRefresh)
                        .font(.caption)
                        .frame(width: 80)
                    
                    Button(action: clearLogs) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Clear")
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    
                    Button(action: { showShareSheet = true }) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share")
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                
                // Log file path
                if let url = logger.getLogFileURL() {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Log File Location:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(url.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.blue)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemBackground))
                }
                
                // Quick Actions - iOS 14 compatible button styling
                HStack(spacing: 8) {
                    Button("Dump Channels") {
                        logger.logChannelEvents()
                        refreshLogs()
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(.systemGray3), lineWidth: 1)
                    )
                    
                    Button("WS Status") {
                        logger.logWebSocketStatus()
                        refreshLogs()
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(.systemGray3), lineWidth: 1)
                    )
                    
                    Button("Test Event") {
                        testEventStorage()
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(.systemGray3), lineWidth: 1)
                    )
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                
                Divider()
                
                // Log contents
                ScrollView {
                    ScrollViewReader { proxy in
                        Text(logContents)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .id("logBottom")
                            .onChange(of: logContents) { _ in
                                if autoRefresh {
                                    withAnimation {
                                        proxy.scrollTo("logBottom", anchor: .bottom)
                                    }
                                }
                            }
                    }
                }
                .background(Color(.systemBackground))
            }
            .navigationTitle("Debug Logs")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                refreshLogs()
                if autoRefresh {
                    startAutoRefresh()
                }
            }
            .onDisappear {
                stopAutoRefresh()
            }
            .onChange(of: autoRefresh) { enabled in
                if enabled {
                    startAutoRefresh()
                } else {
                    stopAutoRefresh()
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = logger.shareLogs() {
                    ShareSheet(items: [url])
                }
            }
        }
    }
    
    private func refreshLogs() {
        logContents = logger.getLogContents()
    }
    
    private func clearLogs() {
        logger.clearLogs()
        refreshLogs()
    }
    
    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            refreshLogs()
        }
    }
    
    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    private func testEventStorage() {
        logger.log("TEST", "=== TESTING EVENT STORAGE ===")
        
        // Create a test event
        let testEvent = Event(
            id: "test-\(UUID().uuidString)",
            timestamp: Int64(Date().timeIntervalSince1970),
            source: "test",
            area: "giridih",
            areaDisplay: "Giridih",
            type: "id",
            typeDisplay: "Intrusion Detection",
            groupId: nil,
            vehicleNumber: nil,
            vehicleTransporter: nil,
            data: [
                "location": AnyCodable("Test Location"),
                "description": AnyCodable("Test event for debugging")
            ],
            isRead: false
        )
        
        logger.logEvent(testEvent, action: "TEST EVENT CREATED")
        
        // Try to add it
        let channelId = "giridih_id"
        let added = SubscriptionManager.shared.addEvent(event: testEvent)
        
        logger.log("TEST", "Add result: \(added)")
        
        // Check if it's there
        let events = SubscriptionManager.shared.getEvents(channelId: channelId)
        logger.log("TEST", "Events in channel after add: \(events.count)")
        
        if let firstEvent = events.first {
            logger.log("TEST", "First event ID: \(firstEvent.id ?? "nil")")
        }
        
        // Force a notification
        NotificationCenter.default.post(
            name: .newEventReceived,
            object: nil,
            userInfo: ["event": testEvent, "channelId": channelId]
        )
        
        logger.log("TEST", "✅ Broadcast test event notification")
        logger.log("TEST", "=== END TEST ===")
        
        refreshLogs()
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct DebugView_Previews: PreviewProvider {
    static var previews: some View {
        DebugView()
    }
}