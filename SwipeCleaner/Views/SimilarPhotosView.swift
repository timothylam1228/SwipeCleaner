import Photos
import SwiftUI

struct SimilarPhotosView: View {
    @EnvironmentObject private var library: PhotoLibraryManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var finder = SimilarPhotoFinder()

    var body: some View {
        NavigationStack {
            Group {
                switch finder.state {
                case .idle:
                    introduction
                case .scanning(let completed, let total):
                    scanning(completed: completed, total: total)
                case .finished:
                    results
                case .cancelled:
                    ContentUnavailableView(
                        "Scan Cancelled",
                        systemImage: "xmark.circle",
                        description: Text("No photos were changed.")
                    )
                case .failed(let message):
                    ContentUnavailableView(
                        "Scan Failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            }
            .navigationTitle("Similar Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        finder.cancel()
                        dismiss()
                    }
                }
            }
        }
        .alert(
            "Photo Protected",
            isPresented: Binding(
                get: { library.safetyMessage != nil },
                set: { if !$0 { library.safetyMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                library.safetyMessage = nil
            }
        } message: {
            Text(library.safetyMessage ?? "")
        }
    }

    private var introduction: some View {
        ContentUnavailableView {
            Label(
                "Find Similar Photos",
                systemImage: "square.stack.3d.up"
            )
        } description: {
            Text(
                "Vision compares up to \(finder.scanLimit) photos from the selected time range on this device. Results are suggestions only."
            )
        } actions: {
            Button("Start Scan") {
                finder.scan(
                    assets: library.assets,
                    imageManager: library.imageManager
                )
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func scanning(completed: Int, total: Int) -> some View {
        VStack(spacing: 18) {
            ProgressView(
                value: Double(completed),
                total: Double(total)
            )
            .padding(.horizontal, 40)
            Text("Analyzing \(completed) of \(total)")
                .font(.headline)
                .monospacedDigit()
            Text("iCloud-only photos may take longer to download.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Cancel", role: .cancel) {
                finder.cancel()
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if finder.groups.isEmpty {
            ContentUnavailableView(
                "No Similar Groups",
                systemImage: "checkmark.circle",
                description: Text(
                    "No likely matches were found in this range."
                )
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(
                        Array(finder.groups.enumerated()),
                        id: \.element.id
                    ) { index, group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(
                                "Group \(index + 1) · \(group.assetIDs.count) photos"
                            )
                            .font(.headline)
                            .padding(.horizontal)

                            ScrollView(
                                .horizontal,
                                showsIndicators: false
                            ) {
                                LazyHStack(spacing: 8) {
                                    ForEach(group.assetIDs, id: \.self) { id in
                                        if let asset = library.asset(withID: id) {
                                            candidate(asset)
                                        }
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
        }
    }

    private func candidate(_ asset: PHAsset) -> some View {
        VStack(spacing: 6) {
            PhotoImageView(
                asset: asset,
                manager: library.imageManager,
                cache: library.imageCache,
                contentMode: .fill,
                targetSize: CGSize(width: 360, height: 360)
            )
            .frame(width: 150, height: 150)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                        .padding(8)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(5)
                }
            }

            Button {
                if library.isQueuedForDeletion(asset) {
                    library.removeFromDeletionQueue(asset)
                } else {
                    library.queueForDeletion(asset)
                }
            } label: {
                let queued = library.isQueuedForDeletion(asset)
                Label(
                    queued
                        ? "Queued"
                        : (asset.isFavorite ? "Protected" : "Queue"),
                    systemImage: queued
                        ? "checkmark.circle.fill"
                        : (asset.isFavorite ? "lock.fill" : "trash")
                )
            }
            .buttonStyle(.bordered)
            .tint(
                library.isQueuedForDeletion(asset) ? .red : .primary
            )
        }
    }
}
