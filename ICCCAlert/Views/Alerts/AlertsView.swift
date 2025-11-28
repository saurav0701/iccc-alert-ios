import SwiftUI

struct AlertsView: View {
    @State private var alerts: [Event] = [
        // Sample data for testing
        Event(
            eventId: "test-1",
            timestamp: Int64(Date().timeIntervalSince1970),
            area: "sijua",
            areaDisplay: "Sijua",
            type: "cd",
            typeDisplay: "Crowd Detection",
            data: ["location": "Main Gate Area"]
        ),
        Event(
            eventId: "test-2",
            timestamp: Int64(Date().timeIntervalSince1970 - 300),
            area: "kusunda",
            areaDisplay: "Kusunda",
            type: "id",
            typeDisplay: "Intrusion Detection",
            data: ["location": "North Perimeter"]
        )
    ]
    
    var body: some View {
        NavigationView {
            Group {
                if alerts.isEmpty {
                    EmptyAlertsView()
                } else {
                    AlertsList(alerts: alerts)
                }
            }
            .navigationTitle("All Alerts")
        }
    }
}

struct EmptyAlertsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            
            Text("No Alerts Yet")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Real-time alerts will appear here")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

struct AlertsList: View {
    let alerts: [Event]
    
    var body: some View {
        List(alerts) { alert in
            AlertRow(event: alert)
        }
    }
}

struct AlertRow: View {
    let event: Event
    
    private var formattedDate: String {
        let date = Date(timeIntervalSince1970: TimeInterval(event.timestamp))
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, HH:mm:ss"
        return formatter.string(from: date)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(event.areaDisplay ?? "Unknown")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Text(event.typeDisplay ?? "Unknown")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if let location = event.data["location"] {
                Text(location)
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }
            
            Text(formattedDate)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
    }
}