import SwiftUI

struct ChannelsView: View {
    var body: some View {
        NavigationView {
            List {
                Text("Sijua - Crowd Detection")
                Text("Kusunda - Intrusion Detection")
                Text("Barora - Vehicle Detection")
            }
            .navigationTitle("Channels")
        }
    }
}