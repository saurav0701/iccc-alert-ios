import SwiftUI

// MARK: - AlertsView (Equivalent to AlertsActivity)
struct AlertsView: View {
    @StateObject private var viewModel = AlertsViewModel()
    
    var body: some View {
        NavigationView {
            ZStack {
                if viewModel.alerts.isEmpty {
                    EmptyAlertsView()
                } else {
                    AlertsList(alerts: viewModel.alerts)
                }
            }
            .navigationTitle("All Alerts")
            .navigationBarTitleDisplayMode(.large)
        }
        .onAppear {
            viewModel.startListening()
        }
        .onDisappear {
            viewModel.stopListening()
        }
    }
}

// MARK: - Empty State View
struct EmptyAlertsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            
            Text("No Alerts Yet")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("You'll see real-time alerts here when events occur")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

// MARK: - Alerts List
struct AlertsList: View {
    let alerts: [Event]
    
    var body: some View {
        List(alerts) { alert in
            AlertRow(event: alert)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
        .listStyle(PlainListStyle())
    }
}

// MARK: - Alert Row (Equivalent to item_alert.xml)
struct AlertRow: View {
    let event: Event
    
    private var formattedDate: String {
        let date = Date(timeIntervalSince1970: TimeInterval(event.timestamp))
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, HH:mm:ss"
        return formatter.string(from: date)
    }
    
    private var badgeColor: Color {
        switch event.type {
        case "cd": return Color(hex: "#FF5722")
        case "id": return Color(hex: "#F44336")
        case "ct": return Color(hex: "#E91E63")
        case "sh": return Color(hex: "#FF9800")
        case "vd": return Color(hex: "#2196F3")
        case "pd": return Color(hex: "#4CAF50")
        case "vc": return Color(hex: "#FF9800")
        default: return Color(hex: "#9E9E9E")
        }
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Badge Circle
            Circle()
                .fill(badgeColor)
                .frame(width: 12, height: 12)
                .padding(.top, 4)
            
            // Content
            VStack(alignment: .leading, spacing: 6) {
                // Area and Type
                HStack {
                    Text(event.areaDisplay ?? "Unknown")
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    Text(event.typeDisplay ?? "Unknown")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                // Location
                if let location = event.data["location"] as? String {
                    Text(location)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
                
                // Timestamp
                Text(formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - ViewModel (Business Logic)
class AlertsViewModel: ObservableObject {
    @Published var alerts: [Event] = []
    private let maxAlerts = 100
    
    func startListening() {
        // Listen to WebSocket events
        WebSocketManager.shared.addListener { [weak self] event in
            DispatchQueue.main.async {
                self?.addAlert(event)
            }
        }
    }
    
    func stopListening() {
        // Remove listener when view disappears
        WebSocketManager.shared.removeAllListeners()
    }
    
    private func addAlert(_ event: Event) {
        // Add to beginning
        alerts.insert(event, at: 0)
        
        // Keep only last 100 alerts
        if alerts.count > maxAlerts {
            alerts.removeLast()
        }
    }
}

// MARK: - Color Extension (Hex Support)
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Preview
struct AlertsView_Previews: PreviewProvider {
    static var previews: some View {
        AlertsView()
    }
}