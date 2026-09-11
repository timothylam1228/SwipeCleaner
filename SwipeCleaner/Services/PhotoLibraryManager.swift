import Photos
import SwiftUI

@MainActor
final class PhotoLibraryManager: NSObject, ObservableObject {
    enum LoadState: Equatable {
        case idle, requestingPermission, loading, ready, empty, denied
        case failed(String)
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var assets: [PHAsset] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var deletionQueue: [PHAsset] = []
    @Published private(set) var lastHistoryEntry: SwipeHistoryEntry?
    @Published var deletionErrorMessage: String?
    @Published private(set) var isDeleting = false

    let imageManager = PHCachingImageManager()
    private var cachedAssetIDs = Set<String>()

    var currentAsset: PHAsset? { assets.indices.contains(currentIndex) ? assets[currentIndex] : nil }
    var remainingCount: Int { max(assets.count - currentIndex, 0) }
    var isLimited: Bool { authorizationStatus == .limited }

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func begin() async {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = current
        if current == .notDetermined {
            state = .requestingPermission
            authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        await respondToAuthorization()
    }

    func refreshAuthorizationAndPhotos() async {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        await respondToAuthorization()
    }

    private func respondToAuthorization() async {
        switch authorizationStatus {
        case .authorized, .limited:
            loadPhotos()
        case .denied, .restricted:
            state = .denied
        case .notDetermined:
            state = .idle
        @unknown default:
            state = .failed("Unknown Photos authorization status.")
        }
    }

    private func loadPhotos() {
        state = .loading
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var loaded: [PHAsset] = []
        loaded.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in loaded.append(asset) }

        assets = loaded
        currentIndex = min(currentIndex, loaded.count)
        let validIDs = Set(loaded.map(\.localIdentifier))
        deletionQueue.removeAll { !validIDs.contains($0.localIdentifier) }
        state = loaded.isEmpty ? .empty : .ready
        updatePrefetching()
    }

    func decide(_ decision: SwipeDecision) {
        guard let asset = currentAsset else { return }
        if decision == .delete,
           !deletionQueue.contains(where: { $0.localIdentifier == asset.localIdentifier }) {
            deletionQueue.append(asset)
        }
        lastHistoryEntry = SwipeHistoryEntry(asset: asset, index: currentIndex, decision: decision)
        currentIndex += 1
        updatePrefetching()
    }

    func undoLastDecision() {
        guard let entry = lastHistoryEntry else { return }
        if entry.decision == .delete {
            deletionQueue.removeAll { $0.localIdentifier == entry.asset.localIdentifier }
        }
        currentIndex = min(entry.index, assets.count)
        lastHistoryEntry = nil
        updatePrefetching()
    }

    func removeFromDeletionQueue(_ asset: PHAsset) {
        deletionQueue.removeAll { $0.localIdentifier == asset.localIdentifier }
    }

    func presentLimitedLibraryPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let controller = scene.keyWindow?.rootViewController else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    func deleteQueuedPhotos() async -> Bool {
        let queued = deletionQueue
        guard !queued.isEmpty else { return true }
        isDeleting = true
        deletionErrorMessage = nil
        defer { isDeleting = false }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(queued as NSArray)
            }
            let deletedIDs = Set(queued.map(\.localIdentifier))
            assets.removeAll { deletedIDs.contains($0.localIdentifier) }
            deletionQueue.removeAll()
            currentIndex = min(currentIndex, assets.count)
            lastHistoryEntry = nil
            state = assets.isEmpty ? .empty : .ready
            updatePrefetching()
            return true
        } catch {
            let nsError = error as NSError
            deletionErrorMessage = nsError.domain == PHPhotosError.errorDomain && nsError.code == PHPhotosError.Code.userCancelled.rawValue
                ? "Deletion was cancelled. No photos were deleted."
                : "Could not delete the selected photos: \(error.localizedDescription)"
            return false
        }
    }

    private func updatePrefetching() {
        let range = currentIndex..<min(currentIndex + 6, assets.count)
        let nearby = range.map { assets[$0] }
        let nearbyIDs = Set(nearby.map(\.localIdentifier))
        let requestOptions = PHImageRequestOptions()
        requestOptions.deliveryMode = .opportunistic
        requestOptions.resizeMode = .fast
        requestOptions.isNetworkAccessAllowed = true
        let size = CGSize(width: 900, height: 1200)

        let noLongerNeeded = assets.filter { cachedAssetIDs.contains($0.localIdentifier) && !nearbyIDs.contains($0.localIdentifier) }
        if !noLongerNeeded.isEmpty {
            imageManager.stopCachingImages(for: noLongerNeeded, targetSize: size, contentMode: .aspectFit, options: requestOptions)
        }
        let newlyNeeded = nearby.filter { !cachedAssetIDs.contains($0.localIdentifier) }
        if !newlyNeeded.isEmpty {
            imageManager.startCachingImages(for: newlyNeeded, targetSize: size, contentMode: .aspectFit, options: requestOptions)
        }
        cachedAssetIDs = nearbyIDs
    }
}

extension PhotoLibraryManager: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.loadPhotos()
        }
    }
}
