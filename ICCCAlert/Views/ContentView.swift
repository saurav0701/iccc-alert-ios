import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            AlertsView()
                .tabItem {
                    Label("Alerts", systemImage: "bell.fill")
                }
            
            ChannelsView()
                .tabItem {
                    Label("Channels", systemImage: "list.bullet")
                }
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
    }
}