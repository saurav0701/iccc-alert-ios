import SwiftUI

struct SettingsView: View {
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var webSocketManager = WebSocketManager.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var showLogoutAlert = false
    
    var body: some View {
        NavigationView {
            List {
                // Profile Section
                if let user = authManager.currentUser {
                    Section(header: Text("Profile")) {
                        HStack {
                            Text("Name")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(user.name)
                        }
                        
                        HStack {
                            Text("Phone")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("+91 \(user.phone)")
                        }
                        
                        HStack {
                            Text("Designation")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(user.designation)
                        }
                        
                        HStack {
                            Text("Area")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(user.area)
                        }
                        
                        HStack {
                            Text("Working For")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(user.workingFor)
                        }
                    }
                }
                
                // Subscription Info
                Section(header: Text("Subscriptions")) {
                    HStack {
                        Text("Active Channels")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(subscriptionManager.subscribedChannels.count)")
                            .fontWeight(.semibold)
                    }
                    
                    HStack {
                        Text("Total Events")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(webSocketManager.events.count)")
                            .fontWeight(.semibold)
                    }
                }
                
                // Connection Status
                Section(header: Text("Connection")) {
                    HStack {
                        Text("Status")
                            .foregroundColor(.secondary)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(webSocketManager.isConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(webSocketManager.isConnected ? "Connected" : "Disconnected")
                                .foregroundColor(webSocketManager.isConnected ? .green : .red)
                        }
                    }
                    
                    if !webSocketManager.isConnected {
                        Button("Reconnect") {
                            webSocketManager.connect()
                        }
                    }
                }
                
                // App Info
                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("1.0.0")
                    }
                    
                    HStack {
                        Text("Platform")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("iOS")
                    }
                }
                
                // Logout
                Section {
                    Button(action: {
                        showLogoutAlert = true
                    }) {
                        HStack {
                            Spacer()
                            Text("Logout")
                                .foregroundColor(.red)
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Logout", isPresented: $showLogoutAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Logout", role: .destructive) {
                    webSocketManager.disconnect()
                    authManager.logout()
                }
            } message: {
                Text("Are you sure you want to logout?")
            }
        }
    }
}