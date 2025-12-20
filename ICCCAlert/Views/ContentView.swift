import SwiftUI

struct ContentView: View {
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
            
            // ✅ DEBUG TAB (remove in production)
            DebugView()
                .tabItem {
                    Image(systemName: "ladybug")
                    Text("Debug")
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