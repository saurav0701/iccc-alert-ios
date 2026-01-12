import SwiftUI

// MARK: - Stream Status Overlay
// Visual indicators for stream health, latency, buffer, and connection quality

struct StreamStatusOverlay: View {
    let cameraId: String
    let compact: Bool
    
    @StateObject private var healthMonitor = StreamHealthMonitor.shared
    @StateObject private var bandwidthManager = BandwidthManager.shared
    @State private var showDetailedStats = false
    
    init(cameraId: String, compact: Bool = false) {
        self.cameraId = cameraId
        self.compact = compact
    }
    
    var health: StreamHealthMonitor.StreamHealth? {
        healthMonitor.streamHealths[cameraId]
    }
    
    var body: some View {
        Group {
            if compact {
                compactView
            } else {
                fullView
            }
        }
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                showDetailedStats.toggle()
            }
        }
    }
    
    // MARK: - Compact View (for multi-camera)
    
    private var compactView: some View {
        HStack(spacing: 4) {
            // Connection quality indicator
            Circle()
                .fill(qualityColor)
                .frame(width: 6, height: 6)
            
            // Latency
            if let health = health {
                Text("\(Int(health.latencyMs))ms")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.6))
        )
    }
    
    // MARK: - Full View (for single camera)
    
    private var fullView: some View {
        VStack(spacing: 0) {
            // Main status bar
            HStack(spacing: 8) {
                // Connection quality
                HStack(spacing: 4) {
                    Image(systemName: connectionIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(qualityColor)
                    
                    Text(connectionQuality)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                // Latency
                if let health = health {
                    HStack(spacing: 3) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.8))
                        
                        Text("\(Int(health.latencyMs))ms")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
                
                // Bitrate
                if let health = health, health.bitrateKbps > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "waveform")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.8))
                        
                        Text("\(Int(health.bitrateKbps))k")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
                
                // Buffer health
                if let health = health {
                    bufferIndicator(health: health.bufferHealth)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.7))
            )
            
            // Detailed stats (expandable)
            if showDetailedStats {
                detailedStatsView
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
    
    // MARK: - Detailed Stats View
    
    private var detailedStatsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .background(Color.white.opacity(0.3))
            
            // Network info
            HStack(spacing: 8) {
                Image(systemName: bandwidthManager.networkType.icon)
                    .font(.system(size: 12))
                    .foregroundColor(.blue)
                
                Text(bandwidthManager.networkType.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                
                Spacer()
                
                Text(bandwidthManager.currentBandwidth.rawValue)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
            }
            
            // Recommended quality
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12))
                    .foregroundColor(.purple)
                
                Text("Recommended: \(bandwidthManager.recommendedQuality.rawValue)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
            }
            
            // Reconnect attempts
            if let health = health, health.reconnectAttempts > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    
                    Text("Reconnects: \(health.reconnectAttempts)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                }
            }
            
            // Stall warning
            if let health = health, health.isStalled {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                    
                    Text("Stream Stalled")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.red)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.8))
        )
    }
    
    // MARK: - Buffer Indicator
    
    private func bufferIndicator(health: StreamHealthMonitor.BufferHealth) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bufferBarColor(health: health, index: index))
                    .frame(width: 3, height: 8)
            }
        }
    }
    
    private func bufferBarColor(health: StreamHealthMonitor.BufferHealth, index: Int) -> Color {
        switch health {
        case .healthy:
            return .green
        case .warning:
            return index < 2 ? .orange : .gray.opacity(0.3)
        case .critical:
            return index < 1 ? .red : .gray.opacity(0.3)
        }
    }
    
    // MARK: - Computed Properties
    
    private var qualityColor: Color {
        guard let health = health else { return .gray }
        
        switch health.connectionQuality {
        case .excellent:
            return .green
        case .good:
            return .blue
        case .fair:
            return .orange
        case .poor:
            return .red
        case .unknown:
            return .gray
        }
    }
    
    private var connectionIcon: String {
        guard let health = health else { return "wifi.slash" }
        return health.connectionQuality.icon
    }
    
    private var connectionQuality: String {
        guard let health = health else { return "Unknown" }
        return health.connectionQuality.rawValue
    }
}

// MARK: - Multi-Camera Performance Overlay

struct MultiCameraPerformanceOverlay: View {
    @StateObject private var optimizer = MultiCameraOptimizer.shared
    @StateObject private var bandwidthManager = BandwidthManager.shared
    @State private var showDetails = false
    
    var body: some View {
        VStack {
            HStack {
                Spacer()
                
                VStack(spacing: 8) {
                    // Performance indicator
                    performanceIndicator
                    
                    // Details panel
                    if showDetails {
                        detailsPanel
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            .padding()
            
            Spacer()
        }
    }
    
    private var performanceIndicator: some View {
        HStack(spacing: 8) {
            // Memory indicator
            Circle()
                .fill(memoryColor)
                .frame(width: 8, height: 8)
            
            Text("\(optimizer.activeStreamCount) / \(optimizer.optimizationMode.maxConcurrentStreams)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
            
            Text("\(String(format: "%.0f", optimizer.memoryUsageMB))MB")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
            
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    showDetails.toggle()
                }
            }) {
                Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.7))
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 2)
        )
    }
    
    private var detailsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Optimization mode
            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
                
                Text("Mode: \(optimizer.optimizationMode.rawValue)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
            }
            
            // Network quality
            HStack(spacing: 6) {
                Image(systemName: bandwidthManager.networkType.icon)
                    .font(.system(size: 10))
                    .foregroundColor(.green)
                
                Text(bandwidthManager.currentBandwidth.rawValue.components(separatedBy: " ").first ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            
            // Memory warning
            if optimizer.isMemoryWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    
                    Text("High Memory")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.red)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.8))
        )
    }
    
    private var memoryColor: Color {
        if optimizer.isMemoryWarning {
            return .red
        } else if optimizer.memoryUsageMB > 200 {
            return .orange
        } else {
            return .green
        }
    }
}

// MARK: - Network Status Badge

struct NetworkStatusBadge: View {
    @StateObject private var bandwidthManager = BandwidthManager.shared
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: bandwidthManager.currentBandwidth.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(statusColor)
            
            Text(shortDescription)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.6))
        )
    }
    
    private var statusColor: Color {
        switch bandwidthManager.currentBandwidth {
        case .veryFast:
            return .green
        case .fast:
            return .blue
        case .moderate:
            return .orange
        case .slow, .verySlow:
            return .red
        case .unknown:
            return .gray
        }
    }
    
    private var shortDescription: String {
        switch bandwidthManager.currentBandwidth {
        case .veryFast:
            return "Excellent"
        case .fast:
            return "Good"
        case .moderate:
            return "Fair"
        case .slow:
            return "Slow"
        case .verySlow:
            return "Very Slow"
        case .unknown:
            return "Unknown"
        }
    }
}

// MARK: - Reconnecting Overlay

struct ReconnectingOverlay: View {
    let attempt: Int
    let maxAttempts: Int
    
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.2)
            
            Text("Reconnecting...")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
            
            Text("Attempt \(attempt) of \(maxAttempts)")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.8))
                .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
        )
    }
}

// MARK: - Stream Quality Selector

struct StreamQualitySelector: View {
    @Binding var selectedQuality: BandwidthManager.StreamQuality
    @StateObject private var bandwidthManager = BandwidthManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stream Quality")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            
            ForEach(BandwidthManager.StreamQuality.allCases) { quality in
                qualityOption(quality)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.8))
        )
    }
    
    private func qualityOption(_ quality: BandwidthManager.StreamQuality) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedQuality = quality
            }
        }) {
            HStack(spacing: 12) {
                Image(systemName: quality.icon)
                    .font(.system(size: 16))
                    .foregroundColor(selectedQuality == quality ? .blue : .white)
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(quality.rawValue)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                    
                    Text(quality.resolution)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                }
                
                Spacer()
                
                if quality == bandwidthManager.recommendedQuality {
                    Text("Recommended")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.green.opacity(0.2))
                        )
                }
                
                if selectedQuality == quality {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.blue)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedQuality == quality ? Color.blue.opacity(0.2) : Color.clear)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}