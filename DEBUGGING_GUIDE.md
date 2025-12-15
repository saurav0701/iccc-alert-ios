# Debugging Guide for Windows Development

Since you're developing on Windows without access to Xcode console, we've added an in-app debug logging system.

## How to View Debug Logs

1. **Run your app on the iOS device/simulator**
2. **Navigate to Settings tab** (gear icon)
3. **Scroll down to "Debug" section**
4. **Tap "View Debug Logs"**
5. **See all the detailed logs from the OTP verification process**

## What Logs to Look For

When you perform OTP verification, you should see logs like:

### Successful Flow:
```
[HH:MM:SS] [INFO] 🔄 Sending OTP verification request: phone=6284267500, otp=123456, deviceId=xxxx
[HH:MM:SS] [INFO] 📥 RAW RESPONSE: {"token":"...", "user": {...}}
[HH:MM:SS] [INFO] 📊 HTTP Status Code: 200
[HH:MM:SS] [INFO] 🔄 Attempting to decode AuthResponse...
[HH:MM:SS] [SUCCESS] Successfully decoded AuthResponse directly
[HH:MM:SS] [SUCCESS] Auth data saved successfully
[HH:MM:SS] [SUCCESS] Showing ContentView (authenticated)
```

### If There's a Problem:
```
[HH:MM:SS] [ERROR] Network Error: [specific error message]
[HH:MM:SS] [ERROR] Key 'token' not found: ...
[HH:MM:SS] [WARNING] Could not decode response, but got 200 status. Attempting fallback...
[HH:MM:SS] [INFO] 📋 Response JSON keys: token, user, expiresAt
```

## Troubleshooting Steps

1. **Check the "RAW RESPONSE" log**
   - This shows exactly what the server is sending
   - Share this with the team if something looks wrong

2. **Look for ERROR or WARNING logs**
   - These indicate what's failing
   - The detailed error message will help identify the issue

3. **Share the Logs**
   - Use the "Copy" button at the bottom to copy all logs
   - Paste them in a message/ticket for the dev team

## Common Issues and Solutions

### Issue: "No token found in response"
- **Cause**: Server response doesn't include a `token` field
- **Solution**: Check if server is sending `access_token` instead of `token`

### Issue: "Type mismatch for type"
- **Cause**: A field has a different data type than expected (e.g., string instead of number)
- **Solution**: Check the actual response format and update the model

### Issue: "Key 'user' not found"
- **Cause**: Server response doesn't include user data
- **Solution**: Server might need to be updated to include user info

### Issue: App still not navigating
- **Cause**: AuthManager's `isAuthenticated` property not being set
- **Solution**: Check if `saveAuthData()` is being called (look for "Auth data saved successfully" log)

## Key Files for This Feature

- `Utils/DebugLogger.swift` - Debug logging system
- `Views/DebugLogsView.swift` - Debug logs display UI
- `Views/SettingsView.swift` - Settings tab with debug section
- `Services/AuthManager.swift` - Updated with comprehensive logging

## Next Steps

1. Build and run the app
2. Try OTP verification
3. Go to Settings → Debug → View Debug Logs
4. Take a screenshot of the logs or copy them
5. Share the logs if there are any issues
