import SwiftUI

@main
struct ICCCAlertApp: App {
    init() {
        // Initialize managers
        _ = ClientIdManager.shared.getOrCreateClientId()
        WebSocketManager.shared.connect()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

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