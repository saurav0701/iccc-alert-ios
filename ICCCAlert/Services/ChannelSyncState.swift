import Foundation

struct ChannelSyncInfo: Codable {
    let channelId: String
    var lastEventId: String?
    var lastEventTimestamp: Int64
    var lastEventSeq: Int64
    var highestSeq: Int64
    var totalReceived: Int64
    var lastSyncTime: TimeInterval
    
    init(channelId: String) {
        self.channelId = channelId
        self.lastEventId = nil
        self.lastEventTimestamp = 0
        self.lastEventSeq = 0
        self.highestSeq = 0
        self.totalReceived = 0
        self.lastSyncTime = Date().timeIntervalSince1970
    }
}

class ChannelSyncState {
    static let shared = ChannelSyncState()
    
    // MARK: - Properties
    private let defaults = UserDefaults.standard
    private let syncStateKey = "channel_sync_states"
    
    // ✅ FIX: Use serial queue for ALL operations - prevents race conditions
    private let serialQueue = DispatchQueue(label: "com.iccc.channelsync.serial", qos: .userInitiated)
    
    private var syncStates: [String: ChannelSyncInfo] = [:]
    
    // Catch-up mode tracking
    private var catchUpMode: [String: Bool] = [:]
    private var receivedSequences: [String: Set<Int64>] = [:]
    
    private var saveTimer: Timer?
    private let saveDelay: TimeInterval = 0.5
    
    // MARK: - Initialization
    private init() {
        loadStates()
    }
    
    // MARK: - Event Recording
    func recordEventReceived(channelId: String, eventId: String, timestamp: Int64, seq: Int64 = 0) -> Bool {
        var result = false
        
        serialQueue.sync {
            var state = syncStates[channelId] ?? ChannelSyncInfo(channelId: channelId)
            let inCatchUpMode = catchUpMode[channelId] == true
            
            // Sequence-based duplicate detection
            if seq > 0 {
                if inCatchUpMode {
                    // CATCH-UP MODE: Use Set for out-of-order handling
                    var seqSet = receivedSequences[channelId] ?? Set<Int64>()
                    
                    if !seqSet.insert(seq).inserted {
                        print("⏭️ Duplicate seq \(seq) for \(channelId) (catch-up mode)")
                        result = false
                        return
                    }
                    
                    receivedSequences[channelId] = seqSet
                    print("✅ Recorded \(channelId): seq=\(seq) (CATCH-UP, total=\(seqSet.count))")
                    
                } else {
                    // LIVE MODE: Simple comparison
                    if seq <= state.highestSeq {
                        print("⏭️ Duplicate seq \(seq) for \(channelId) (live mode, highest=\(state.highestSeq))")
                        result = false
                        return
                    }
                    
                    print("✅ Recorded \(channelId): seq=\(seq) (LIVE)")
                }
            }
            
            // Update state
            state.totalReceived += 1
            state.lastSyncTime = Date().timeIntervalSince1970
            
            if seq > 0 && seq > state.highestSeq {
                state.highestSeq = seq
                state.lastEventId = eventId
                state.lastEventTimestamp = timestamp
                state.lastEventSeq = seq
            } else if seq == 0 && timestamp > state.lastEventTimestamp {
                state.lastEventTimestamp = timestamp
                state.lastEventId = eventId
            }
            
            syncStates[channelId] = state
            scheduleSave()
            
            result = true
        }
        
        return result
    }
    
    // MARK: - Catch-up Mode Management
    func enableCatchUpMode(channelId: String) {
        serialQueue.sync {
            catchUpMode[channelId] = true
            receivedSequences[channelId] = Set<Int64>()
            print("🔄 Enabled catch-up mode for \(channelId)")
        }
    }
    
    func disableCatchUpMode(channelId: String) {
        serialQueue.sync {
            catchUpMode[channelId] = false
            receivedSequences[channelId]?.removeAll()
            print("✅ Disabled catch-up mode for \(channelId) (switched to live mode)")
        }
    }
    
    func isInCatchUpMode(channelId: String) -> Bool {
        var result = false
        serialQueue.sync {
            result = catchUpMode[channelId] == true
        }
        return result
    }
    
    func getCatchUpProgress(channelId: String) -> Int {
        var result = 0
        serialQueue.sync {
            result = receivedSequences[channelId]?.count ?? 0
        }
        return result
    }
    
    // MARK: - State Access
    func getSyncInfo(channelId: String) -> ChannelSyncInfo? {
        var result: ChannelSyncInfo?
        serialQueue.sync {
            result = syncStates[channelId]
        }
        return result
    }
    
    func getAllSyncStates() -> [String: ChannelSyncInfo] {
        var result: [String: ChannelSyncInfo] = [:]
        serialQueue.sync {
            result = syncStates
        }
        return result
    }
    
    func getLastEventId(channelId: String) -> String? {
        var result: String?
        serialQueue.sync {
            result = syncStates[channelId]?.lastEventId
        }
        return result
    }
    
    func getLastSequence(channelId: String) -> Int64 {
        var result: Int64 = 0
        serialQueue.sync {
            result = syncStates[channelId]?.lastEventSeq ?? 0
        }
        return result
    }
    
    func getHighestSequence(channelId: String) -> Int64 {
        var result: Int64 = 0
        serialQueue.sync {
            result = syncStates[channelId]?.highestSeq ?? 0
        }
        return result
    }
    
    func getTotalEventsReceived() -> Int64 {
        var result: Int64 = 0
        serialQueue.sync {
            result = syncStates.values.reduce(0) { $0 + $1.totalReceived }
        }
        return result
    }
    
    // MARK: - Channel Management
    func clearChannel(channelId: String) {
        serialQueue.sync {
            syncStates.removeValue(forKey: channelId)
            receivedSequences.removeValue(forKey: channelId)
            catchUpMode.removeValue(forKey: channelId)
        }
        
        scheduleSave()
        print("🗑️ Cleared sync state for \(channelId)")
    }
    
    func clearAll() {
        serialQueue.sync {
            syncStates.removeAll()
            receivedSequences.removeAll()
            catchUpMode.removeAll()
        }
        
        defaults.removeObject(forKey: syncStateKey)
        print("🗑️ Cleared all sync state")
    }
    
    // MARK: - Statistics
    func getStats() -> [String: Any] {
        var result: [String: Any] = [:]
        
        serialQueue.sync {
            let channelStats = syncStates.map { (channelId, state) in
                return [
                    "channel": channelId,
                    "lastEventId": state.lastEventId as Any,
                    "lastSeq": state.lastEventSeq,
                    "highestSeq": state.highestSeq,
                    "totalReceived": state.totalReceived,
                    "catchUpMode": catchUpMode[channelId] == true,
                    "trackedSequences": receivedSequences[channelId]?.count ?? 0
                ] as [String: Any]
            }
            
            result = [
                "channelCount": syncStates.count,
                "totalEvents": getTotalEventsReceived(),
                "channels": channelStats
            ]
        }
        
        return result
    }
    
    // MARK: - Persistence
    private func scheduleSave() {
        // Must be called from serialQueue
        saveTimer?.invalidate()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.saveTimer = Timer.scheduledTimer(withTimeInterval: self.saveDelay, repeats: false) { [weak self] _ in
                self?.saveNow()
            }
        }
    }
    
    private func saveNow() {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            
            let snapshot = self.syncStates
            
            if let data = try? JSONEncoder().encode(snapshot) {
                self.defaults.set(data, forKey: self.syncStateKey)
                print("💾 Saved \(snapshot.count) channel states")
            }
        }
    }
    
    private func loadStates() {
        if let data = defaults.data(forKey: syncStateKey),
           let states = try? JSONDecoder().decode([String: ChannelSyncInfo].self, from: data) {
            serialQueue.sync {
                syncStates = states
            }
            
            print("📊 Loaded \(states.count) channel sync states")
            for (channelId, state) in states {
                print("  - \(channelId): lastSeq=\(state.lastEventSeq), highestSeq=\(state.highestSeq)")
            }
        }
    }
    
    func forceSave() {
        saveTimer?.invalidate()
        saveNow()
        print("💾 Force saved all channel states")
    }
}