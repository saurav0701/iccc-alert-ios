import SwiftUI

struct ImageDetailView: View {
    let event: Event
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var imageLoader = ImageLoader()
    
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, yyyy HH:mm:ss"
        return formatter
    }()
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding()
                    }
                    
                    Spacer()
                    
                    Menu {
                        Button(action: saveImage) {
                            Label("Save to Photos", systemImage: "square.and.arrow.down")
                        }
                        
                        Button(action: shareImage) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding()
                    }
                }
                .background(Color.black.opacity(0.7))
                
                // Image
                ZStack {
                    if let image = imageLoader.image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(scale)
                            .offset(offset)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        scale = lastScale * value
                                    }
                                    .onEnded { _ in
                                        lastScale = scale
                                        
                                        // Limit scale
                                        if scale < 1.0 {
                                            withAnimation {
                                                scale = 1.0
                                                lastScale = 1.0
                                            }
                                        } else if scale > 5.0 {
                                            withAnimation {
                                                scale = 5.0
                                                lastScale = 5.0
                                            }
                                        }
                                    }
                            )
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        if scale > 1.0 {
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
                            .onTapGesture(count: 2) {
                                withAnimation {
                                    if scale > 1.0 {
                                        scale = 1.0
                                        lastScale = 1.0
                                        offset = .zero
                                        lastOffset = .zero
                                    } else {
                                        scale = 2.0
                                        lastScale = 2.0
                                    }
                                }
                            }
                    } else if imageLoader.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                    } else if imageLoader.error != nil {
                        VStack(spacing: 16) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 50))
                                .foregroundColor(.white)
                            Text("Failed to load image")
                                .foregroundColor(.white)
                            Button("Retry") {
                                imageLoader.loadImage(for: event)
                            }
                            .padding()
                            .background(Color.white.opacity(0.2))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Footer
                VStack(alignment: .leading, spacing: 8) {
                    Text(event.typeDisplay ?? event.type ?? "Event")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text(event.location)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                    
                    Text(dateFormatter.string(from: event.date))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.black.opacity(0.7))
            }
        }
        .onAppear {
            imageLoader.loadImage(for: event)
        }
        .statusBar(hidden: true)
    }
    
    private func saveImage() {
        guard let image = imageLoader.image else { return }
        
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        
        // Show success feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }
    
    private func shareImage() {
        guard let image = imageLoader.image else { return }
        
        let activityVC = UIActivityViewController(
            activityItems: [image],
            applicationActivities: nil
        )
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }
}