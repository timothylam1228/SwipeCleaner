import Photos
import SwiftUI

struct SwipeCardView: View {
    let asset: PHAsset
    let imageManager: PHImageManager
    let imageCache: PhotoImageCache
    let targetSize: CGSize
    let onDecision: (SwipeDecision) -> Void
    let onDetails: () -> Void

    @State private var offset: CGSize = .zero
    @State private var isAnimatingOut = false
    private let threshold: CGFloat = 105

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                PhotoImageView(
                    asset: asset,
                    manager: imageManager,
                    cache: imageCache,
                    targetSize: targetSize
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                HStack {
                    indicator("KEEP", color: .green, opacity: max(0, offset.width / threshold))
                    Spacer()
                    indicator("DELETE", color: .red, opacity: max(0, -offset.width / threshold))
                }
                .padding(28)

                HStack {
                    Spacer()
                    Button(action: onDetails) {
                        Image(systemName: "info.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .accessibilityLabel("Show photo details and zoom")
                }
                .padding(18)

                if let date = asset.creationDate {
                    VStack {
                        Spacer()
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(18)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            .offset(offset)
            .rotationEffect(.degrees(Double(offset.width / 24)))
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { if !isAnimatingOut { offset = $0.translation } }
                    .onEnded { value in
                        if value.translation.width < -threshold {
                            animateOut(.delete, width: proxy.size.width)
                        } else if value.translation.width > threshold {
                            animateOut(.keep, width: proxy.size.width)
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                                offset = .zero
                            }
                        }
                    }
            )
        }
        .accessibilityLabel("Photo from \(asset.creationDate?.formatted() ?? "unknown date")")
        .accessibilityHint("Swipe left to queue for deletion or right to keep")
    }

    private func indicator(_ text: String, color: Color, opacity: CGFloat) -> some View {
        Text(text)
            .font(.title2.bold())
            .foregroundStyle(color)
            .padding(10)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 4))
            .opacity(min(opacity, 1))
    }

    private func animateOut(_ decision: SwipeDecision, width: CGFloat) {
        guard !isAnimatingOut else { return }
        isAnimatingOut = true
        withAnimation(.easeIn(duration: 0.22)) {
            offset.width = decision == .delete ? -(width + 180) : width + 180
            offset.height *= 0.3
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDecision(decision)
        }
    }
}
