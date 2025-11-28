import SwiftUI

@main
struct ICCCAlertApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                AlertsView()
                    .tabItem {
                        Label("Alerts", systemImage: "bell.fill")
                    }
                
                Text("Channels")
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
}