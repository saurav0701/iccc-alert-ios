import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Build")
                        Spacer()
                        Text("1")
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text("Notifications")) {
                    Toggle("Enable Notifications", isOn: .constant(true))
                    Toggle("Enable Vibration", isOn: .constant(true))
                }
                
                Section(header: Text("App")) {
                    Button("Clear Cache") {
                        // Action coming soon
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}