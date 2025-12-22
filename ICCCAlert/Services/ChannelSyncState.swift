import Foundation

class ChannelSyncState {
    static let shared = ChannelSyncState()
    
    private let userDefaults = UserDefaults.standard
    private let syncStateKey = "channel_sync_states"
    
    private var syncStates: [String: ChannelSyncInfo] = [:]

    private var catchUpMode: [String: Bool] = [:]
    private var receivedSequences: [String: Set<Int64>] = [:]
    
    struct ChannelSyncInfo: Codable {
        let channelId: String
        var lastEventId: String?
        var lastEventTimestamp: Int64
        var lastEventSeq: Int64
        var highestSeq: Int64
        var totalReceived: Int64
        var lastSyncTime: Int64
        
        init(channelId: String) {
            self.channelId = channelId
            self.lastEventId = nil
            self.lastEventTimestamp = 0
            self.lastEventSeq = 0
            self.highestSeq = 0
            self.totalReceived = 0
            self.lastSyncTime = Int64(Date().timeIntervalSince1970)
        }
    }
    
    private init() {
        loadStates()
    }

    private func loadStates() {
        if let data = userDefaults.data(forKey: syncStateKey),
           let states = try? JSONDecoder().decode([String: ChannelSyncInfo].self, from: data) {
            syncStates = states
            print("📊 Loaded sync states for \(states.count) channels")
            
            for (channelId, state) in states {
                print("   \(channelId): lastSeq=\(state.lastEventSeq), highestSeq=\(state.highestSeq)")
            }
        }
    }
    
    func forceSave() {
        if let data = try? JSONEncoder().encode(syncStates) {
            userDefaults.set(data, forKey: syncStateKey)
            print("✅ Force saved sync states for \(syncStates.count) channels")
        }
    }
    
    private func saveStates() {
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.5) {
            if let data = try? JSONEncoder().encode(self.syncStates) {
                self.userDefaults.set(data, forKey: self.syncStateKey)
            }
        }
    }

    func enableCatchUpMode(channelId: String) {
        catchUpMode[channelId] = true
        receivedSequences[channelId] = Set<Int64>()
        print("🔄 Enabled catch-up mode for \(channelId)")
    }
    
    func disableCatchUpMode(channelId: String) {
        catchUpMode[channelId] = false
        receivedSequences[channelId] = nil
        print("✅ Disabled catch-up mode for \(channelId) (switched to live mode)")
    }
    
    func isInCatchUpMode(channelId: String) -> Bool {
        return catchUpMode[channelId] ?? false
    }
    
    func getCatchUpProgress(channelId: String) -> Int {
        return receivedSequences[channelId]?.count ?? 0
    }

    func recordEventReceived(channelId: String, eventId: String, timestamp: Int64, seq: Int64 = 0) -> Bool {
        if syncStates[channelId] == nil {
            syncStates[channelId] = ChannelSyncInfo(channelId: channelId)
        }
        
        guard var state = syncStates[channelId] else { return false }
        
        let inCatchUpMode = isInCatchUpMode(channelId: channelId)
        
        if seq > 0 {
            if inCatchUpMode {
                if receivedSequences[channelId]?.contains(seq) == true {
                    print("⏭️ Duplicate seq \(seq) for \(channelId) (catch-up mode)")
                    return false
                }
                
                receivedSequences[channelId]?.insert(seq)
                let setSize = receivedSequences[channelId]?.count ?? 0
                print("✅ Recorded \(channelId): seq=\(seq) (CATCH-UP, total=\(setSize))")
                
            } else {
                if seq <= state.highestSeq {
                    print("⏭️ Duplicate seq \(seq) for \(channelId) (live mode, highest=\(state.highestSeq))")
                    return false
                }
                
                print("✅ Recorded \(channelId): seq=\(seq) (LIVE)")
            }
        }

        state.totalReceived += 1
        state.lastSyncTime = Int64(Date().timeIntervalSince1970)
        
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
        saveStates()
        
        return true
    }

    func getSyncInfo(channelId: String) -> ChannelSyncInfo? {
        return syncStates[channelId]
    }
    
    func getLastEventId(channelId: String) -> String? {
        return syncStates[channelId]?.lastEventId
    }
    
    func getLastSequence(channelId: String) -> Int64 {
        return syncStates[channelId]?.lastEventSeq ?? 0
    }
    
    func getHighestSequence(channelId: String) -> Int64 {
        return syncStates[channelId]?.highestSeq ?? 0
    }
    
    func getTotalEventsReceived() -> Int64 {
        return syncStates.values.reduce(0) { $0 + $1.totalReceived }
    }

    func clearChannel(channelId: String) {
        syncStates.removeValue(forKey: channelId)
        receivedSequences.removeValue(forKey: channelId)
        catchUpMode.removeValue(forKey: channelId)
        saveStates()
        print("🗑️ Cleared sync state for \(channelId)")
    }
    
    func clearAll() {
        syncStates.removeAll()
        receivedSequences.removeAll()
        catchUpMode.removeAll()
        userDefaults.removeObject(forKey: syncStateKey)
        print("✅ Cleared all sync state")
    }
 
    func getStats() -> [String: Any] {
        let channelStats = syncStates.map { (channelId, state) -> [String: Any] in
            return [
                "channel": channelId,
                "lastEventId": state.lastEventId ?? "",
                "lastSeq": state.lastEventSeq,
                "highestSeq": state.highestSeq,
                "totalReceived": state.totalReceived,
                "catchUpMode": catchUpMode[channelId] ?? false,
                "trackedSequences": receivedSequences[channelId]?.count ?? 0
            ]
        }
        
        return [
            "channelCount": syncStates.count,
            "totalEvents": getTotalEventsReceived(),
            "channels": channelStats
        ]
    }
}