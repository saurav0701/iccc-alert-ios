import SwiftUI

struct ImageDetailView: View {
    let event: Event
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()
            
            // Image Content
            if isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    
                    Text("Loading image...")
                        .foregroundColor(.white)
                        .font(.subheadline)
                }
            } else if let image = image {
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
                                    scale = min(max(scale * delta, 1), 5)
                                }
                                .onEnded { _ in
                                    lastScale = 1.0
                                    if scale <= 1 {
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
                                    if scale > 1 {
                                        offset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                    }
                                }
                                .onEnded { _ in
                                    lastOffset = offset
                                }
                        )
                }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50))
                        .foregroundColor(.white)
                    
                    Text("Failed to load image")
                        .foregroundColor(.white)
                        .font(.headline)
                    
                    Button("Try Again") {
                        loadImage()
                    }
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
            }
            
            // Top Bar with Event Info
            VStack {
                HStack {
                    Button(action: { presentationMode.wrappedValue.dismiss() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white)
                                .shadow(radius: 2)
                        }
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(event.typeDisplay ?? event.type ?? "Event")
                            .font(.headline)
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                        
                        Text(event.location)
                            .font(.caption)
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                    }
                    
                    Spacer()
                    
                    // Share button
                    if image != nil {
                        Button(action: shareImage) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .shadow(radius: 2)
                        }
                    }
                }
                .padding()
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.black.opacity(0.6), Color.clear]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                
                Spacer()
            }
        }
        .statusBar(hidden: true)
        .onAppear {
            loadImage()
        }
        .onTapGesture(count: 2) {
            // Double tap to zoom
            withAnimation {
                if scale > 1 {
                    scale = 1
                    offset = .zero
                    lastOffset = .zero
                } else {
                    scale = 2
                }
            }
        }
    }
    
    private func loadImage() {
        isLoading = true
        
        Task {
            do {
                let loadedImage = try await EventImageLoader.shared.loadImage(for: event)
                await MainActor.run {
                    self.image = loadedImage
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.image = nil
                    self.isLoading = false
                }
                print("❌ Error loading full image: \(error.localizedDescription)")
            }
        }
    }
    
    private func shareImage() {
        guard let image = image else { return }
        
        let activityController = UIActivityViewController(
            activityItems: [image, shareText],
            applicationActivities: nil
        )
        
        // Get the top-most view controller
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            
            // Present from the top-most presented view controller
            var topController = rootViewController
            while let presentedViewController = topController.presentedViewController {
                topController = presentedViewController
            }
            
            // For iPad: configure popover
            if let popover = activityController.popoverPresentationController {
                popover.sourceView = window
                popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            
            topController.present(activityController, animated: true)
        }
    }
    
    private var shareText: String {
        """
        Event: \(event.typeDisplay ?? event.type ?? "Unknown")
        Location: \(event.location)
        Time: \(formatDate(event.date))
        """
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Preview

#if DEBUG
struct ImageDetailView_Previews: PreviewProvider {
    static var previews: some View {
        ImageDetailView(event: Event(
            id: "test_123",
            area: "barkasayal",
            type: "cd",
            typeDisplay: "Crowd Detection",
            message: "Test message",
            location: "Test Location",
            timestamp: Int64(Date().timeIntervalSince1970),
            data: [:],
            isRead: false,
            priority: nil
        ))
    }
}
#endif