import SwiftUI

struct ContentView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    
    var body: some View {
        TabView {
            AlertsView()
                .tabItem {
                    Image(systemName: "bell.fill")
                    Text("Alerts")
                }
            
            SavedEventsView()
                .tabItem {
                    Image(systemName: "bookmark.fill")
                    Text("Saved")
                }
            
            ChannelsView()
                .tabItem {
                    Image(systemName: "list.bullet")
                    Text("Channels")
                }
            
            SettingsView()
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
                }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AuthManager.shared)
            .environmentObject(WebSocketService.shared)
            .environmentObject(SubscriptionManager.shared)
    }
}