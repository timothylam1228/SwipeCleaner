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
    @Published private(set) var reviewSession = PhotoReviewSession()
    @Published var deletionErrorMessage: String?
    @Published private(set) var isDeleting = false

    let imageManager = PHCachingImageManager()
    private var cachedAssetIDs = Set<String>()

    var currentAsset: PHAsset? {
        guard let id = reviewSession.currentAssetID else { return nil }
        return assets.first { $0.localIdentifier == id }
    }
    var remainingCount: Int { reviewSession.remainingCount }
    var deletionQueue: [PHAsset] {
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        return reviewSession.deletionIDs.compactMap { byID[$0] }
    }
    var lastHistoryEntry: SwipeHistoryEntry? { reviewSession.lastHistoryEntry }
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
        reviewSession.updateAssets(loaded.map(\.localIdentifier))
        state = loaded.isEmpty ? .empty : .ready
        updatePrefetching()
    }

    func decide(_ decision: SwipeDecision) {
        guard currentAsset != nil else { return }
        reviewSession.decide(decision)
        updatePrefetching()
    }

    func undoLastDecision() {
        reviewSession.undoLastDecision()
        updatePrefetching()
    }

    func removeFromDeletionQueue(_ asset: PHAsset) {
        reviewSession.removeFromDeletionQueue(assetID: asset.localIdentifier)
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
            reviewSession.removeDeletedAssets(deletedIDs)
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
        let unreviewed = assets.filter { !reviewSession.reviewedIDs.contains($0.localIdentifier) }
        let nearby = Array(unreviewed.prefix(6))
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
