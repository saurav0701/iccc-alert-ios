import SwiftUI

struct AlertsView: View {
    @StateObject private var viewModel = AlertsViewModel()
    @StateObject private var webSocketManager = WebSocketManager.shared
    
    var body: some View {
        NavigationView {
            Group {
                if viewModel.events.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        
                        Text("No Alerts Yet")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("Subscribe to channels to receive real-time alerts")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                } else {
                    List(viewModel.events) { event in
                        AlertRowView(event: event)
                    }
                }
            }
            .navigationTitle("Alerts")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(webSocketManager.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        
                        Text(webSocketManager.isConnected ? "Connected" : "Disconnected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

struct AlertRowView: View {
    let event: Event
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Event Type Badge
                Text(event.type?.uppercased() ?? "??")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(eventColor)
                    .cornerRadius(6)
                
                Spacer()
                
                Text(event.date, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(event.areaDisplay ?? "Unknown Area")
                .font(.headline)
            
            Text(event.typeDisplay ?? "Unknown Event")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text(event.location)
                .font(.caption)
                .foregroundColor(.gray)
            
            Text(event.date, style: .date)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(.vertical, 4)
    }
    
    var eventColor: Color {
        switch event.type {
        case "cd": return Color.orange
        case "id": return Color.red
        case "vd": return Color.blue
        case "pd": return Color.green
        case "ct": return Color.purple
        case "sh": return Color.orange
        case "off-route": return Color.orange
        case "tamper": return Color.red
        default: return Color.gray
        }
    }
}