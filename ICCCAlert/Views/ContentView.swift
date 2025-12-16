import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            AlertsView()
                .tabItem {
                    Image(systemName: "bell.fill")
                    Text("Alerts")
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