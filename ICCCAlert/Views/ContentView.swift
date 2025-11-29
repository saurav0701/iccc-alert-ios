import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authManager: AuthManager
    
    var body: some View {
        TabView {
            AlertsView(authManager: authManager)  // ✅ Pass authManager
                .tabItem {
                    Label("Alerts", systemImage: "exclamationmark.triangle.fill")
                }
            
            ChannelsView(authManager: authManager)  // ✅ Pass authManager
                .tabItem {
                    Label("Channels", systemImage: "list.bullet")
                }
            
            SettingsView()  // ✅ This one uses @EnvironmentObject
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