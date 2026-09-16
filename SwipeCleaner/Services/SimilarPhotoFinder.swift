import Photos
import SwiftUI
import Vision

@MainActor
final class SimilarPhotoFinder: ObservableObject {
    enum State: Equatable {
        case idle
        case scanning(completed: Int, total: Int)
        case finished
        case cancelled
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var groups: [SimilarPhotoGroup] = []

    private var scanTask: Task<Void, Never>?
    private let maximumAssetCount = 250
    private let similarityThreshold: Float = 8

    var scanLimit: Int { maximumAssetCount }

    func scan(assets: [PHAsset], imageManager: PHImageManager) {
        cancel()
        groups = []
        let candidates = Array(assets.prefix(maximumAssetCount))
        guard candidates.count > 1 else {
            state = .finished
            return
        }

        state = .scanning(completed: 0, total: candidates.count)
        scanTask = Task { [weak self] in
            guard let self else { return }
            var observations: [(String, VNFeaturePrintObservation)] = []

            do {
                for (index, asset) in candidates.enumerated() {
                    try Task.checkCancellation()
                    let image = try await requestThumbnail(for: asset, manager: imageManager)
                    guard let cgImage = image.cgImage else { continue }
                    let observation = try await Task.detached(priority: .userInitiated) {
                        try Self.makeFeaturePrint(from: cgImage)
                    }.value
                    observations.append((asset.localIdentifier, observation))
                    state = .scanning(completed: index + 1, total: candidates.count)
                }

                try Task.checkCancellation()
                groups = Self.cluster(observations, threshold: similarityThreshold)
                state = .finished
            } catch is CancellationError {
                state = .cancelled
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
    }

    private func requestThumbnail(for asset: PHAsset, manager: PHImageManager) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            manager.requestImage(
                for: asset,
                targetSize: CGSize(width: 320, height: 320),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: CancellationError())
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: SimilarityError.imageUnavailable)
                }
            }
        }
    }

    private nonisolated static func makeFeaturePrint(from image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw SimilarityError.featurePrintUnavailable
        }
        return observation
    }

    private nonisolated static func cluster(
        _ observations: [(String, VNFeaturePrintObservation)],
        threshold: Float
    ) -> [SimilarPhotoGroup] {
        var consumed = Set<String>()
        var results: [SimilarPhotoGroup] = []

        for (index, candidate) in observations.enumerated() where !consumed.contains(candidate.0) {
            var group = [candidate.0]
            for comparison in observations.dropFirst(index + 1) where !consumed.contains(comparison.0) {
                var distance: Float = 0
                guard (try? candidate.1.computeDistance(&distance, to: comparison.1)) != nil,
                      distance <= threshold else { continue }
                group.append(comparison.0)
                consumed.insert(comparison.0)
            }
            if group.count > 1 {
                consumed.insert(candidate.0)
                results.append(SimilarPhotoGroup(assetIDs: group))
            }
        }
        return results
    }

    private enum SimilarityError: LocalizedError {
        case imageUnavailable
        case featurePrintUnavailable

        var errorDescription: String? {
            switch self {
            case .imageUnavailable: "A photo thumbnail could not be loaded."
            case .featurePrintUnavailable: "Vision could not analyze a photo."
            }
        }
    }
}
