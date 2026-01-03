import Foundation
import WebRTC
import Combine

// MARK: - Native WebRTC Service
class NativeWebRTCService: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var connectionState: RTCIceConnectionState = .new
    @Published var remoteVideoTrack: RTCVideoTrack?
    @Published var isConnected = false
    @Published var memoryUsageMB: Double = 0.0
    
    // MARK: - Private Properties
    private var peerConnection: RTCPeerConnection?
    private let factory: RTCPeerConnectionFactory
    private var videoCapturer: RTCVideoCapturer?
    private var memoryTimer: Timer?
    private let streamURL: String
    private let cameraId: String
    
    // MARK: - WebRTC Configuration
    private let config: RTCConfiguration = {
        let config = RTCConfiguration()
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])
        ]
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        return config
    }()
    
    private let constraints: RTCMediaConstraints = {
        let mandatoryConstraints = [
            "OfferToReceiveAudio": "true",
            "OfferToReceiveVideo": "true"
        ]
        return RTCMediaConstraints(
            mandatoryConstraints: mandatoryConstraints,
            optionalConstraints: nil
        )
    }()
    
    // MARK: - Initialization
    init(streamURL: String, cameraId: String) {
        self.streamURL = streamURL
        self.cameraId = cameraId
        
        // Initialize WebRTC
        RTCInitializeSSL()
        
        // Create factory with hardware acceleration
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: videoEncoderFactory,
            decoderFactory: videoDecoderFactory
        )
        
        super.init()
        
        DebugLogger.shared.log("🎬 NativeWebRTC initialized: \(cameraId)", emoji: "🎬", color: .blue)
        startMemoryMonitoring()
    }
    
    // MARK: - Connection Management
    func connect() {
        DebugLogger.shared.log("🔌 Connecting: \(cameraId)", emoji: "🔌", color: .blue)
        
        // Create peer connection
        guard let pc = factory.peerConnection(
            with: config,
            constraints: RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: nil
            ),
            delegate: self
        ) else {
            DebugLogger.shared.log("❌ Failed to create peer connection", emoji: "❌", color: .red)
            return
        }
        
        self.peerConnection = pc
        
        // Add transceivers for receiving only (FIXED: Use init with direction)
        let videoInit = RTCRtpTransceiverInit()
        videoInit.direction = .recvOnly
        pc.addTransceiver(of: .video, init: videoInit)
        
        let audioInit = RTCRtpTransceiverInit()
        audioInit.direction = .recvOnly
        pc.addTransceiver(of: .audio, init: audioInit)
        
        // Create and send offer
        pc.offer(for: constraints) { [weak self] sdp, error in
            guard let self = self else { return }
            
            if let error = error {
                DebugLogger.shared.log("❌ Offer error: \(error)", emoji: "❌", color: .red)
                return
            }
            
            guard let sdp = sdp else {
                DebugLogger.shared.log("❌ No SDP in offer", emoji: "❌", color: .red)
                return
            }
            
            // Set local description
            pc.setLocalDescription(sdp) { error in
                if let error = error {
                    DebugLogger.shared.log("❌ Set local SDP error: \(error)", emoji: "❌", color: .red)
                    return
                }
                
                // Send offer to server
                self.sendOffer(sdp: sdp.sdp)
            }
        }
    }
    
    private func sendOffer(sdp: String) {
        guard let url = URL(string: streamURL) else {
            DebugLogger.shared.log("❌ Invalid stream URL", emoji: "❌", color: .red)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = sdp.data(using: .utf8)
        request.timeoutInterval = 10.0
        
        DebugLogger.shared.log("📤 Sending offer to: \(streamURL)", emoji: "📤", color: .blue)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                DebugLogger.shared.log("❌ WHEP error: \(error.localizedDescription)", emoji: "❌", color: .red)
                return
            }
            
            guard let data = data,
                  let answerSDP = String(data: data, encoding: .utf8) else {
                DebugLogger.shared.log("❌ Invalid answer from server", emoji: "❌", color: .red)
                return
            }
            
            DebugLogger.shared.log("✅ Received answer from server", emoji: "✅", color: .green)
            
            // Set remote description
            let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
            self.peerConnection?.setRemoteDescription(answer) { error in
                if let error = error {
                    DebugLogger.shared.log("❌ Set remote SDP error: \(error)", emoji: "❌", color: .red)
                } else {
                    DebugLogger.shared.log("✅ Remote SDP set successfully", emoji: "✅", color: .green)
                }
            }
        }.resume()
    }
    
    func disconnect() {
        DebugLogger.shared.log("🔌 Disconnecting: \(cameraId)", emoji: "🔌", color: .orange)
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.remoteVideoTrack = nil
        }
        
        // Close peer connection
        peerConnection?.close()
        peerConnection = nil
        
        // Stop memory monitoring
        memoryTimer?.invalidate()
        memoryTimer = nil
        
        // Force cleanup
        autoreleasepool {}
        
        DebugLogger.shared.log("✅ Disconnected: \(cameraId)", emoji: "✅", color: .green)
    }
    
    // MARK: - Memory Monitoring
    private func startMemoryMonitoring() {
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateMemory()
        }
    }
    
    private func updateMemory() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        guard kerr == KERN_SUCCESS else { return }
        
        let usedMB = Double(info.resident_size) / 1024 / 1024
        
        DispatchQueue.main.async {
            self.memoryUsageMB = usedMB
            
            // Warning at 150MB
            if usedMB > 150 {
                DebugLogger.shared.log("⚠️ High memory: \(Int(usedMB))MB", emoji: "⚠️", color: .orange)
            }
            
            // Auto-disconnect at 180MB (safety)
            if usedMB > 180 {
                DebugLogger.shared.log("🚨 Critical memory: \(Int(usedMB))MB - disconnecting", emoji: "🚨", color: .red)
                self.disconnect()
            }
        }
    }
    
    deinit {
        DebugLogger.shared.log("♻️ NativeWebRTC deinit: \(cameraId)", emoji: "♻️", color: .gray)
        disconnect()
        RTCCleanupSSL()
    }
}

// MARK: - RTCPeerConnectionDelegate
extension NativeWebRTCService: RTCPeerConnectionDelegate {
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        DebugLogger.shared.log("📡 Signaling: \(stateChanged.rawValue)", emoji: "📡", color: .blue)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        DebugLogger.shared.log("📹 Stream added (deprecated)", emoji: "📹", color: .gray)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        DebugLogger.shared.log("📹 Stream removed", emoji: "📹", color: .orange)
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        DebugLogger.shared.log("🔄 Should negotiate", emoji: "🔄", color: .blue)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DebugLogger.shared.log("🧊 ICE: \(newState.description)", emoji: "🧊", color: .blue)
        
        DispatchQueue.main.async {
            self.connectionState = newState
            
            switch newState {
            case .connected, .completed:
                self.isConnected = true
                DebugLogger.shared.log("✅ Connected!", emoji: "✅", color: .green)
                
            case .failed, .disconnected, .closed:
                self.isConnected = false
                DebugLogger.shared.log("❌ Disconnected: \(newState)", emoji: "❌", color: .red)
                
            default:
                self.isConnected = false
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        DebugLogger.shared.log("📡 ICE Gathering: \(newState.rawValue)", emoji: "📡", color: .gray)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // Trickle ICE not needed for WHEP
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        // Not needed
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        DebugLogger.shared.log("📡 Data channel opened", emoji: "📡", color: .blue)
    }
    
    // CRITICAL: Handle track events (replaces deprecated stream API)
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd receiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        DebugLogger.shared.log("📹 Track added: \(receiver.track?.kind ?? "unknown")", emoji: "📹", color: .green)
        
        if let track = receiver.track as? RTCVideoTrack {
            DispatchQueue.main.async {
                self.remoteVideoTrack = track
                DebugLogger.shared.log("✅ Video track ready!", emoji: "✅", color: .green)
            }
        }
    }
}

// MARK: - ICE Connection State Extension
extension RTCIceConnectionState {
    var description: String {
        switch self {
        case .new: return "New"
        case .checking: return "Checking"
        case .connected: return "Connected"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .disconnected: return "Disconnected"
        case .closed: return "Closed"
        case .count: return "Count"
        @unknown default: return "Unknown"
        }
    }
}