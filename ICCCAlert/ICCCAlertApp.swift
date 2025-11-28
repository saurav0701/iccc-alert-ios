import SwiftUI

@main
struct ICCCAlertApp: App {
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var webSocketManager = WebSocketManager.shared
    
    var body: some Scene {
        WindowGroup {
            if authManager.isAuthenticated {
                ContentView()
                    .onAppear {
                        webSocketManager.connect()
                    }
            } else {
                LoginView()
            }
        }
    }
}