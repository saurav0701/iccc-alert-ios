import SwiftUI

struct DebugLogsView: View {
    @State private var logs: [String] = []
    @State private var showLogs = false
    
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Debug Logs")
                    .font(.headline)
                Spacer()
                Button(action: { logs = DebugLogger.shared.getLogs() }) {
                    Image(systemName: "arrow.clockwise")
                }
                Button(action: { DebugLogger.shared.clearLogs(); logs = [] }) {
                    Image(systemName: "trash")
                }
            }
            
            if logs.isEmpty {
                Text("No logs yet")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(logs, id: \.self) { log in
                            Text(log)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(nil)
                                .padding(.vertical, 2)
                        }
                    }
                    .padding(.horizontal)
                }
                .background(Color(.systemGray6))
                .cornerRadius(8)
                
                HStack {
                    Button(action: {
                        UIPasteboard.general.string = DebugLogger.shared.getLogsAsString()
                    }) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Spacer()
                    Text("\(logs.count) logs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .onAppear {
            logs = DebugLogger.shared.getLogs()
        }
    }
}

struct DebugLogsView_Previews: PreviewProvider {
    static var previews: some View {
        DebugLogsView()
    }
}
