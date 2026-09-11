import SwiftUI

struct ReviewView: View {
    @EnvironmentObject private var library: PhotoLibraryManager
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 3)]

    var body: some View {
        NavigationStack {
            Group {
                if library.deletionQueue.isEmpty {
                    ContentUnavailableView("Nothing Queued", systemImage: "checkmark.circle", description: Text("Swipe left on photos to add them here."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(library.deletionQueue, id: \.localIdentifier) { asset in
                                PhotoImageView(asset: asset, manager: library.imageManager, contentMode: .fill)
                                    .aspectRatio(1, contentMode: .fit).clipped()
                                    .overlay(alignment: .topTrailing) {
                                        Button { library.removeFromDeletionQueue(asset) } label: {
                                            Image(systemName: "xmark.circle.fill").font(.title2).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.65))
                                        }
                                        .padding(5).accessibilityLabel("Remove from deletion queue")
                                    }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Review \(library.deletionQueue.count)")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                if !library.deletionQueue.isEmpty {
                    Button(role: .destructive) { showDeleteConfirmation = true } label: {
                        Label("Delete \(library.deletionQueue.count) Photos", systemImage: "trash.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding()
                    }
                    .buttonStyle(.borderedProminent).tint(.red).padding().background(.ultraThinMaterial)
                    .disabled(library.isDeleting)
                }
            }
            .confirmationDialog("Delete \(library.deletionQueue.count) photos?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete \(library.deletionQueue.count) Photos", role: .destructive) {
                    Task { if await library.deleteQueuedPhotos() { dismiss() } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Apple will ask you to confirm. Deleted photos move to Recently Deleted in Photos.") }
            .alert("Deletion Not Completed", isPresented: Binding(get: { library.deletionErrorMessage != nil }, set: { if !$0 { library.deletionErrorMessage = nil } })) {
                Button("OK", role: .cancel) { library.deletionErrorMessage = nil }
            } message: { Text(library.deletionErrorMessage ?? "Unknown error") }
        }
    }
}

