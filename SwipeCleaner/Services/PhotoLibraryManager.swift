import Photos
import PhotosUI
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
    @Published private(set) var dateFilter = PhotoDateFilter()
    @Published var deletionErrorMessage: String?
    @Published var safetyMessage: String?
    @Published private(set) var isDeleting = false

    let imageManager = PHCachingImageManager()
    private var cachedAssetIDs = Set<String>()
    private var allAssets: [PHAsset] = []
    private let progressKey = "SwipeCleaner.reviewProgress.v1"

    let cardTargetSize = CGSize(
        width: UIScreen.main.bounds.width * UIScreen.main.scale,
        height: UIScreen.main.bounds.height * UIScreen.main.scale
    )

    var currentAsset: PHAsset? {
        guard let id = reviewSession.currentAssetID else { return nil }
        return assets.first { $0.localIdentifier == id }
    }
    var nextAsset: PHAsset? {
        guard reviewSession.unreviewedAssetIDs.count > 1 else { return nil }
        let id = reviewSession.unreviewedAssetIDs[1]
        return assets.first { $0.localIdentifier == id }
    }
    var remainingCount: Int { reviewSession.remainingCount }
    var deletionQueue: [PHAsset] {
        let byID = Dictionary(uniqueKeysWithValues: allAssets.map { ($0.localIdentifier, $0) })
        return reviewSession.deletionIDs.compactMap { byID[$0] }
    }
    var lastHistoryEntry: SwipeHistoryEntry? { reviewSession.lastHistoryEntry }
    var isLimited: Bool { authorizationStatus == .limited }
    var hasPhotosOutsideFilter: Bool { !allAssets.isEmpty && assets.isEmpty }

    override init() {
        super.init()
        restoreProgress()
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

        allAssets = loaded
        applyCurrentFilter()
    }

    func setDateFilter(_ filter: PhotoDateFilter) {
        dateFilter = filter
        applyCurrentFilter()
    }

    private func applyCurrentFilter() {
        for favorite in allAssets where favorite.isFavorite && reviewSession.deletionIDs.contains(favorite.localIdentifier) {
            reviewSession.removeFromDeletionQueue(assetID: favorite.localIdentifier)
        }
        assets = allAssets.filter { dateFilter.contains($0.creationDate) }
        reviewSession.updateAssets(
            assets.map(\.localIdentifier),
            availableAssetIDs: Set(allAssets.map(\.localIdentifier))
        )
        persistProgress()
        state = assets.isEmpty ? .empty : .ready
        updatePrefetching()
    }

    func decide(_ decision: SwipeDecision) {
        guard let asset = currentAsset else { return }
        if decision == .delete, asset.isFavorite {
            safetyMessage = "This photo is marked as a Favorite. Unfavorite it in Photos before adding it to the deletion queue."
            HapticFeedback.warning()
            return
        }
        reviewSession.decide(decision)
        if decision == .delete { HapticFeedback.queuedForDeletion() } else { HapticFeedback.kept() }
        persistProgress()
        updatePrefetching()
    }

    func undoLastDecision() {
        reviewSession.undoLastDecision()
        HapticFeedback.undone()
        persistProgress()
        updatePrefetching()
    }

    func removeFromDeletionQueue(_ asset: PHAsset) {
        reviewSession.removeFromDeletionQueue(assetID: asset.localIdentifier)
        persistProgress()
    }

    func queueForDeletion(_ asset: PHAsset) {
        guard !asset.isFavorite else {
            safetyMessage = "Favorited photos are protected. Unfavorite this photo in Photos before queueing it."
            HapticFeedback.warning()
            return
        }
        reviewSession.queueForDeletion(assetID: asset.localIdentifier)
        HapticFeedback.queuedForDeletion()
        persistProgress()
    }

    func isQueuedForDeletion(_ asset: PHAsset) -> Bool {
        reviewSession.deletionIDs.contains(asset.localIdentifier)
    }

    func asset(withID id: String) -> PHAsset? {
        allAssets.first { $0.localIdentifier == id }
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
            allAssets.removeAll { deletedIDs.contains($0.localIdentifier) }
            reviewSession.removeDeletedAssets(deletedIDs)
            HapticFeedback.deletionCompleted()
            persistProgress()
            applyCurrentFilter()
            return true
        } catch {
            let nsError = error as NSError
            deletionErrorMessage = nsError.domain == PHPhotosError.errorDomain && nsError.code == PHPhotosError.Code.userCancelled.rawValue
                ? "Deletion was cancelled. No photos were deleted."
                : "Could not delete the selected photos: \(error.localizedDescription)"
            return false
        }
    }

    private func restoreProgress() {
        guard let data = UserDefaults.standard.data(forKey: progressKey),
              let progress = try? JSONDecoder().decode(PhotoReviewSession.Progress.self, from: data) else { return }
        reviewSession.restore(progress)
    }

    private func persistProgress() {
        guard let data = try? JSONEncoder().encode(reviewSession.progress) else { return }
        UserDefaults.standard.set(data, forKey: progressKey)
    }

    private func updatePrefetching() {
        let unreviewed = assets.filter { !reviewSession.reviewedIDs.contains($0.localIdentifier) }
        let nearby = Array(unreviewed.prefix(12))
        let nearbyIDs = Set(nearby.map(\.localIdentifier))
        let requestOptions = PHImageRequestOptions()
        requestOptions.deliveryMode = .opportunistic
        requestOptions.resizeMode = .fast
        requestOptions.isNetworkAccessAllowed = true
        let size = cardTargetSize

        let noLongerNeeded = allAssets.filter { cachedAssetIDs.contains($0.localIdentifier) && !nearbyIDs.contains($0.localIdentifier) }
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
