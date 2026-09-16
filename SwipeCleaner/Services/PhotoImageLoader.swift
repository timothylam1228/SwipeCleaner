import Photos
import SwiftUI

@MainActor
final class PhotoImageCache {
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 8
        cache.totalCostLimit = 80 * 1_024 * 1_024
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, for key: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    static func key(
        assetID: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode
    ) -> String {
        let mode = contentMode == .aspectFill ? "fill" : "fit"
        return "\(assetID)|\(Int(targetSize.width.rounded()))x\(Int(targetSize.height.rounded()))|\(mode)"
    }
}

@MainActor
final class PhotoImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?

    private let manager: PHImageManager
    private let cache: PhotoImageCache
    private var requestID: PHImageRequestID = PHInvalidImageRequestID
    private var generation = 0

    init(manager: PHImageManager, cache: PhotoImageCache) {
        self.manager = manager
        self.cache = cache
    }

    func load(
        asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFit
    ) {
        cancel()
        generation += 1
        let requestGeneration = generation
        let cacheKey = PhotoImageCache.key(
            assetID: asset.localIdentifier,
            targetSize: targetSize,
            contentMode: contentMode
        )

        errorMessage = nil
        if let cachedImage = cache.image(for: cacheKey) {
            image = cachedImage
            isLoading = false
        } else {
            image = nil
            isLoading = true
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.progressHandler = { [weak self] _, error, _, _ in
            guard let error else { return }
            Task { @MainActor in
                guard let self, self.generation == requestGeneration else { return }
                self.errorMessage = error.localizedDescription
            }
        }

        requestID = manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode,
            options: options
        ) { [weak self] result, info in
            Task { @MainActor in
                guard let self, self.generation == requestGeneration else { return }
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                guard !cancelled else { return }

                if let result {
                    self.image = result
                    self.cache.insert(result, for: cacheKey)
                }

                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                if !degraded {
                    self.isLoading = false
                }
                if let error = info?[PHImageErrorKey] as? Error {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func cancel() {
        generation += 1
        if requestID != PHInvalidImageRequestID {
            manager.cancelImageRequest(requestID)
        }
        requestID = PHInvalidImageRequestID
    }

    deinit {
        if requestID != PHInvalidImageRequestID {
            manager.cancelImageRequest(requestID)
        }
    }
}
