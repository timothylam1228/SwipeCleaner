import Photos
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: PhotoLibraryManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var showReview = false
    @State private var showDateRange = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                content
            }
            .navigationTitle("SwipeCleaner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Undo", systemImage: "arrow.uturn.backward") { library.undoLastDecision() }
                        .disabled(library.lastHistoryEntry == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showReview = true } label: { Label("Review \(library.deletionQueue.count)", systemImage: "trash") }
                }
            }
        }
        .tint(.white)
        .task { await library.begin() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await library.refreshAuthorizationAndPhotos() } } }
        .sheet(isPresented: $showReview) { ReviewView().environmentObject(library) }
        .sheet(isPresented: $showDateRange) {
            DateRangePickerView(filter: library.dateFilter) { library.setDateFilter($0) }
        }
    }

    @ViewBuilder private var content: some View {
        switch library.state {
        case .idle, .requestingPermission:
            permissionIntro
        case .loading:
            ProgressView("Loading your photos…").controlSize(.large)
        case .denied:
            deniedView
        case .empty:
            ContentUnavailableView {
                Label(library.hasPhotosOutsideFilter ? "No Photos in This Range" : "No Photos", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text(library.hasPhotosOutsideFilter ? "Choose another time range to continue reviewing." : "There are no accessible photos in your library.")
            } actions: {
                if library.hasPhotosOutsideFilter { Button("Choose Time Range") { showDateRange = true }.buttonStyle(.borderedProminent) }
            }
        case .failed(let message):
            ContentUnavailableView("Couldn’t Load Photos", systemImage: "exclamationmark.triangle", description: Text(message))
        case .ready:
            if let asset = library.currentAsset { review(asset) } else { finishedView }
        }
    }

    private var permissionIntro: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.stack").font(.system(size: 58)).foregroundStyle(.blue)
            Text("Tidy Your Photo Library").font(.title2.bold())
            Text("SwipeCleaner needs photo access so you can review and safely queue unwanted photos. Nothing is deleted without final confirmation.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            if library.state == .idle { Button("Continue") { Task { await library.begin() } }.buttonStyle(.borderedProminent) }
            else { ProgressView() }
        }.padding(32)
    }

    private var deniedView: some View {
        ContentUnavailableView {
            Label("Photo Access Required", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text("Allow read and write access in Settings to review and delete photos.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }.buttonStyle(.borderedProminent)
        }
    }

    private func review(_ asset: PHAsset) -> some View {
        VStack(spacing: 12) {
            if library.isLimited {
                HStack {
                    Image(systemName: "info.circle")
                    Text("Limited Photos Access").font(.caption)
                    Spacer()
                    Button("Manage Access") { library.presentLimitedLibraryPicker() }.font(.caption.bold())
                }.padding(10).background(.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Label("\(library.remainingCount) remaining", systemImage: "photo")
                Spacer()
                Label("\(library.deletionQueue.count) queued", systemImage: "trash")
            }.font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)

            Button { showDateRange = true } label: {
                HStack {
                    Label(library.dateFilter.title, systemImage: "calendar")
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            }

            ZStack {
                if let nextAsset = library.nextAsset {
                    PhotoImageView(asset: nextAsset, manager: library.imageManager, targetSize: library.cardTargetSize)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .scaleEffect(0.97)
                        .opacity(0.82)
                        .allowsHitTesting(false)
                }
                SwipeCardView(asset: asset, imageManager: library.imageManager, targetSize: library.cardTargetSize) { library.decide($0) }
                    .id(asset.localIdentifier)
            }

            HStack(spacing: 52) {
                actionButton(title: "Delete", icon: "trash.fill", color: .red) { library.decide(.delete) }
                actionButton(title: "Keep", icon: "heart.fill", color: .green) { library.decide(.keep) }
            }.padding(.vertical, 4)
        }.padding(.horizontal).padding(.bottom, 4)
    }

    private func actionButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) { Image(systemName: icon).font(.title2); Text(title).font(.caption.bold()) }
                .frame(width: 68, height: 58).foregroundStyle(color).background(color.opacity(0.14), in: Circle())
        }.accessibilityLabel(title)
    }

    private var finishedView: some View {
        ContentUnavailableView {
            Label("All Reviewed", systemImage: "checkmark.circle")
        } description: {
            Text(library.deletionQueue.isEmpty ? "You kept every photo." : "Review the queued photos before deleting anything.")
        } actions: {
            if !library.deletionQueue.isEmpty { Button("Review \(library.deletionQueue.count) Photos") { showReview = true }.buttonStyle(.borderedProminent).tint(.red) }
            Button("Undo Last Swipe") { library.undoLastDecision() }.disabled(library.lastHistoryEntry == nil)
        }
    }
}
