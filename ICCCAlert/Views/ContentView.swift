import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authManager: AuthManager
    
    var body: some View {
        TabView {
            AlertsView()
                .tabItem {
                    Label("Alerts", systemImage: "exclamationmark.triangle.fill")
                }
            
            ChannelsView()
                .tabItem {
                    Label("Channels", systemImage: "list.bullet")
                }
            
            SettingsView()  // ✅ Fixed - no parameter needed
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AuthManager.shared)
    }
}