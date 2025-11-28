import SwiftUI

struct ChannelsView: View {
    @StateObject private var viewModel = ChannelsViewModel()
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var searchText = ""
    
    var filteredChannels: [Channel] {
        if searchText.isEmpty {
            return viewModel.allChannels
        } else {
            return viewModel.allChannels.filter {
                $0.description.localizedCaseInsensitiveContains(searchText) ||
                $0.areaDisplay.localizedCaseInsensitiveContains(searchText) ||
                $0.eventTypeDisplay.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    var body: some View {
        NavigationView {
            List {
                // Subscribed Channels Section
                if !subscriptionManager.subscribedChannels.isEmpty {
                    Section(header: Text("Subscribed (\(subscriptionManager.subscribedChannels.count))")) {
                        ForEach(subscriptionManager.subscribedChannels) { channel in
                            ChannelRowView(
                                channel: channel,
                                isSubscribed: true,
                                onToggle: {
                                    subscriptionManager.unsubscribe(from: channel.id)
                                }
                            )
                        }
                    }
                }
                
                // All Channels Section
                Section(header: Text("All Channels (\(filteredChannels.count))")) {
                    ForEach(filteredChannels) { channel in
                        let isSubscribed = subscriptionManager.isSubscribed(channelId: channel.id)
                        ChannelRowView(
                            channel: channel,
                            isSubscribed: isSubscribed,
                            onToggle: {
                                if isSubscribed {
                                    subscriptionManager.unsubscribe(from: channel.id)
                                } else {
                                    subscriptionManager.subscribe(to: channel)
                                }
                            }
                        )
                    }
                }
            }
            .navigationTitle("Channels")
            .searchable(text: $searchText, prompt: "Search channels")
        }
    }
}

struct ChannelRowView: View {
    let channel: Channel
    let isSubscribed: Bool
    let onToggle: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.areaDisplay)
                    .font(.headline)
                
                Text(channel.eventTypeDisplay)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: onToggle) {
                Image(systemName: isSubscribed ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isSubscribed ? .green : .gray)
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
    }
}