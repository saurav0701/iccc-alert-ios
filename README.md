# ICCC Alert - iOS App

iOS companion app for the ICCC Alert system (Integrated Command & Control Centre).

## 🚀 Features

- Real-time event alerts via WebSocket
- Channel subscription management
- User authentication with OTP
- Event filtering and search
- Push notifications
- Offline support

## 🏗️ Architecture

- **SwiftUI** for UI
- **Combine** for reactive programming
- **URLSession** for networking
- **UserDefaults** for local storage

## 📱 Requirements

- iOS 14.0+
- Xcode 15.0+
- Swift 5.9+

## 🛠️ Setup

1. Clone the repository
2. Run `ruby generate_project.rb`
3. Open `ICCCAlert.xcodeproj`
4. Build and run

## 🌐 Backend

Connects to:
- WebSocket: `ws://192.168.29.69:19999/ws`
- Auth API: `http://192.168.29.69:19998/auth`

## 📦 Project Structure