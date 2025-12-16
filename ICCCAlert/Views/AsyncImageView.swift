import SwiftUI

struct AsyncImageView: View {
    let event: Event
    @StateObject private var imageLoader = ImageLoader()
    
    var body: some View {
        ZStack {
            if let image = imageLoader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 200)
                    .clipped()
                    .cornerRadius(8)
            } else if imageLoader.isLoading {
                // Loading state
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 200)
                    .cornerRadius(8)
                    .overlay(
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    )
            } else if imageLoader.error != nil {
                // Error state
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 200)
                    .cornerRadius(8)
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 30))
                                .foregroundColor(.gray)
                            Text("Failed to load image")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("Retry") {
                                imageLoader.loadImage(for: event)
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                        }
                    )
            } else {
                // Initial state
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 200)
                    .cornerRadius(8)
            }
        }
        .onAppear {
            imageLoader.loadImage(for: event)
        }
        .onDisappear {
            imageLoader.cancel()
        }
    }
}