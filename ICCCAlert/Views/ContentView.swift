import SwiftUI

struct ContentView: View {
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var pipManager = PiPManager.shared
    @State private var selectedTab = 0
    @State private var fullscreenCamera: Camera?
    
    var body: some View {
        ZStack {
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
            
            // Picture-in-Picture Window (overlays on top of all tabs)
            if pipManager.isPiPActive {
                PiPWindowView()
                    .zIndex(999)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .fullScreenCover(item: $fullscreenCamera) { camera in
            UnifiedCameraPlayerView(camera: camera)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenCameraFullscreen"))) { notification in
            if let camera = notification.object as? Camera {
                pipManager.stopPiP()
                fullscreenCamera = camera
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