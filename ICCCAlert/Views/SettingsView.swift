import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var showLogoutAlert = false
    @State private var notificationsEnabled = true
    
    var body: some View {
        NavigationView {
            Form {
                // Profile Section
                Section(header: Text("Profile")) {
                    if let user = authManager.currentUser {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 50))
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(user.name)
                                    .font(.headline)
                                Text(user.phone ?? "No phone number")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                        
                        HStack {
                            Text("Designation")
                            Spacer()
                            Text(user.designation ?? "N/A")
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Text("Area")
                            Spacer()
                            Text(user.area ?? "N/A")
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Text("Organisation")
                            Spacer()
                            Text(user.organisation ?? "N/A")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                // Notifications Section
                Section(header: Text("Notifications")) {
                    Toggle("Enable Notifications", isOn: $notificationsEnabled)
                    NavigationLink(destination: Text("Notification preferences coming soon")) {
                        HStack {
                            Image(systemName: "bell.badge")
                            Text("Notification Preferences")
                        }
                    }
                }
                
                // Preferences Section
                Section(header: Text("Preferences")) {
                    NavigationLink(destination: Text("Channel subscriptions coming soon")) {
                        HStack {
                            Image(systemName: "star")
                            Text("Manage Subscriptions")
                        }
                    }
                    NavigationLink(destination: Text("Alert filters coming soon")) {
                        HStack {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text("Alert Filters")
                        }
                    }
                }
                
                // App Info Section
                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    NavigationLink(destination: Text("Privacy policy coming soon")) {
                        HStack {
                            Image(systemName: "lock.shield")
                            Text("Privacy Policy")
                        }
                    }
                    NavigationLink(destination: Text("Terms of service coming soon")) {
                        HStack {
                            Image(systemName: "doc.text")
                            Text("Terms of Service")
                        }
                    }
                }
                
                // Account Section
                Section {
                    Button(action: {
                        showLogoutAlert = true
                    }) {
                        HStack {
                            Spacer()
                            Text("Logout")
                                .foregroundColor(.red)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .alert(isPresented: $showLogoutAlert) {
                Alert(
                    title: Text("Logout"),
                    message: Text("Are you sure you want to logout?"),
                    primaryButton: .cancel(),
                    secondaryButton: .destructive(Text("Logout")) {
                        authManager.logout()
                    }
                )
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(AuthManager.shared)
    }
}