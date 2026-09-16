import Photos
import PhotosUI
import SwiftUI

@MainActor
final class PhotoLibraryManager: NSObject, ObservableObject {
    enum LoadState: Equatable {
        case idle, requestingPermission, loading, ready, empty, denied
        case failed(String)
    }

    private struct LibrarySnapshot: @unchecked Sendable {
        let assets: [PHAsset]
        let assetsByID: [String: PHAsset]
        let assetIDs: Set<String>
        let favoriteIDs: Set<String>
    }

    private struct FilteredSnapshot: @unchecked Sendable {
        let assets: [PHAsset]
        let assetIDs: [String]
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var authorizationStatus =
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var assets: [PHAsset] = []
    @Published private(set) var reviewSession = PhotoReviewSession()
    @Published private(set) var dateFilter = PhotoDateFilter()
    @Published private(set) var deletionQueue: [PHAsset] = []
    @Published var deletionErrorMessage: String?
    @Published var safetyMessage: String?
    @Published private(set) var isDeleting = false

    let imageManager = PHCachingImageManager()
    let imageCache = PhotoImageCache()

    private var allAssets: [PHAsset] = []
    private var assetsByID: [String: PHAsset] = [:]
    private var availableAssetIDs: Set<String> = []
    private var favoriteAssetIDs: Set<String> = []
    private var cachedAssetIDs: Set<String> = []
    private var cachedTargetSize = CGSize.zero

    private var loadTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var loadRevision = 0
    private var filterRevision = 0
    private var memoryWarningObserver: NSObjectProtocol?

    private let legacyProgressKey = "SwipeCleaner.reviewProgress.v1"
    private let prefetchCount = 4
    private let prefetchOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }()

    var cardTargetSize: CGSize {
        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        return CGSize(
            width: bounds.width * scale,
            height: min(bounds.height * 0.62, bounds.width * 1.5) * scale
        )
    }

    var thumbnailTargetSize: CGSize {
        let side = 140 * UIScreen.main.scale
        return CGSize(width: side, height: side)
    }

    var currentAsset: PHAsset? {
        guard let id = reviewSession.currentAssetID else { return nil }
        return assetsByID[id]
    }

    var nextAsset: PHAsset? {
        guard let id = reviewSession.nextAssetID else { return nil }
        return assetsByID[id]
    }

    var remainingCount: Int { reviewSession.remainingCount }
    var lastHistoryEntry: SwipeHistoryEntry? { reviewSession.lastHistoryEntry }
    var isLimited: Bool { authorizationStatus == .limited }
    var hasPhotosOutsideFilter: Bool { !allAssets.isEmpty && assets.isEmpty }

    override init() {
        super.init()
        restoreProgress()
        PHPhotoLibrary.shared().register(self)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clearImageCaches() }
        }
    }

    deinit {
        loadTask?.cancel()
        filterTask?.cancel()
        persistenceTask?.cancel()
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    func begin() async {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = current
        if current == .notDetermined {
            state = .requestingPermission
            authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        respondToAuthorization(forceReload: true)
    }

    func refreshAuthorizationAndPhotos() async {
        let previous = authorizationStatus
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let needsReload = previous != authorizationStatus || allAssets.isEmpty
        respondToAuthorization(forceReload: needsReload)
    }

    private func respondToAuthorization(forceReload: Bool) {
        switch authorizationStatus {
        case .authorized, .limited:
            if forceReload || state == .idle || state == .denied {
                loadPhotos()
            }
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
        loadRevision += 1
        let revision = loadRevision
        loadTask?.cancel()
        filterTask?.cancel()

        loadTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                let options = PHFetchOptions()
                options.sortDescriptors = [
                    NSSortDescriptor(key: "creationDate", ascending: false)
                ]
                let result = PHAsset.fetchAssets(with: .image, options: options)
                var loaded: [PHAsset] = []
                var byID: [String: PHAsset] = [:]
                var identifiers = Set<String>()
                var favorites = Set<String>()
                loaded.reserveCapacity(result.count)
                byID.reserveCapacity(result.count)
                identifiers.reserveCapacity(result.count)

                result.enumerateObjects { asset, _, stop in
                    if Task.isCancelled {
                        stop.pointee = true
                        return
                    }
                    let id = asset.localIdentifier
                    loaded.append(asset)
                    byID[id] = asset
                    identifiers.insert(id)
                    if asset.isFavorite {
                        favorites.insert(id)
                    }
                }
                return LibrarySnapshot(
                    assets: loaded,
                    assetsByID: byID,
                    assetIDs: identifiers,
                    favoriteIDs: favorites
                )
            }.value

            guard let self, !Task.isCancelled, revision == self.loadRevision else { return }
            self.allAssets = snapshot.assets
            self.assetsByID = snapshot.assetsByID
            self.availableAssetIDs = snapshot.assetIDs
            self.favoriteAssetIDs = snapshot.favoriteIDs
            self.applyCurrentFilter()
        }
    }

    func setDateFilter(_ filter: PhotoDateFilter) {
        dateFilter = filter
        applyCurrentFilter()
    }

    private func applyCurrentFilter() {
        filterRevision += 1
        let revision = filterRevision
        let source = allAssets
        let filter = dateFilter
        filterTask?.cancel()

        guard !source.isEmpty else {
            commitFilteredAssets([], ids: [])
            return
        }

        state = .loading
        filterTask = Task { [weak self] in
            let filtered = await Task.detached(priority: .userInitiated) {
                var matches: [PHAsset] = []
                var identifiers: [String] = []
                matches.reserveCapacity(source.count)
                identifiers.reserveCapacity(source.count)

                for asset in source {
                    guard !Task.isCancelled else { break }
                    if filter.contains(asset.creationDate) {
                        matches.append(asset)
                        identifiers.append(asset.localIdentifier)
                    }
                }
                return FilteredSnapshot(assets: matches, assetIDs: identifiers)
            }.value

            guard let self, !Task.isCancelled, revision == self.filterRevision else { return }
            self.commitFilteredAssets(filtered.assets, ids: filtered.assetIDs)
        }
    }

    private func commitFilteredAssets(_ filteredAssets: [PHAsset], ids: [String]) {
        let protectedIDs = reviewSession.deletionIDs.filter {
            favoriteAssetIDs.contains($0)
        }
        for id in protectedIDs {
            reviewSession.removeFromDeletionQueue(assetID: id)
        }

        assets = filteredAssets
        reviewSession.updateAssets(ids, availableAssetIDs: availableAssetIDs)
        refreshDeletionQueue()
        scheduleProgressSave()
        state = filteredAssets.isEmpty ? .empty : .ready
        updatePrefetching()
    }

    func decide(_ decision: SwipeDecision) {
        guard let asset = currentAsset else { return }
        if decision == .delete, favoriteAssetIDs.contains(asset.localIdentifier) {
            safetyMessage =
                "This photo is marked as a Favorite. Unfavorite it in Photos before adding it to the deletion queue."
            HapticFeedback.warning()
            return
        }

        reviewSession.decide(decision)
        if decision == .delete {
            HapticFeedback.queuedForDeletion()
        } else {
            HapticFeedback.kept()
        }
        refreshDeletionQueue()
        scheduleProgressSave()
        updatePrefetching()
    }

    func undoLastDecision() {
        reviewSession.undoLastDecision()
        HapticFeedback.undone()
        refreshDeletionQueue()
        scheduleProgressSave()
        updatePrefetching()
    }

    func removeFromDeletionQueue(_ asset: PHAsset) {
        reviewSession.removeFromDeletionQueue(assetID: asset.localIdentifier)
        refreshDeletionQueue()
        scheduleProgressSave()
    }

    func queueForDeletion(_ asset: PHAsset) {
        guard !favoriteAssetIDs.contains(asset.localIdentifier) else {
            safetyMessage =
                "Favorited photos are protected. Unfavorite this photo in Photos before queueing it."
            HapticFeedback.warning()
            return
        }
        reviewSession.queueForDeletion(assetID: asset.localIdentifier)
        HapticFeedback.queuedForDeletion()
        refreshDeletionQueue()
        scheduleProgressSave()
        updatePrefetching()
    }

    func isQueuedForDeletion(_ asset: PHAsset) -> Bool {
        reviewSession.isQueuedForDeletion(asset.localIdentifier)
    }

    func asset(withID id: String) -> PHAsset? {
        assetsByID[id]
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

            loadRevision += 1
            filterRevision += 1
            loadTask?.cancel()
            filterTask?.cancel()

            let deletedIDs = Set(queued.map(\.localIdentifier))
            allAssets.removeAll { deletedIDs.contains($0.localIdentifier) }
            for id in deletedIDs {
                assetsByID[id] = nil
            }
            availableAssetIDs.subtract(deletedIDs)
            favoriteAssetIDs.subtract(deletedIDs)
            reviewSession.removeDeletedAssets(deletedIDs)
            refreshDeletionQueue()
            HapticFeedback.deletionCompleted()
            scheduleProgressSave(immediately: true)
            applyCurrentFilter()
            return true
        } catch {
            let nsError = error as NSError
            deletionErrorMessage =
                nsError.domain == PHPhotosError.errorDomain
                && nsError.code == PHPhotosError.Code.userCancelled.rawValue
                ? "Deletion was cancelled. No photos were deleted."
                : "Could not delete the selected photos: \(error.localizedDescription)"
            return false
        }
    }

    func flushProgress() {
        scheduleProgressSave(immediately: true)
    }

    private func refreshDeletionQueue() {
        deletionQueue = reviewSession.deletionIDs.compactMap { assetsByID[$0] }
    }

    private func scheduleProgressSave(immediately: Bool = false) {
        persistenceTask?.cancel()
        let progress = reviewSession.progress
        persistenceTask = Task {
            if !immediately {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                Self.writeProgress(progress)
            }.value
        }
    }

    private func restoreProgress() {
        if let url = Self.progressFileURL(),
           let data = try? Data(contentsOf: url),
           let progress = try? JSONDecoder().decode(
               PhotoReviewSession.Progress.self,
               from: data
           ) {
            reviewSession.restore(progress)
            return
        }

        if let data = UserDefaults.standard.data(forKey: legacyProgressKey),
           let progress = try? JSONDecoder().decode(
               PhotoReviewSession.Progress.self,
               from: data
           ) {
            reviewSession.restore(progress)
            Self.writeProgress(progress)
            UserDefaults.standard.removeObject(forKey: legacyProgressKey)
        }
    }

    private nonisolated static func progressFileURL() -> URL? {
        guard let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let appDirectory = directory.appendingPathComponent(
            "SwipeCleaner",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: appDirectory,
            withIntermediateDirectories: true
        )
        return appDirectory.appendingPathComponent("ReviewProgress.json")
    }

    private nonisolated static func writeProgress(
        _ progress: PhotoReviewSession.Progress
    ) {
        guard let url = progressFileURL(),
              let data = try? JSONEncoder().encode(progress) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func updatePrefetching() {
        let targetSize = cardTargetSize
        if cachedTargetSize != targetSize {
            imageManager.stopCachingImagesForAllAssets()
            cachedAssetIDs.removeAll()
            cachedTargetSize = targetSize
        }

        let nearby = reviewSession
            .upcomingAssetIDs(limit: prefetchCount)
            .compactMap { assetsByID[$0] }
        let nearbyIDs = Set(nearby.map(\.localIdentifier))

        let noLongerNeeded = cachedAssetIDs
            .subtracting(nearbyIDs)
            .compactMap { assetsByID[$0] }
        if !noLongerNeeded.isEmpty {
            imageManager.stopCachingImages(
                for: noLongerNeeded,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: prefetchOptions
            )
        }

        let newlyNeeded = nearby.filter {
            !cachedAssetIDs.contains($0.localIdentifier)
        }
        if !newlyNeeded.isEmpty {
            imageManager.startCachingImages(
                for: newlyNeeded,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: prefetchOptions
            )
        }
        cachedAssetIDs = nearbyIDs
    }

    private func clearImageCaches() {
        imageManager.stopCachingImagesForAllAssets()
        imageCache.removeAll()
        cachedAssetIDs.removeAll()
        cachedTargetSize = .zero
        updatePrefetching()
    }
}

extension PhotoLibraryManager: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.loadPhotos()
        }
    }
}
