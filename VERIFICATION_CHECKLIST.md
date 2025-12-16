# Verification Checklist

## ✅ Pre-Deployment Verification

### Code Changes Verification
- [ ] All changes are in `WebSocketService.swift` only
- [ ] No changes to `ChannelSyncState.swift` (already correct)
- [ ] New properties added (catchUpStartTime, eventProcessingTimeout, etc.)
- [ ] processEvent() updated with sync_complete signal handling
- [ ] receiveMessage() updated with error recovery
- [ ] checkCatchUpProgress() completely rewritten
- [ ] sendSubscriptionV2() tracks timestamps
- [ ] Monitoring interval reduced from 5s to 2s

### Compilation Check
```bash
# Should compile without errors
xcodebuild -scheme ICCCAlert -configuration Debug 2>&1 | grep error
```
- [ ] No compilation errors
- [ ] No Swift warnings (in changed code)

### Import/Dependency Check
- [ ] No new imports added
- [ ] All existing imports still valid
- [ ] No third-party dependencies added

---

## 🧪 Unit Testing Scenarios

### Scenario 1: Normal Subscription (No Backlog)
**Steps:**
1. Launch app fresh
2. Subscribe to channels
3. New events arrive

**Expected:**
- [ ] `🔄 Enabled catch-up mode for [channel]` logged
- [ ] `✅ Recorded [channel]: seq=XXX (LIVE)` (not CATCH-UP)
- [ ] Events processed normally
- [ ] Catch-up auto-completes immediately

**Result:** ✅ PASS / ❌ FAIL

---

### Scenario 2: Offline Backlog (5+ minutes)
**Steps:**
1. Open app, subscribe
2. Force quit app
3. Wait 5+ minutes (events accumulate on backend)
4. Reopen app
5. Observe event flow

**Expected:**
- [ ] `🔄 Enabled catch-up mode for [channel]` logged
- [ ] `✅ Recorded [channel]: seq=XXX (CATCH-UP)` logged (multiple events)
- [ ] Events arrive without freezing
- [ ] After 30s inactivity: `No new events for 30s - Catch-up complete`
- [ ] Transitions to `LIVE` mode
- [ ] DebugView shows all events received

**Result:** ✅ PASS / ❌ FAIL

---

### Scenario 3: Network Interruption During Catch-up
**Steps:**
1. Open app, subscribe to channels
2. Simulate offline (Airplane Mode or proxy)
3. Wait 15 seconds
4. Restore network
5. Observe recovery

**Expected:**
- [ ] `WebSocket error` logged
- [ ] `ERROR DURING CATCH-UP - Forcing completion` logged
- [ ] `Force-disabling catch-up for [channel]` logged
- [ ] Automatic reconnect triggered
- [ ] No freeze during interruption

**Result:** ✅ PASS / ❌ FAIL

---

### Scenario 4: Very Slow Event Processing
**Steps:**
1. Subscribe to channels
2. Observe event timing
3. Wait until first event arrives
4. Check if app freezes for long periods

**Expected:**
- [ ] No freeze > 2 seconds
- [ ] Events continue flowing
- [ ] DebugView updates regularly
- [ ] UI remains responsive

**Result:** ✅ PASS / ❌ FAIL

---

### Scenario 5: Timeout Edge Case (60+ seconds)
**Steps:**
1. Subscribe to channels
2. Create scenario where catch-up is stuck
3. Monitor for > 60 seconds

**Expected:**
- [ ] `TIMEOUT for [channel] after XXXs - Force disabling` logged
- [ ] Catch-up auto-exits after 60s max
- [ ] App remains responsive
- [ ] Next subscription works normally

**Result:** ✅ PASS / ❌ FAIL

---

## 📊 DebugView Verification

### Log Format Check
```
✅ Expected log entries should contain:
- "🔄 Enabled catch-up mode for"
- "✅ Recorded [channel]: seq=XXX (CATCH-UP)"
- "No new events for XXs - Catch-up complete"
- "✅ Disabled catch-up mode for [channel]"
- "Event processed successfully"
```

**Check:**
- [ ] Logs appear in this order
- [ ] Timestamps are reasonable
- [ ] No error logs during normal operation
- [ ] Connection status updates correctly

---

## 🔍 Backend Integration Check

### Backend Sends Completion Signal (Optional)
If backend implemented, check for:
- [ ] `{"type":"sync_complete","channelId":"..."}` received
- [ ] Logged as `"🎉 Server signaled catch-up complete"`
- [ ] Catch-up completes immediately (not 30s timeout)

**Result:** ✅ Signal received / ⚠️ Not sent (OK - uses timeout)

---

## 📱 Device Testing

### iOS Device/Simulator
```
Device Info:
- Device: [iPhone Model or Simulator]
- iOS Version: [iOS Version]
- App Version: [Version Number]
- Build: [Build Number]
```

### Functional Tests

#### Test 1: Cold Start
- [ ] App launches normally
- [ ] Subscription succeeds
- [ ] First event arrives
- [ ] UI updates

#### Test 2: Hot Start (Resume)
- [ ] App resumes from background
- [ ] Reconnection occurs
- [ ] Events flow normally
- [ ] No freeze

#### Test 3: Bulk Events
- [ ] Reconnect after offline
- [ ] 100+ events arrive
- [ ] All events processed
- [ ] No dropped events
- [ ] No UI freeze

#### Test 4: Long Soak (1 hour)
- [ ] App running for 1+ hour
- [ ] Events continuously arrive
- [ ] DebugView stats update
- [ ] No memory leaks
- [ ] No crashes

---

## 🎯 Success Criteria

### Must Pass All:
- [ ] No app freeze during bulk event delivery
- [ ] Catch-up completes within 30 seconds
- [ ] Connection errors trigger graceful recovery
- [ ] Out-of-order events handled correctly
- [ ] DebugView shows expected log messages

### Should Pass:
- [ ] Catch-up completes faster than 30s (< 10s typical)
- [ ] No unnecessary reconnects
- [ ] Memory usage stable
- [ ] Battery drain minimal

### Nice to Have:
- [ ] Explicit backend sync_complete signals received
- [ ] Timeout not triggered (catches up normally)
- [ ] Error recovery not needed (connections stable)

---

## 🐛 Known Issues to Watch For

### Issue: Catch-up never completes
- **Check:** Any logs with `"Error fetching messages"`?
- **Solution:** Check backend catch-up implementation
- **Fallback:** 30s timeout will eventually complete

### Issue: Events still being dropped
- **Check:** Are you seeing `"⏭️ Duplicate seq"` logs?
- **Solution:** Confirm `ChannelSyncState` is being initialized
- **Fallback:** Clear app data and resubscribe

### Issue: High memory usage
- **Check:** Are catch-up state trackers being cleaned up?
- **Solution:** Call `stopCatchUpMonitoring()` when done
- **Fallback:** App should auto-cleanup on connection error

### Issue: Catch-up timing out (60s)
- **Check:** Backend sending events for 60+ seconds?
- **Solution:** Reduce `catchUpTimeout` value if needed
- **Expected:** Backend should complete catch-up in < 30s

---

## 📋 Sign-Off Checklist

### Developer Verification
- [ ] Code changes reviewed
- [ ] All files compile without errors
- [ ] No new warnings introduced
- [ ] Tested on simulator
- [ ] Tested on at least 1 real device

### QA Verification (If applicable)
- [ ] All test scenarios pass
- [ ] No regression in existing features
- [ ] DebugView shows expected logs
- [ ] Network stress testing done
- [ ] Battery/Memory testing done

### Deployment Ready
- [ ] Code review completed
- [ ] All tests passed
- [ ] Documentation updated
- [ ] Release notes prepared
- [ ] Rollback plan ready

---

## 📞 Support & Troubleshooting

### If Still Seeing Freezes

1. **Check DebugView logs** for:
   - Connection errors?
   - Catch-up mode not enabled?
   - Events not being processed?

2. **Verify backend:**
   - Is catch-up actually completing?
   - Are there subscription errors?
   - Check backend logs for `sync_complete` signal

3. **Try manual fix:**
   ```swift
   // Force clear and retry
   ChannelSyncState.shared.clearAll()
   WebSocketService.shared.disconnect()
   WebSocketService.shared.connect()
   ```

### If Catch-up is Too Slow

1. **Reduce timeout:**
   ```swift
   private let eventProcessingTimeout: TimeInterval = 15.0  // Was 30
   ```

2. **Check network:**
   - WiFi vs Cellular speed difference?
   - Backend load during catch-up?

3. **Monitor backend:**
   - How long is catch-up taking?
   - Are events arriving in order?

### If Connection Keeps Dropping

1. **Check backend:**
   - `"subscription closed"` errors?
   - Consumer cleanup issues?

2. **Increase timeouts:**
   ```swift
   private let catchUpTimeout: TimeInterval = 120.0  // Was 60
   ```

3. **Monitor network stability:**
   - Test with WiFi only
   - Check signal strength

---

## ✅ Final Checklist

- [ ] Code changes applied
- [ ] Compilation successful
- [ ] Scenario tests passed
- [ ] DebugView logs verified
- [ ] Device testing complete
- [ ] No regressions found
- [ ] Documentation reviewed
- [ ] Ready for deployment

**Status:** 🟢 READY / 🟡 READY WITH NOTES / 🔴 NOT READY

**Sign-off Date:** _______________
**Sign-off By:** _______________
**Notes:** _______________
