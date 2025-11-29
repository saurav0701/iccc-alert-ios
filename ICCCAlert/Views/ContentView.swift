import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            AlertsView(authManager: authManager)
                .tabItem {
                    Label("Alerts", systemImage: selectedTab == 0 ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                }
                .tag(0)
            
            ChannelsView()
                .tabItem {
                    Label("Channels", systemImage: selectedTab == 1 ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                }
                .tag(1)
            
            StatsView()
                .tabItem {
                    Label("Stats", systemImage: selectedTab == 2 ? "chart.bar.fill" : "chart.bar")
                }
                .tag(2)
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: selectedTab == 3 ? "gear.circle.fill" : "gear")
                }
                .tag(3)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AuthManager.shared)
    }
}