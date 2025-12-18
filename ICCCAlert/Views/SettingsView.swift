import SwiftUI

struct SettingsView: View {
    @StateObject private var authManager = AuthManager.shared
    @State private var showLogoutAlert = false
    
    var body: some View {
        NavigationView {
            List {
                // ✅ FIXED: Use proper Section syntax for iOS 14+
                Section {
                    if let user = authManager.currentUser {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(user.name)
                                .font(.headline)
                            Text("+91 \(user.phone)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text(user.designation)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text(user.area)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                } header: {
                    Text("Profile")
                }
                
                Section {
                    HStack {
                        Text("Organization")
                        Spacer()
                        // ✅ FIXED: Changed from workingFor to organisation
                        Text(authManager.currentUser?.organisation ?? "Unknown")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Subscriptions")
                        Spacer()
                        Text("\(SubscriptionManager.shared.subscribedChannels.count)")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Total Events")
                        Spacer()
                        Text("\(SubscriptionManager.shared.getTotalEventCount())")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Account")
                }
                
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
                } header: {
                    Text("Actions")
                }
                
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Build")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .alert(isPresented: $showLogoutAlert) {
                Alert(
                    title: Text("Logout"),
                    message: Text("Are you sure you want to logout?"),
                    primaryButton: .destructive(Text("Logout")) {
                        performLogout()
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }
    
    private func performLogout() {
        authManager.logout { success in
            // Auth manager will automatically update isAuthenticated
            print("Logout \(success ? "successful" : "failed")")
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}