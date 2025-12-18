import SwiftUI

struct DebugView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @StateObject private var logger = DebugLogger.shared
    @State private var refreshTrigger = UUID()
    
    var body: some View {
        NavigationView {
            List {
                // Connection
                Section(header: Text("Connection")) {
                    HStack {
                        Circle()
                            .fill(webSocketService.isConnected ? Color.green : Color.red)
                            .frame(width: 12, height: 12)
                        Text(webSocketService.isConnected ? "Connected" : "Disconnected")
                    }
                    
                    Button("Reconnect") {
                        webSocketService.disconnect()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            webSocketService.connect()
                        }
                    }
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
                    
                    Button("Send Subscription") {
                        webSocketService.sendSubscriptionV2()
                    }
                }
                
                // Events
                Section(header: Text("Events (Total: \(subscriptionManager.getTotalEventCount()))")) {
                    ForEach(subscriptionManager.subscribedChannels) { channel in
                        let events = subscriptionManager.getEvents(channelId: channel.id)
                        if !events.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(channel.id)
                                    .font(.system(size: 13, weight: .bold))
                                
                                ForEach(events.prefix(3)) { event in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.id ?? "no-id")
                                            .font(.system(size: 11))
                                            .foregroundColor(.blue)
                                        Text(event.location)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(4)
                                    .background(Color(.systemGray6))
                                    .cornerRadius(4)
                                }
                            }
                        }
                    }
                }
                
                // Logs (MOST RECENT FIRST)
                Section(header: HStack {
                    Text("Logs (\(logger.logs.count))")
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
                                    .font(.system(size: 12))
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
                // Refresh every 2 seconds
                Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                    refreshTrigger = UUID()
                }
            }
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Debug Logger

class DebugLogger: ObservableObject {
    static let shared = DebugLogger()
    
    @Published var logs: [LogEntry] = []
    private let maxLogs = 100
    
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let emoji: String
        let color: Color
    }
    
    func log(_ message: String, emoji: String = "📋", color: Color = .primary) {
        DispatchQueue.main.async {
            let entry = LogEntry(timestamp: Date(), message: message, emoji: emoji, color: color)
            self.logs.append(entry)
            
            // Keep only last 100 logs
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