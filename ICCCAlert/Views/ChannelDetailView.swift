import SwiftUI

struct ChannelDetailView: View {
    let channel: Channel
    @StateObject private var webSocketManager: WebSocketManager
    @StateObject private var subscriptionManager: SubscriptionManager
    @State private var isSubscribed = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    init(channel: Channel, authManager: AuthManager) {
        self.channel = channel
        _webSocketManager = StateObject(wrappedValue: WebSocketManager(authManager: authManager))
        _subscriptionManager = StateObject(wrappedValue: SubscriptionManager(authManager: authManager))
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Channel Header
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: categoryIcon(for: channel.category))
                            .font(.system(size: 50))
                            .foregroundColor(.blue)
                            .frame(width: 80, height: 80)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(16)
                        
                        Spacer()
                    }
                    
                    Text(channel.name)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text(channel.category)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(8)
                }
                .padding()
                
                Divider()
                
                // Description
                if let description = channel.description {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About")
                            .font(.headline)
                        Text(description)
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
                
                Divider()
                
                // Subscription Section
                VStack(alignment: .leading, spacing: 16) {
                    Text("Notifications")
                        .font(.headline)
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Subscribe to alerts")
                                .font(.body)
                            Text("Get notified when new alerts are posted")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Toggle("", isOn: $isSubscribed)
                            .labelsHidden()
                            .onChange(of: isSubscribed) { newValue in
                                handleSubscriptionToggle(newValue)
                            }
                    }
                }
                .padding()
                
                Spacer()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .alert(isPresented: $showingAlert) {
            Alert(
                title: Text("Subscription"),
                message: Text(alertMessage),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            checkSubscriptionStatus()
        }
    }
    
    private func categoryIcon(for category: String) -> String {
        switch category.lowercased() {
        case "technology": return "laptopcomputer"
        case "sports": return "sportscourt"
        case "news": return "newspaper"
        case "entertainment": return "tv"
        case "business": return "briefcase"
        case "health": return "heart"
        default: return "bell"
        }
    }
    
    private func checkSubscriptionStatus() {
        subscriptionManager.checkSubscription(channelId: channel.id) { result in
            switch result {
            case .success(let subscribed):
                isSubscribed = subscribed
            case .failure:
                break
            }
        }
    }
    
    private func handleSubscriptionToggle(_ newValue: Bool) {
        if newValue {
            subscriptionManager.subscribe(to: channel.id) { result in
                switch result {
                case .success:
                    alertMessage = "Successfully subscribed to \(channel.name)"
                    showingAlert = true
                case .failure(let error):
                    alertMessage = "Failed to subscribe: \(error.localizedDescription)"
                    showingAlert = true
                    isSubscribed = false
                }
            }
        } else {
            subscriptionManager.unsubscribe(from: channel.id) { result in
                switch result {
                case .success:
                    alertMessage = "Successfully unsubscribed from \(channel.name)"
                    showingAlert = true
                case .failure(let error):
                    alertMessage = "Failed to unsubscribe: \(error.localizedDescription)"
                    showingAlert = true
                    isSubscribed = true
                }
            }
        }
    }
}