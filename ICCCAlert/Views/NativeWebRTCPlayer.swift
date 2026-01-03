import Foundation
import UIKit
import WebRTC
import SwiftUI
import Combine

// MARK: - Native WebRTC Player (MEMORY OPTIMIZED)
class NativeWebRTCPlayer: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var isConnected = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // MARK: - Private Properties
    private var peerConnection: RTCPeerConnection?
    private var videoTrack: RTCVideoTrack?
    private var remoteVideoView: RTCMTLVideoView?
    
    private let streamURL: String
    private let cameraId: String
    
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
    }()
    
    private var isActive = false
    
    // MARK: - Initialization
    init(cameraId: String, streamURL: String) {
        self.cameraId = cameraId
        self.streamURL = streamURL
        super.init()
        
        DebugLogger.shared.log("🎬 NativeWebRTCPlayer created: \(cameraId)", emoji: "🎬", color: .blue)
        DebugLogger.shared.log("📍 Stream URL: \(streamURL)", emoji: "📍", color: .blue)
    }
    
    // MARK: - Public Methods
    
    func start() -> UIView {
        guard !isActive else {
            DebugLogger.shared.log("⚠️ Already active", emoji: "⚠️", color: .orange)
            return remoteVideoView ?? UIView()
        }
        
        isActive = true
        isLoading = true
        
        DebugLogger.shared.log("▶️ Starting native WebRTC stream", emoji: "▶️", color: .green)
        
        // Create video view
        let videoView = RTCMTLVideoView(frame: .zero)
        videoView.contentMode = .scaleAspectFit
        videoView.backgroundColor = .black
        self.remoteVideoView = videoView
        
        // Setup peer connection
        setupPeerConnection()
        
        return videoView
    }
    
    func stop() {
        guard isActive else { return }
        
        DebugLogger.shared.log("⏹️ Stopping native WebRTC stream", emoji: "⏹️", color: .orange)
        
        isActive = false
        isConnected = false
        isLoading = false
        
        cleanup()
    }
    
    // MARK: - WebRTC Setup
    
    private func setupPeerConnection() {
        // Create configuration
        let config = RTCConfiguration()
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
        ]
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        
        // Create constraints
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        
        // Create peer connection
        let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)
        
        self.peerConnection = pc
        
        // Add transceivers for receive-only
        let videoTransceiverInit = RTCRtpTransceiverInit()
        videoTransceiverInit.direction = .recvOnly
        pc.addTransceiver(of: .video, init: videoTransceiverInit)
        
        let audioTransceiverInit = RTCRtpTransceiverInit()
        audioTransceiverInit.direction = .recvOnly
        pc.addTransceiver(of: .audio, init: audioTransceiverInit)
        
        DebugLogger.shared.log("✅ Peer connection created", emoji: "✅", color: .green)
        
        // Create offer
        createOffer()
    }
    
    private func createOffer() {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveVideo": "true",
                "OfferToReceiveAudio": "true"
            ],
            optionalConstraints: nil
        )
        
        peerConnection?.offer(for: constraints) { [weak self] sdp, error in
            guard let self = self else { return }
            
            if let error = error {
                DebugLogger.shared.log("❌ Create offer failed: \(error.localizedDescription)", emoji: "❌", color: .red)
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to create offer"
                    self.isLoading = false
                }
                return
            }
            
            guard let sdp = sdp else {
                DebugLogger.shared.log("❌ No SDP in offer", emoji: "❌", color: .red)
                DispatchQueue.main.async {
                    self.errorMessage = "No SDP in offer"
                    self.isLoading = false
                }
                return
            }
            
            DebugLogger.shared.log("✅ Offer created (\(sdp.sdp.count) bytes)", emoji: "✅", color: .green)
            
            // Set local description
            self.peerConnection?.setLocalDescription(sdp) { error in
                if let error = error {
                    DebugLogger.shared.log("❌ Set local description failed: \(error.localizedDescription)", emoji: "❌", color: .red)
                    DispatchQueue.main.async {
                        self.errorMessage = "Failed to set local description"
                        self.isLoading = false
                    }
                    return
                }
                
                DebugLogger.shared.log("✅ Local description set", emoji: "✅", color: .green)
                
                // Send offer to server
                self.sendOfferToServer(sdp: sdp.sdp)
            }
        }
    }
    
    private func sendOfferToServer(sdp: String) {
        guard let url = URL(string: streamURL) else {
            DebugLogger.shared.log("❌ Invalid stream URL: \(streamURL)", emoji: "❌", color: .red)
            DispatchQueue.main.async {
                self.errorMessage = "Invalid stream URL"
                self.isLoading = false
            }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue("application/sdp", forHTTPHeaderField: "Accept")  // ← ADDED
        request.httpBody = sdp.data(using: .utf8)
        request.timeoutInterval = 15  // Increased timeout
        
        DebugLogger.shared.log("📤 Sending WHEP offer to: \(streamURL)", emoji: "📤", color: .blue)
        DebugLogger.shared.log("📤 SDP size: \(sdp.count) bytes", emoji: "📤", color: .blue)
        
        let startTime = Date()
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            let elapsed = Date().timeIntervalSince(startTime)
            DebugLogger.shared.log("⏱️ Request took \(String(format: "%.2f", elapsed))s", emoji: "⏱️", color: .blue)
            
            // Check for network errors
            if let error = error {
                let nsError = error as NSError
                DebugLogger.shared.log("❌ Network error: \(error.localizedDescription)", emoji: "❌", color: .red)
                DebugLogger.shared.log("❌ Error domain: \(nsError.domain), code: \(nsError.code)", emoji: "❌", color: .red)
                
                DispatchQueue.main.async {
                    self.errorMessage = "Connection failed: \(error.localizedDescription)"
                    self.isLoading = false
                }
                return
            }
            
            // Check HTTP response
            guard let httpResponse = response as? HTTPURLResponse else {
                DebugLogger.shared.log("❌ No HTTP response", emoji: "❌", color: .red)
                DispatchQueue.main.async {
                    self.errorMessage = "No server response"
                    self.isLoading = false
                }
                return
            }
            
            DebugLogger.shared.log("📥 HTTP Status: \(httpResponse.statusCode)", emoji: "📥", color: .blue)
            DebugLogger.shared.log("📥 Headers: \(httpResponse.allHeaderFields)", emoji: "📥", color: .gray)
            
            // Log response body for debugging
            if let data = data {
                DebugLogger.shared.log("📥 Response size: \(data.count) bytes", emoji: "📥", color: .blue)
                if let bodyString = String(data: data, encoding: .utf8) {
                    DebugLogger.shared.log("📄 Response body: \(bodyString.prefix(500))...", emoji: "📄", color: .gray)
                }
            }
            
            // Accept both 200 and 201 status codes
            guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
                let errorMsg: String
                if let data = data, let body = String(data: data, encoding: .utf8) {
                    errorMsg = "Server error (\(httpResponse.statusCode)): \(body)"
                } else {
                    errorMsg = "Server error: \(httpResponse.statusCode)"
                }
                
                DebugLogger.shared.log("❌ \(errorMsg)", emoji: "❌", color: .red)
                
                DispatchQueue.main.async {
                    self.errorMessage = errorMsg
                    self.isLoading = false
                }
                return
            }
            
            // Get SDP answer
            guard let data = data, let answerSDP = String(data: data, encoding: .utf8), !answerSDP.isEmpty else {
                DebugLogger.shared.log("❌ No SDP answer from server", emoji: "❌", color: .red)
                DispatchQueue.main.async {
                    self.errorMessage = "No answer from server"
                    self.isLoading = false
                }
                return
            }
            
            DebugLogger.shared.log("✅ Received SDP answer (\(answerSDP.count) bytes)", emoji: "✅", color: .green)
            
            // Set remote description
            let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
            
            self.peerConnection?.setRemoteDescription(answer) { error in
                if let error = error {
                    DebugLogger.shared.log("❌ Set remote description failed: \(error.localizedDescription)", emoji: "❌", color: .red)
                    DispatchQueue.main.async {
                        self.errorMessage = "Failed to process server response"
                        self.isLoading = false
                    }
                    return
                }
                
                DebugLogger.shared.log("✅ Remote description set - waiting for ICE", emoji: "✅", color: .green)
                DispatchQueue.main.async {
                    self.isLoading = false  // Will show "Connecting..." until ICE completes
                }
            }
            
        }.resume()
    }
    
    // MARK: - Cleanup
    
    private func cleanup() {
        DebugLogger.shared.log("🧹 Cleaning up native WebRTC", emoji: "🧹", color: .gray)
        
        // Remove video track from view
        if let track = videoTrack, let view = remoteVideoView {
            track.remove(view)
        }
        
        // Close peer connection
        peerConnection?.close()
        
        // Clear references
        videoTrack = nil
        peerConnection = nil
        
        // Force memory cleanup
        autoreleasepool {}
        
        DebugLogger.shared.log("✅ Native WebRTC cleanup complete", emoji: "✅", color: .green)
    }
    
    deinit {
        DebugLogger.shared.log("♻️ NativeWebRTCPlayer deinit: \(cameraId)", emoji: "♻️", color: .gray)
        cleanup()
    }
}

// MARK: - RTCPeerConnectionDelegate
extension NativeWebRTCPlayer: RTCPeerConnectionDelegate {
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        DebugLogger.shared.log("📡 Signaling state: \(stateChanged.rawValue)", emoji: "📡", color: .blue)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        DebugLogger.shared.log("🎥 Media stream added", emoji: "🎥", color: .green)
        
        guard let videoTrack = stream.videoTracks.first else {
            DebugLogger.shared.log("⚠️ No video track in stream", emoji: "⚠️", color: .orange)
            return
        }
        
        DebugLogger.shared.log("✅ Video track found", emoji: "✅", color: .green)
        
        self.videoTrack = videoTrack
        
        DispatchQueue.main.async {
            if let videoView = self.remoteVideoView {
                videoTrack.add(videoView)
                self.isConnected = true
                self.isLoading = false
                DebugLogger.shared.log("✅ Video rendering started", emoji: "✅", color: .green)
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        DebugLogger.shared.log("📴 Media stream removed", emoji: "📴", color: .orange)
        
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        DebugLogger.shared.log("🔄 Should negotiate", emoji: "🔄", color: .blue)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DebugLogger.shared.log("❄️ ICE connection state: \(newState.rawValue)", emoji: "❄️", color: .blue)
        
        DispatchQueue.main.async {
            switch newState {
            case .connected, .completed:
                self.isConnected = true
                self.isLoading = false
                DebugLogger.shared.log("✅ ICE Connected!", emoji: "✅", color: .green)
                
            case .disconnected:
                self.isConnected = false
                DebugLogger.shared.log("⚠️ ICE Disconnected", emoji: "⚠️", color: .orange)
                
            case .failed:
                self.isConnected = false
                self.errorMessage = "Connection failed - check network"
                DebugLogger.shared.log("❌ ICE Connection failed", emoji: "❌", color: .red)
                
            case .closed:
                self.isConnected = false
                DebugLogger.shared.log("🔒 ICE Connection closed", emoji: "🔒", color: .gray)
                
            case .checking:
                DebugLogger.shared.log("🔍 ICE Checking...", emoji: "🔍", color: .blue)
                
            default:
                break
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        DebugLogger.shared.log("❄️ ICE gathering state: \(newState.rawValue)", emoji: "❄️", color: .blue)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        DebugLogger.shared.log("🧊 ICE candidate: \(candidate.sdp)", emoji: "🧊", color: .gray)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        DebugLogger.shared.log("🗑️ ICE candidates removed: \(candidates.count)", emoji: "🗑️", color: .gray)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        DebugLogger.shared.log("📡 Data channel opened", emoji: "📡", color: .blue)
    }
}

// MARK: - UIViewRepresentable for SwiftUI
struct NativeWebRTCPlayerView: UIViewRepresentable {
    @StateObject private var player: NativeWebRTCPlayer
    
    init(cameraId: String, streamURL: String) {
        _player = StateObject(wrappedValue: NativeWebRTCPlayer(cameraId: cameraId, streamURL: streamURL))
    }
    
    func makeUIView(context: Context) -> UIView {
        return player.start()
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // No updates needed
    }
    
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        // Cleanup handled by player deinit
    }
}