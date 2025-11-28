import SwiftUI

struct AlertsView: View {
    @StateObject private var viewModel: AlertsViewModel
    @StateObject private var webSocketManager: WebSocketManager
    @State private var selectedFilter: AlertFilter = .all
    
    init(authManager: AuthManager) {
        _viewModel = StateObject(wrappedValue: AlertsViewModel(authManager: authManager))
        _webSocketManager = StateObject(wrappedValue: WebSocketManager(authManager: authManager))
    }
    
    var filteredAlerts: [Event] {
        switch selectedFilter {
        case .all:
            return viewModel.alerts
        case .unread:
            return viewModel.alerts.filter { !$0.isRead }
        case .important:
            return viewModel.alerts.filter { $0.priority == "high" }
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Filter Picker
                Picker("Filter", selection: $selectedFilter) {
                    Text("All").tag(AlertFilter.all)
                    Text("Unread").tag(AlertFilter.unread)
                    Text("Important").tag(AlertFilter.important)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                
                // Connection Status
                if !webSocketManager.isConnected {
                    HStack {
                        Image(systemName: "wifi.slash")
                        Text("Disconnected")
                            .font(.caption)
                        Spacer()
                        Button("Reconnect") {
                            webSocketManager.connect()
                        }
                        .font(.caption)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.2))
                }
                
                // Alerts List
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.error {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 50))
                            .foregroundColor(.orange)
                        Text(error)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            viewModel.fetchAlerts()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredAlerts.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        Text("No alerts")
                            .font(.headline)
                        Text("You're all caught up!")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filteredAlerts) { alert in
                            AlertRowView(alert: alert) {
                                viewModel.markAsRead(alert)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Alerts")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        viewModel.markAllAsRead()
                    }) {
                        Text("Mark All Read")
                            .font(.subheadline)
                    }
                }
            }
        }
        .onAppear {
            viewModel.fetchAlerts()
            webSocketManager.connect()
        }
        .onDisappear {
            webSocketManager.disconnect()
        }
    }
}

enum AlertFilter {
    case all
    case unread
    case important
}

struct AlertRowView: View {
    let alert: Event
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                // Priority Indicator
                Circle()
                    .fill(priorityColor)
                    .frame(width: 12, height: 12)
                    .padding(.top, 4)
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(alert.title)
                            .font(.headline)
                            .foregroundColor(.primary)
                        Spacer()
                        if !alert.isRead {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 8, height: 8)
                        }
                    }
                    
                    Text(alert.message)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    
                    HStack {
                        Text(alert.channelName ?? "General")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                        
                        Spacer()
                        
                        Text(timeAgo(from: alert.createdAt))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var priorityColor: Color {
        switch alert.priority?.lowercased() {
        case "high":
            return .red
        case "medium":
            return .orange
        default:
            return .green
        }
    }
    
    private func timeAgo(from dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: dateString) else {
            return dateString
        }
        
        let now = Date()
        let interval = now.timeIntervalSince(date)
        
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}