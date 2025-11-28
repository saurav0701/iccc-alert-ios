import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authManager: AuthManager
    
    var body: some View {
        TabView {
            AlertsView(authManager: authManager)
                .tabItem {
                    Label("Alerts", systemImage: "bell.fill")
                }
            
            ChannelsView(authManager: authManager)
                .tabItem {
                    Label("Channels", systemImage: "list.bullet")
                }
            
            SettingsView(authManager: authManager)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
    }
}