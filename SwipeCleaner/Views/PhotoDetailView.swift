import Photos
import SwiftUI

struct PhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let asset: PHAsset
    let imageManager: PHImageManager
    let imageCache: PhotoImageCache

    @State private var scale: CGFloat = 1
    @State private var storedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var storedOffset: CGSize = .zero
    @State private var showDetails = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PhotoImageView(
                asset: asset,
                manager: imageManager,
                cache: imageCache,
                targetSize: CGSize(width: 1600, height: 2200)
            )
            .scaleEffect(scale)
            .offset(offset)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3)) {
                    scale = scale > 1 ? 1 : 2.5
                    storedScale = scale
                    if scale == 1 {
                        offset = .zero
                        storedOffset = .zero
                    }
                }
            }
            .onTapGesture {
                withAnimation { showDetails.toggle() }
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        scale = min(
                            max(storedScale * value.magnification, 1),
                            6
                        )
                    }
                    .onEnded { _ in
                        storedScale = scale
                        if scale == 1 {
                            offset = .zero
                            storedOffset = .zero
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(
                            width: storedOffset.width
                                + value.translation.width,
                            height: storedOffset.height
                                + value.translation.height
                        )
                    }
                    .onEnded { _ in storedOffset = offset }
            )

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    Text("\(Int(scale * 100))%")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .opacity(scale > 1 ? 1 : 0)
                }
                .padding()

                Spacer()
                if showDetails {
                    detailsPanel.transition(
                        .move(edge: .bottom).combined(with: .opacity)
                    )
                }
            }
        }
        .statusBarHidden()
    }

    private var detailsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let date = asset.creationDate {
                Label(
                    date.formatted(date: .long, time: .shortened),
                    systemImage: "calendar"
                )
            }
            Label(
                "\(asset.pixelWidth) × \(asset.pixelHeight) pixels",
                systemImage: "aspectratio"
            )
            if let filename =
                PHAssetResource.assetResources(for: asset)
                    .first?.originalFilename {
                Label(filename, systemImage: "doc")
            }
            HStack(spacing: 14) {
                if asset.isFavorite {
                    Label("Favorite", systemImage: "heart.fill")
                        .foregroundStyle(.pink)
                }
                if asset.mediaSubtypes.contains(.photoLive) {
                    Label("Live Photo", systemImage: "livephoto")
                }
                if asset.mediaSubtypes.contains(.photoScreenshot) {
                    Label("Screenshot", systemImage: "iphone")
                }
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial)
    }
}
