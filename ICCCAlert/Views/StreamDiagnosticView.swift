import SwiftUI

struct StreamDiagnosticView: View {
    let camera: Camera
    @State private var diagnosticResult: DiagnosticResult?
    @State private var isRunning = false
    @Environment(\.presentationMode) var presentationMode
    
    struct DiagnosticResult {
        var manifestAccessible: Bool = false
        var manifestError: String?
        var segmentAccessible: Bool = false
        var segmentError: String?
        var responseTime: TimeInterval = 0
        var contentType: String?
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Camera Info
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Camera Information")
                            .font(.headline)
                        
                        DiagnosticInfoRow(label: "Name", value: camera.displayName)
                        DiagnosticInfoRow(label: "ID", value: camera.id)
                        DiagnosticInfoRow(label: "Area", value: camera.area)
                        DiagnosticInfoRow(label: "Status", value: camera.status)
                        DiagnosticInfoRow(label: "Group ID", value: "\(camera.groupId)")
                        
                        if let streamURL = camera.streamURL {
                            DiagnosticInfoRow(label: "Stream URL", value: streamURL)
                                .font(.caption)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    
                    // Diagnostic Button
                    Button(action: runDiagnostics) {
                        HStack {
                            if isRunning {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                Text("Running Diagnostics...")
                            } else {
                                Image(systemName: "stethoscope")
                                Text("Run Stream Diagnostics")
                            }
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isRunning ? Color.gray : Color.blue)
                        .cornerRadius(12)
                    }
                    .disabled(isRunning)
                    
                    // Results
                    if let result = diagnosticResult {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Diagnostic Results")
                                .font(.headline)
                            
                            DiagnosticRow(
                                title: "Manifest (.m3u8) Access",
                                status: result.manifestAccessible,
                                error: result.manifestError
                            )
                            
                            DiagnosticRow(
                                title: "Video Segment Access",
                                status: result.segmentAccessible,
                                error: result.segmentError
                            )
                            
                            if result.manifestAccessible {
                                HStack {
                                    Text("Response Time:")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(String(format: "%.2f ms", result.responseTime * 1000))
                                        .fontWeight(.medium)
                                }
                                
                                if let contentType = result.contentType {
                                    HStack {
                                        Text("Content Type:")
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text(contentType)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                    }
                                }
                            }
                            
                            // Recommendations
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Recommendations:")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                
                                if !result.manifestAccessible {
                                    RecommendationText("• Check network connection")
                                    RecommendationText("• Verify server is online")
                                    RecommendationText("• Check firewall settings")
                                } else if !result.segmentAccessible {
                                    RecommendationText("• Manifest found but segments missing")
                                    RecommendationText("• Server may be transcoding")
                                    RecommendationText("• Wait a moment and try again")
                                } else {
                                    RecommendationText("✅ Stream appears healthy")
                                }
                            }
                            .padding(.top, 8)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }
                    
                    Spacer()
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
    
    private func runDiagnostics() {
        guard let streamURL = camera.streamURL else { return }
        
        isRunning = true
        var result = DiagnosticResult()
        
        let startTime = Date()
        
        // Test manifest access
        guard let url = URL(string: streamURL) else {
            result.manifestError = "Invalid URL"
            diagnosticResult = result
            isRunning = false
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    result.manifestError = error.localizedDescription
                    result.manifestAccessible = false
                    diagnosticResult = result
                    isRunning = false
                } else if let httpResponse = response as? HTTPURLResponse {
                    result.responseTime = Date().timeIntervalSince(startTime)
                    result.contentType = httpResponse.mimeType
                    
                    if httpResponse.statusCode == 200 {
                        result.manifestAccessible = true
                        
                        // Try to parse manifest and check first segment
                        if let data = data, let manifest = String(data: data, encoding: .utf8) {
                            checkFirstSegment(manifest: manifest, baseURL: streamURL) { accessible, error in
                                result.segmentAccessible = accessible
                                result.segmentError = error
                                diagnosticResult = result
                                isRunning = false
                            }
                        } else {
                            diagnosticResult = result
                            isRunning = false
                        }
                    } else {
                        result.manifestError = "HTTP \(httpResponse.statusCode)"
                        result.manifestAccessible = false
                    }
                }
                
                diagnosticResult = result
                isRunning = false
            }
        }.resume()
    }
    
    private func checkFirstSegment(manifest: String, baseURL: String, completion: @escaping (Bool, String?) -> Void) {
        // Parse manifest for first .ts segment
        let lines = manifest.components(separatedBy: .newlines)
        var segmentURL: String?
        
        for line in lines {
            if line.hasSuffix(".ts") {
                segmentURL = line
                break
            }
        }
        
        guard let segment = segmentURL else {
            completion(false, "No segments found in manifest")
            return
        }
        
        // Construct full segment URL
        let fullSegmentURL: String
        if segment.hasPrefix("http") {
            fullSegmentURL = segment
        } else {
            // Relative URL - construct from base
            if let baseURLObj = URL(string: baseURL),
               let segmentURLObj = URL(string: segment, relativeTo: baseURLObj) {
                fullSegmentURL = segmentURLObj.absoluteString
            } else {
                completion(false, "Could not construct segment URL")
                return
            }
        }
        
        // Test segment access
        guard let url = URL(string: fullSegmentURL) else {
            completion(false, "Invalid segment URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = "HEAD"
        
        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(false, error.localizedDescription)
                } else if let httpResponse = response as? HTTPURLResponse {
                    let accessible = (httpResponse.statusCode == 200)
                    let errorMsg = accessible ? nil : "HTTP \(httpResponse.statusCode)"
                    completion(accessible, errorMsg)
                }
            }
        }.resume()
    }
}

// MARK: - Private Helper Views
private struct DiagnosticInfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label + ":")
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct DiagnosticRow: View {
    let title: String
    let status: Bool
    let error: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: status ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(status ? .green : .red)
                Text(title)
                    .fontWeight(.medium)
            }
            
            if let error = error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.leading, 24)
            }
        }
    }
}

struct RecommendationText: View {
    let text: String
    
    init(_ text: String) {
        self.text = text
    }
    
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
    }
}