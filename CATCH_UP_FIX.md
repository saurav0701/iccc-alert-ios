# iOS App Freeze During Catch-up Recovery

## 🔴 Root Cause Analysis

Your app was freezing after receiving the first event because of **improper catch-up synchronization**. Here's what was happening:

### Backend Behavior (from logs):
```
2025-12-16T13:24:17+05:30 INF ws\jetstream.go:414 > 🚀 CATCH-UP MODE: Will fetch ALL pending messages backlog=5
2025-12-16T13:24:17+05:30 ERR ws\jetstream.go:537 > Error fetching messages error="nats: invalid subscription\nnats: subscription closed"
```

The backend enters **CATCH-UP MODE** when `numPending > 0`, sending bulk messages (100-200 events) in parallel streams. These events arrive **out-of-order** due to 4 parallel processing threads.

### iOS Problem 1: Bad Catch-up Detection
```swift
// OLD: Checks if event buffer is empty ❌ WRONG
if isQueueEmpty {
    ChannelSyncState.shared.disableCatchUpMode(channelId: channelId)
}
```

**Why this fails:**
- Event buffer empties quickly after dequeuing for processing
- Doesn't wait for actual catch-up to complete
- Sends live-mode sequence checks while still receiving bulk events
- Causes duplicate detection to fail (live mode rejects seq 200 after seq 156)

### iOS Problem 2: No Connection Error Recovery During Catch-up
```
2025-12-16T13:24:17+05:30 ERR ws\jetstream.go:537 > Error fetching messages 
error="nats: invalid subscription\nnats: subscription closed"
```

When backend hits an error during catch-up (subscription closed), the iOS app:
- ❌ Doesn't detect it's mid-catch-up
- ❌ Continues expecting events in live mode
- ❌ Freezes waiting for events that never come

### Android Handled It Correctly:
Your Android code has:
1. ✅ `enableCatchUpMode()` before subscription
2. ✅ `disableCatchUpMode()` ONLY when backend signals completion
3. ✅ Tracks ALL sequences in a Set during catch-up
4. ✅ Graceful fallback if error occurs

## ✅ Solution Implemented

### 1. **Catch-up Detection by Timeout + Inactivity**
```swift
private let catchUpTimeout: TimeInterval = 60.0  // Max time for catch-up
private let eventProcessingTimeout: TimeInterval = 30.0  // No events for 30s = done
private var lastEventProcessedTime: TimeInterval = 0
private var catchUpStartTime: [String: TimeInterval] = [:]
```

**Logic:**
- If 30 seconds pass with NO events → catch-up complete
- If > 60 seconds pass total → force timeout (assume backend error)
- Checks every 2 seconds instead of 5 seconds for faster recovery

### 2. **Handle Backend Catch-up Signals**
```swift
// Check for server catch-up completion signal
if text.contains("\"type\":\"sync_complete\"") || 
   text.contains("\"catchUpComplete\":true") {
    ChannelSyncState.shared.disableCatchUpMode(channelId: channelId)
    catchUpChannels.remove(channelId)
}
```

Prepare your backend to send this when `numPending=0`.

### 3. **Graceful Error Recovery During Catch-up**
```swift
case .failure(let error):
    let isCatchingUp = !self.catchUpChannels.isEmpty
    if isCatchingUp {
        logger.logError("WS_RECEIVE", "ERROR DURING CATCH-UP - Forcing completion")
        
        // Force disable for all channels
        for channelId in self.catchUpChannels {
            ChannelSyncState.shared.disableCatchUpMode(channelId: channelId)
        }
        self.catchUpChannels.removeAll()
    }
    // Reconnect
    self.scheduleReconnect()
```

If connection fails mid-catch-up:
- Force exit catch-up mode
- Trigger reconnect
- Next subscription will resync from `highestSeq`

### 4. **Updated Monitoring with Logging**
```swift
private func checkCatchUpProgress() {
    for channelId in channelsToCheck {
        // Timeout check
        if elapsed > catchUpTimeout {
            logger.logError("CATCHUP", "TIMEOUT for \(channelId) - Force disabling")
            ChannelSyncState.shared.disableCatchUpMode(channelId: channelId)
        }
        
        // Inactivity check
        let timeSinceLastEvent = now - lastEventProcessedTime
        if progress > 0 && timeSinceLastEvent > eventProcessingTimeout {
            logger.log("CATCHUP", "No new events for \(timeSinceLastEvent)s - Catch-up complete")
            ChannelSyncState.shared.disableCatchUpMode(channelId: channelId)
        }
    }
}
```

## 📊 Timeline of Event Flow (Fixed)

```
1. User subscribes to channels
   ↓
2. iOS: enableCatchUpMode() for all channels
   └─→ recordedSequences = Set() for each channel
   
3. iOS: sendSubscription() with syncState
   └─→ Backend checks: numPending=5 (backlog)
   
4. Backend: CATCH-UP MODE
   └─→ Sends seq [156, 200, 180, 155, 190] in parallel
   
5. iOS: Receives events OUT OF ORDER
   ├─→ seq 200 → Add to Set ✅
   ├─→ seq 155 → Add to Set ✅
   ├─→ seq 156 → Add to Set ✅
   └─→ (Process each event regardless of order)
   
6. iOS: Timer checks every 2s
   └─→ "No events for 30s" → Disable catch-up
   
7. iOS: Live mode
   └─→ seq 201 → ✅ 201 > highestSeq(200)
   └─→ seq 202 → ✅ 202 > 201
```

## 🔧 Required Changes

### Changes Made to iOS:
1. ✅ Added timeout tracking: `catchUpStartTime[channelId]`
2. ✅ Added inactivity detection: `lastEventProcessedTime`
3. ✅ Added error recovery during catch-up
4. ✅ Updated monitoring from 5s to 2s intervals
5. ✅ Added server signal handling for sync_complete

### Changes Needed on Backend (Optional but Recommended):
When `numPending=0` and catch-up complete, send:
```json
{
  "type": "sync_complete",
  "channelId": "giridih_id",
  "catchUpComplete": true,
  "timestamp": 1765869151000
}
```

This signals immediate completion instead of relying on timeouts.

## 🧪 How to Test

1. **Subscribe to channels** → Wait for 1st event
2. **Check logs:** Look for `"🔄 Enabled catch-up mode for [channel]"`
3. **Disconnect app** for 5 minutes
4. **Reconnect** → Bulk events should arrive (100-200)
5. **Verify logs:**
   - `"🚀 CATCH-UP MODE"` messages
   - `"✅ Recorded [channel]: seq=XXX (CATCH-UP)"`
   - After 30s no events: `"No new events for 30s - Catch-up complete"`
   - `"✅ Disabled catch-up mode for [channel]"`
6. **Live events** should continue flowing
7. **App should NOT freeze**

## 📋 Sequence Comparison Logic

### During Catch-up (Set-based):
```
Received: [seq1, seq2, seq3, ... seqN] in ANY order
Check: seqSet.insert(seq).inserted → new or duplicate
Accept: ALL new sequences, ignore duplicates
```

### During Live Mode (Comparison-based):
```
Received: seq1
Check: seq1 > highestSeq
Accept: YES if greater, NO if <= (duplicate)
Result: Very fast O(1) check
```

## 🚨 Failure Modes & Recovery

| Scenario | Old Behavior | New Behavior |
|----------|--|--|
| Backend error mid-catch-up | ❌ Freeze | ✅ Force exit, reconnect |
| Events arrive out-of-order | ❌ Skip duplicates | ✅ Track all in Set |
| No events for 30s | ❌ Wait forever | ✅ Auto-complete catch-up |
| Timeout after 60s | ❌ Hang | ✅ Force-disable catch-up |
| Connection lost | ❌ Freeze | ✅ Graceful reconnect |

## ✨ Key Improvements

1. **Robustness:** No more infinite waits
2. **Speed:** Detects catch-up completion in 30 seconds max
3. **Recovery:** Automatically recovers from backend errors
4. **Visibility:** Detailed logs for debugging
5. **Correctness:** Handles out-of-order parallel delivery

## 📝 Files Modified

- `WebSocketService.swift`: 
  - Added catch-up timeout tracking
  - Enhanced error recovery
  - Improved monitoring logic
  - Added server signal handling

- `ChannelSyncState.swift`: (No changes needed - already correct)
  - Set-based tracking during catch-up ✅
  - Simple comparison in live mode ✅

## 🔗 Related Issue on Backend

The backend errors suggest a potential issue with:
- WebSocket subscription getting closed during catch-up
- NATS consumer not properly handling bulk delivery

Consider:
1. Increasing timeouts on backend
2. Adding retry logic for failed message fetches
3. Sending explicit sync_complete signal

## ✅ Verification Checklist

- [ ] App connects successfully
- [ ] First subscription triggers catch-up mode
- [ ] Events arrive without freezing
- [ ] Catch-up auto-completes after 30s of inactivity
- [ ] Live events continue arriving
- [ ] Connection errors trigger graceful reconnect
- [ ] DebugView shows all stats updating
- [ ] No ANR (Application Not Responding) errors
