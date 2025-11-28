import Foundation

class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()
    
    @Published var subscribedChannels: [Channel] = []
    
    private init() {
        loadSubscriptions()
    }
    
    func subscribe(to channel: Channel) {
        if !subscribedChannels.contains(where: { $0.id == channel.id }) {
            var newChannel = channel
            newChannel.isSubscribed = true
            subscribedChannels.append(newChannel)
            saveSubscriptions()
            WebSocketManager.shared.sendSubscription(channels: subscribedChannels)
        }
    }
    
    func unsubscribe(from channelId: String) {
        subscribedChannels.removeAll { $0.id == channelId }
        saveSubscriptions()
        WebSocketManager.shared.sendSubscription(channels: subscribedChannels)
    }
    
    func isSubscribed(channelId: String) -> Bool {
        return subscribedChannels.contains(where: { $0.id == channelId })
    }
    
    private func saveSubscriptions() {
        if let data = try? JSONEncoder().encode(subscribedChannels) {
            UserDefaults.standard.set(data, forKey: "subscribed_channels")
        }
    }
    
    private func loadSubscriptions() {
        if let data = UserDefaults.standard.data(forKey: "subscribed_channels"),
           let channels = try? JSONDecoder().decode([Channel].self, from: data) {
            subscribedChannels = channels
        }
    }
}