import SwiftUI

struct ChannelDetailView: View {
    let channel: Channel
    @StateObject private var webSocketManager = WebSocketManager.shared
    
    var channelEvents: [Event] {
        webSocketManager.events.filter {
            $0.area == channel.area && $0.type == channel.eventType
        }
    }
    
    var body: some View {
        List(channelEvents) { event in
            AlertRowView(event: event)
        }
        .navigationTitle(channel.areaDisplay)
        .navigationBarTitleDisplayMode(.inline)
    }
}