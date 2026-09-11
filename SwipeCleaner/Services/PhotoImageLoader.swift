import Photos
import SwiftUI

@MainActor
final class PhotoImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?

    private let manager: PHImageManager
    private var requestID: PHImageRequestID = PHInvalidImageRequestID

    init(manager: PHImageManager) {
        self.manager = manager
    }

    func load(asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode = .aspectFit) {
        cancel()
        image = nil
        errorMessage = nil
        isLoading = true

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.progressHandler = { [weak self] _, error, _, _ in
            guard let error else { return }
            Task { @MainActor in self?.errorMessage = error.localizedDescription }
        }

        requestID = manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: options) { [weak self] image, info in
            Task { @MainActor in
                guard let self else { return }
                if let image { self.image = image }
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                if !cancelled && !degraded { self.isLoading = false }
                if let error = info?[PHImageErrorKey] as? Error {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func cancel() {
        if requestID != PHInvalidImageRequestID { manager.cancelImageRequest(requestID) }
        requestID = PHInvalidImageRequestID
    }

    deinit {
        if requestID != PHInvalidImageRequestID { manager.cancelImageRequest(requestID) }
    }
}

