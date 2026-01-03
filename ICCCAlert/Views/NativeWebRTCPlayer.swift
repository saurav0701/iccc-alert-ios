import Foundation
import UIKit
import WebRTC
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
        guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            DebugLogger.shared.log("❌ Failed to create peer connection", emoji: "❌", color: .red)
            errorMessage = "Failed to create peer connection"
            isLoading = false
            return
        }
        
        self.peerConnection = pc
        
        // Add transceivers for receive-only
        pc.addTransceiver(of: .video, init: { transceiver in
            transceiver.direction = .recvOnly
        })
        
        pc.addTransceiver(of: .audio, init: { transceiver in
            transceiver.direction = .recvOnly
        })
        
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
                self.errorMessage = "Failed to create offer"
                self.isLoading = false
                return
            }
            
            guard let sdp = sdp else {
                DebugLogger.shared.log("❌ No SDP in offer", emoji: "❌", color: .red)
                self.errorMessage = "No SDP in offer"
                self.isLoading = false
                return
            }
            
            DebugLogger.shared.log("✅ Offer created", emoji: "✅", color: .green)
            
            // Set local description
            self.peerConnection?.setLocalDescription(sdp) { error in
                if let error = error {
                    DebugLogger.shared.log("❌ Set local description failed: \(error.localizedDescription)", emoji: "❌", color: .red)
                    self.errorMessage = "Failed to set local description"
                    self.isLoading = false
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
            DebugLogger.shared.log("❌ Invalid stream URL", emoji: "❌", color: .red)
            errorMessage = "Invalid stream URL"
            isLoading = false
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = sdp.data(using: .utf8)
        request.timeoutInterval = 10
        
        DebugLogger.shared.log("📤 Sending offer to server...", emoji: "📤", color: .blue)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                DebugLogger.shared.log("❌ Server request failed: \(error.localizedDescription)", emoji: "❌", color: .red)
                DispatchQueue.main.async {
                    self.errorMessage = "Server connection failed"
                    self.isLoading = false
                }
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                DebugLogger.shared.log("❌ Server returned error", emoji: "❌", color: .red)
                DispatchQueue.main.async {
                    self.errorMessage = "Server error"
                    self.isLoading = false
                }
                return
            }
            
            guard let data = data, let answerSDP = String(data: data, encoding: .utf8) else {
                DebugLogger.shared.log("❌ No answer from server", emoji: "❌", color: .red)
                DispatchQueue.main.async {
                    self.errorMessage = "No answer from server"
                    self.isLoading = false
                }
                return
            }
            
            DebugLogger.shared.log("✅ Received answer from server", emoji: "✅", color: .green)
            
            // Set remote description
            let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
            
            self.peerConnection?.setRemoteDescription(answer) { error in
                if let error = error {
                    DebugLogger.shared.log("❌ Set remote description failed: \(error.localizedDescription)", emoji: "❌", color: .red)
                    DispatchQueue.main.async {
                        self.errorMessage = "Failed to set remote description"
                        self.isLoading = false
                    }
                    return
                }
                
                DebugLogger.shared.log("✅ Remote description set - waiting for stream", emoji: "✅", color: .green)
                DispatchQueue.main.async {
                    self.isLoading = false
                }
            }
            
        }.resume()
    }
    
    // MARK: - Cleanup
    
    private func cleanup() {
        DebugLogger.shared.log("🧹 Cleaning up native WebRTC", emoji: "🧹", color: .gray)
        
        // Remove video track from view
        if let track = videoTrack {
            track.remove(remoteVideoView!)
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
                DebugLogger.shared.log("✅ Connected!", emoji: "✅", color: .green)
                
            case .disconnected:
                self.isConnected = false
                DebugLogger.shared.log("⚠️ Disconnected", emoji: "⚠️", color: .orange)
                
            case .failed:
                self.isConnected = false
                self.errorMessage = "Connection failed"
                DebugLogger.shared.log("❌ Connection failed", emoji: "❌", color: .red)
                
            case .closed:
                self.isConnected = false
                DebugLogger.shared.log("🔒 Connection closed", emoji: "🔒", color: .gray)
                
            default:
                break
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        DebugLogger.shared.log("❄️ ICE gathering state: \(newState.rawValue)", emoji: "❄️", color: .blue)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // We're using Trickle ICE, but server handles this automatically
        // No need to send candidates manually for this simple setup
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        // Ignored for now
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // Not using data channels
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