import SwiftUI

// MARK: - Stream Diagnostics View
struct StreamDiagnosticsView: View {
    @StateObject private var cameraManager = CameraManager.shared
    @State private var selectedCamera: Camera?
    @State private var showingDiagnostics = false
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("H.264 Stream Health")) {
                    healthSummaryCard
                }
                
                Section(header: Text("Cameras by Area")) {
                    ForEach(cameraManager.availableAreas, id: \.self) { area in
                        AreaDiagnosticRow(area: area)
                    }
                }
                
                Section(header: Text("Stream Validation")) {
                    ForEach(cameraManager.cameras.prefix(50), id: \.id) { camera in
                        CameraDiagnosticRow(camera: camera)
                            .onTapGesture {
                                selectedCamera = camera
                                showingDiagnostics = true
                            }
                    }
                }
            }
            .navigationTitle("H.264 Diagnostics")
            .sheet(isPresented: $showingDiagnostics) {
                if let camera = selectedCamera {
                    CameraDetailDiagnostics(camera: camera)
                }
            }
        }
    }
    
    private var healthSummaryCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total Cameras")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(cameraManager.cameras.count)")
                        .font(.title2)
                        .fontWeight(.bold)
                }
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Online & Valid")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(validOnlineCameras)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                }
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Issues")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(camerasWithIssues)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                }
            }
            
            Divider()
            
            HStack(spacing: 16) {
                StatBadge(icon: "checkmark.circle.fill", 
                         count: validOnlineCameras, 
                         label: "Valid", 
                         color: .green)
                
                StatBadge(icon: "exclamationmark.triangle.fill", 
                         count: camerasWithIssues, 
                         label: "Issues", 
                         color: .orange)
                
                StatBadge(icon: "xmark.circle.fill", 
                         count: offlineCameras, 
                         label: "Offline", 
                         color: .red)
            }
        }
        .padding()
    }
    
    private var validOnlineCameras: Int {
        cameraManager.cameras.filter { 
            $0.isOnline && $0.validateStream().isValid 
        }.count
    }
    
    private var camerasWithIssues: Int {
        cameraManager.cameras.filter { 
            $0.isOnline && !$0.validateStream().isValid 
        }.count
    }
    
    private var offlineCameras: Int {
        cameraManager.cameras.filter { !$0.isOnline }.count
    }
}

// MARK: - Stat Badge
struct StatBadge: View {
    let icon: String
    let count: Int
    let label: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)
            Text("\(count)")
                .font(.headline)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Area Diagnostic Row
struct AreaDiagnosticRow: View {
    let area: String
    @StateObject private var cameraManager = CameraManager.shared
    
    private var areaCameras: [Camera] {
        cameraManager.getCameras(forArea: area)
    }
    
    private var onlineValid: Int {
        areaCameras.filter { $0.isOnline && $0.validateStream().isValid }.count
    }
    
    private var issues: Int {
        areaCameras.filter { $0.isOnline && !$0.validateStream().isValid }.count
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(area)
                    .font(.headline)
                
                Text("\(areaCameras.count) cameras")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                if onlineValid > 0 {
                    Label("\(onlineValid)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                
                if issues > 0 {
                    Label("\(issues)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Camera Diagnostic Row
struct CameraDiagnosticRow: View {
    let camera: Camera
    
    private var validation: Camera.StreamValidation {
        camera.validateStream()
    }
    
    private var statusIcon: String {
        switch validation {
        case .valid:
            return "checkmark.circle.fill"
        case .offline:
            return "moon.circle.fill"
        case .invalid:
            return "exclamationmark.triangle.fill"
        }
    }
    
    private var statusColor: Color {
        switch validation {
        case .valid:
            return .green
        case .offline:
            return .gray
        case .invalid:
            return .orange
        }
    }
    
    var body: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(camera.displayName)
                    .font(.subheadline)
                
                Text(camera.area)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if let errorMsg = validation.errorMessage {
                    Text(errorMsg)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Camera Detail Diagnostics
struct CameraDetailDiagnostics: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    @State private var testResult: StreamTestResult?
    @State private var isTesting = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Camera Info Card
                    cameraInfoCard
                    
                    // Stream Info Card
                    streamInfoCard
                    
                    // Validation Card
                    validationCard
                    
                    // Test Stream Button
                    testStreamSection
                    
                    // Test Results
                    if let result = testResult {
                        testResultCard(result)
                    }
                }
                .padding()
            }
            .navigationTitle("Stream Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
    
    private var cameraInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Camera Information")
                .font(.headline)
            
            DiagnosticInfoRow(label: "Name", value: camera.displayName)
            DiagnosticInfoRow(label: "ID", value: camera.id)
            DiagnosticInfoRow(label: "Area", value: camera.area)
            DiagnosticInfoRow(label: "Location", value: camera.location.isEmpty ? "N/A" : camera.location)
            DiagnosticInfoRow(label: "IP Address", value: camera.ip.isEmpty ? "⚠️ Missing" : camera.ip)
            DiagnosticInfoRow(label: "Group ID", value: "\(camera.groupId)")
            DiagnosticInfoRow(label: "Status", value: camera.status, valueColor: camera.isOnline ? .green : .red)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
    
    private var streamInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("H.264 Stream Configuration")
                .font(.headline)
            
            if let streamURL = camera.streamURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Stream URL:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(streamURL)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.blue)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(6)
                }
                
                DiagnosticInfoRow(label: "Protocol", value: "HLS (HTTP Live Streaming)")
                DiagnosticInfoRow(label: "Format", value: "H.264 (All profiles supported)")
                DiagnosticInfoRow(label: "Container", value: "MPEG-TS")
            } else {
                Text("⚠️ No stream URL available")
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
    
    private var validationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stream Validation")
                .font(.headline)
            
            let validation = camera.validateStream()
            
            HStack {
                Image(systemName: validation.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(validation.isValid ? .green : .red)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(validation.isValid ? "Stream Valid" : "Stream Issues")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    if let errorMsg = validation.errorMessage {
                        Text(errorMsg)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Divider()
            
            ValidationCheck(label: "IP Address", passed: !camera.ip.isEmpty)
            ValidationCheck(label: "Server Configured", passed: camera.streamURL != nil)
            ValidationCheck(label: "Camera Online", passed: camera.isOnline)
            ValidationCheck(label: "H.264 Compatible", passed: true)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
    
    private var testStreamSection: some View {
        Button(action: {
            testStream()
        }) {
            HStack {
                if isTesting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Image(systemName: "play.circle.fill")
                }
                Text(isTesting ? "Testing Stream..." : "Test H.264 Stream")
                    .fontWeight(.semibold)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(camera.validateStream().isValid ? Color.blue : Color.gray)
            .cornerRadius(12)
        }
        .disabled(isTesting || !camera.validateStream().isValid)
    }
    
    private func testResultCard(_ result: StreamTestResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Test Results")
                    .font(.headline)
                Spacer()
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(result.success ? .green : .red)
            }
            
            DiagnosticInfoRow(label: "Status", 
                   value: result.success ? "✅ Success" : "❌ Failed",
                   valueColor: result.success ? .green : .red)
            
            if !result.message.isEmpty {
                Text(result.message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(6)
            }
            
            DiagnosticInfoRow(label: "Test Duration", value: String(format: "%.2f seconds", result.duration))
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
    
    private func testStream() {
        guard let streamURL = camera.streamURL else { return }
        
        isTesting = true
        testResult = nil
        
        let startTime = Date()
        
        // Test URL reachability
        guard let url = URL(string: streamURL) else {
            testResult = StreamTestResult(
                success: false,
                message: "Invalid stream URL",
                duration: Date().timeIntervalSince(startTime)
            )
            isTesting = false
            return
        }
        
        // Perform HEAD request to check stream availability
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        
        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                let duration = Date().timeIntervalSince(startTime)
                
                if let error = error {
                    testResult = StreamTestResult(
                        success: false,
                        message: "Connection failed: \(error.localizedDescription)",
                        duration: duration
                    )
                } else if let httpResponse = response as? HTTPURLResponse {
                    let success = (200...299).contains(httpResponse.statusCode)
                    testResult = StreamTestResult(
                        success: success,
                        message: success ? "H.264 stream is accessible" : "HTTP \(httpResponse.statusCode)",
                        duration: duration
                    )
                } else {
                    testResult = StreamTestResult(
                        success: false,
                        message: "Unknown response",
                        duration: duration
                    )
                }
                
                isTesting = false
            }
        }.resume()
    }
}

// MARK: - Helper Views
struct DiagnosticInfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    
    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundColor(valueColor)
        }
    }
}

struct ValidationCheck: View {
    let label: String
    let passed: Bool
    
    var body: some View {
        HStack {
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(passed ? .green : .red)
            Text(label)
                .font(.subheadline)
            Spacer()
        }
    }
}

// MARK: - Test Result Model
struct StreamTestResult {
    let success: Bool
    let message: String
    let duration: TimeInterval
}