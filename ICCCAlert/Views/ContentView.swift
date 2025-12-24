import SwiftUI

struct ContentView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            AlertsView()
                .tabItem {
                    Image(systemName: "bell.fill")
                    Text("Alerts")
                }
                .tag(0)
            
            SavedEventsView()
                .tabItem {
                    Image(systemName: "bookmark.fill")
                    Text("Saved")
                }
                .tag(1)
            
            // ✅ NEW: Camera Streams Tab
            CameraStreamsView()
                .tabItem {
                    Image(systemName: "video.fill")
                    Text("Cameras")
                }
                .tag(2)
            
            ChannelsView()
                .tabItem {
                    Image(systemName: "list.bullet")
                    Text("Channels")
                }
                .tag(3)
            
            SettingsView()
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
                }
                .tag(4)
        }
        .accentColor(.blue)
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