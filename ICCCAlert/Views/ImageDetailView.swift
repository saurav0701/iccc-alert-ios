import SwiftUI

struct ImageDetailView: View {
    let event: Event
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var imageLoader = ImageLoader()
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        ZStack {
            // Background
            Color.black.edgesIgnoringSafeArea(.all)
            
            // Content
            if let image = imageLoader.image {
                GeometryReader { geometry in
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    let delta = value / lastScale
                                    lastScale = value
                                    scale = min(max(scale * delta, 1), 4)
                                }
                                .onEnded { _ in
                                    lastScale = 1.0
                                    if scale < 1 {
                                        withAnimation {
                                            scale = 1
                                            offset = .zero
                                        }
                                    }
                                }
                        )
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    lastOffset = offset
                                }
                        )
                }
                .edgesIgnoringSafeArea(.all)
            } else if imageLoader.isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                    Text("Loading image...")
                        .font(.subheadline)
                        .foregroundColor(.white)
                }
            } else if imageLoader.error != nil {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50))
                        .foregroundColor(.white)
                    Text("Failed to load image")
                        .font(.headline)
                        .foregroundColor(.white)
                    Button("Retry") {
                        imageLoader.loadImage(for: event)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            }
            
            // Top bar with info
            VStack {
                HStack {
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                            .shadow(radius: 3)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(event.title)
                            .font(.headline)
                            .foregroundColor(.white)
                            .shadow(radius: 3)
                        
                        Text(event.location)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.9))
                            .shadow(radius: 3)
                    }
                    
                    Spacer()
                    
                    if imageLoader.image != nil {
                        Menu {
                            Button(action: {
                                shareImage()
                            }) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            
                            Button(action: {
                                saveImage()
                            }) {
                                Label("Save to Photos", systemImage: "square.and.arrow.down")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle.fill")
                                .font(.system(size: 30))
                                .foregroundColor(.white)
                                .shadow(radius: 3)
                        }
                    }
                }
                .padding()
                
                Spacer()
                
                // Bottom info bar
                if imageLoader.image != nil {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(formatDate(event.date))
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.9))
                            
                            if let areaDisplay = event.areaDisplay {
                                Text(areaDisplay)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.9))
                            }
                        }
                        
                        Spacer()
                        
                        if scale > 1 {
                            Text(String(format: "%.1fx", scale))
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.9))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.5))
                                .cornerRadius(20)
                        }
                    }
                    .padding()
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.black.opacity(0.7), Color.clear]),
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                }
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: true)
        .onAppear {
            imageLoader.loadImage(for: event)
        }
        .onDisappear {
            imageLoader.cancel()
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, yyyy 'at' HH:mm"
        return formatter.string(from: date)
    }
    
    private func shareImage() {
        guard let image = imageLoader.image else { return }
        
        let activityVC = UIActivityViewController(
            activityItems: [image, event.title],
            applicationActivities: nil
        )
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootVC = window.rootViewController {
            
            // Find the top-most view controller
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            
            // For iPad
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = window
                popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            
            topVC.present(activityVC, animated: true)
        }
    }
    
    private func saveImage() {
        guard let image = imageLoader.image else { return }
        
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        
        // Show feedback (you might want to add a toast notification here)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }
}

struct ImageDetailView_Previews: PreviewProvider {
    static var previews: some View {
        ImageDetailView(event: Event(
            id: "test",
            timestamp: Int64(Date().timeIntervalSince1970),
            source: "camera1",
            area: "barkasayal",
            areaDisplay: "Barka Sayal",
            type: "cd",
            typeDisplay: "Crowd Detection",
            groupId: nil,
            vehicleNumber: nil,
            vehicleTransporter: nil,
            data: ["location": AnyCodable("Main Gate")],
            isRead: false
        ))
    }
}