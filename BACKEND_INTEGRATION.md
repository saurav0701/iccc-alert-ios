# Backend Integration: Catch-up Completion Signals

## 📡 iOS App Expects These Signals

The iOS app now listens for explicit completion signals from the backend. Implement one or both:

### Option 1: Send `sync_complete` Message (Recommended)

When catch-up completes for a channel (when `numPending=0`), send:

```json
{
  "type": "sync_complete",
  "channelId": "giridih_id",
  "catchUpComplete": true,
  "timestamp": 1765869151000
}
```

**Location in backend:** In `ws/jetstream.go` after consumers are ready, when switching from catch-up to live:

```go
// Pseudo-code - adjust to your actual implementation
if initialPending == 0 && wasCatchUp {
    completionMsg := map[string]interface{}{
        "type": "sync_complete",
        "channelId": channelId,
        "catchUpComplete": true,
        "timestamp": time.Now().UnixMilli(),
    }
    client.SendMessage(completionMsg)
    logger.Infof("✅ Sent sync_complete for %s", channelId)
}
```

### Option 2: Include Flag in Event Messages (Fallback)

Add to event data during catch-up transition:

```json
{
  "id": "161225132332_172.24.121.53_ID",
  "area": "giridih",
  "type": "id",
  "data": {
    "_requireAck": true,
    "_seq": 1426,
    "isCatchUpComplete": true
  },
  "timestamp": 1765869151000
}
```

The iOS app checks: `text.contains("\"catchUpComplete\":true")`

## 🔄 Recommended Backend Changes

### 1. **Track Catch-up State Per Client**

```go
type ClientCatchUpState struct {
    channelId string
    startTime time.Time
    pending   int64
    isDone    bool
}
```

### 2. **Send Completion Signal Immediately**

After `numPending=0` is reached:

```go
// In jetstream.go after consumers are ready
if initialPending > 0 && len(msgBatch) > 0 {
    logger.Infof("✅ CAUGHT UP: clientId=%s channel=%s pending=0", 
        clientId, channelId)
    
    // Send explicit completion signal
    client.sendSyncComplete(channelId)
}
```

### 3. **Handle Subscription Errors Gracefully**

When `nats: subscription closed` occurs:

```go
// In aggregator.go error handling
case "subscription closed":
    logger.Warnf("🔴 Subscription closed during catch-up, notifying client")
    client.sendError("subscription_error", "retry_subscription")
    // Don't crash - let client reconnect
    break
```

### 4. **Add Health Check Messages**

If no events for > 30s during catch-up, send keepalive:

```go
ticker := time.NewTicker(10 * time.Second)
defer ticker.Stop()

select {
case msg := <-msgChan:
    // Process message
    
case <-ticker.C:
    if time.Since(lastMsgTime) > 30*time.Second {
        logger.Infof("📍 Keepalive: No events for %s, catch-up progress=%d",
            channelId, pending)
        client.sendKeepAlive(channelId, pending)
    }
}
```

## 📊 Backend Logs Should Show

**Good sequence:**
```
✅ Created new durable pull consumer
🚀 CATCH-UP MODE: Will fetch ALL pending messages backlog=5
✅ CAUGHT UP: Verified no pending messages totalProcessed=5
✅ Sent sync_complete for giridih_id
✅ Pull consumer ready with E2E ACK (live mode)
```

**Problem sequence (current):**
```
🚀 CATCH-UP MODE: Will fetch ALL pending messages backlog=5
ERR Error fetching messages error="nats: invalid subscription\nnats: subscription closed"
🔴 Client disconnected mid-batch, NAKing remaining
```

## 🔧 Implementation Priority

### Critical (Do First):
1. ✅ Send `sync_complete` when `numPending=0`
2. ✅ Handle subscription errors without crashing

### Important (Do Soon):
3. Track catch-up duration per client
4. Add logging for catch-up transitions
5. Monitor error rates during catch-up

### Nice to Have:
6. Add keepalive messages every 10s during catch-up
7. Implement exponential backoff for reconnecting clients
8. Dashboard for catch-up metrics

## 📋 Testing Backend Changes

After implementing completion signals:

1. **Subscribe from iOS app** → Monitor backend logs
2. **Verify:** `"✅ Sent sync_complete for [channel]"` appears
3. **Check iOS logs:** `"🎉 Server signaled catch-up complete for [channel]"`
4. **Verify:** Events continue flowing (should see "LIVE" in logs)

## 🚨 Current Issues from Your Logs

### Issue 1: Subscription Closed Error
```
ERR ws\jetstream.go:537 > Error fetching messages 
error="nats: invalid subscription\nnats: subscription closed"
```

**Cause:** Consumer subscription lost mid-operation
**Fix:** Add retry with exponential backoff before giving up

### Issue 2: NAK Cascade
```
WRN ws\jetstream.go:571 > 🔴 Client disconnected mid-batch, NAKing remaining
```

**Cause:** Client drops connection during high-load catch-up
**Fix:** Send completion signal before high-load catch-up starts to warn client

### Issue 3: Connection Reset
```
ERR dial failed: read tcp ... wsarecv: An existing connection was forcibly closed
```

**Cause:** Network timeouts during bulk transfer
**Fix:** Increase `context.Background()` timeout for bulk operations

## 🎯 Success Criteria

After implementing these changes, you should see:

✅ iOS app doesn't freeze after first event  
✅ Bulk events (100-200) arrive without dropping  
✅ Catch-up completes in < 30 seconds  
✅ Live mode events continue after catch-up  
✅ Connection errors trigger graceful reconnect  
✅ No `"subscription closed"` errors  
✅ Backend shows `"✅ Sent sync_complete"`  

## 📝 Minimal Backend Change Example

Add this to your event publishing logic in `ws/handler.go`:

```go
// When sending catch-up complete signal
const CatchUpCompleteMsg = `{
  "type": "sync_complete",
  "channelId": "%s",
  "catchUpComplete": true,
  "timestamp": %d,
  "pending": 0
}`

func (c *Client) SendCatchUpComplete(channelId string) error {
    msg := fmt.Sprintf(CatchUpCompleteMsg, channelId, time.Now().UnixMilli())
    return c.SendMessage([]byte(msg))
}
```

Then call it:
```go
if initialPending > 0 && numPending == 0 {
    c.SendCatchUpComplete(channelId)
    logger.Infof("✅ Catch-up complete for %s", channelId)
}
```
