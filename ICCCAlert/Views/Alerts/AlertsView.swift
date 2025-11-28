import SwiftUI

struct AlertsView: View {
    @State private var alerts: [Event] = [
        Event(area: "sijua", areaDisplay: "Sijua", 
              type: "cd", typeDisplay: "Crowd Detection", 
              location: "Main Gate"),
        Event(area: "kusunda", areaDisplay: "Kusunda",
              type: "id", typeDisplay: "Intrusion Detection",
              location: "North Side")
    ]
    
    var body: some View {
        NavigationView {
            List(alerts) { alert in
                VStack(alignment: .leading, spacing: 8) {
                    Text(alert.areaDisplay)
                        .font(.headline)
                    Text(alert.typeDisplay)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(alert.location)
                        .font(.caption)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Alerts")
        }
    }
}