import Foundation
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
    private let concurrentRequestCount = 4

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

            do {
                let observations = try await analyze(
                    candidates,
                    imageManager: imageManager
                )
                try Task.checkCancellation()

                let clustered = try await Task.detached(priority: .userInitiated) {
                    try Self.cluster(
                        observations,
                        threshold: self.similarityThreshold
                    )
                }.value

                try Task.checkCancellation()
                groups = clustered
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

    private func analyze(
        _ assets: [PHAsset],
        imageManager: PHImageManager
    ) async throws -> [(String, VNFeaturePrintObservation)] {
        var observations: [(Int, String, VNFeaturePrintObservation)] = []
        var completed = 0
        var nextIndex = 0

        try await withThrowingTaskGroup(
            of: (Int, String, VNFeaturePrintObservation)?.self
        ) { group in
            func addNextTask() {
                guard nextIndex < assets.count else { return }
                let index = nextIndex
                let asset = assets[index]
                nextIndex += 1
                group.addTask {
                    try await Self.analyzeAsset(
                        asset,
                        index: index,
                        manager: imageManager
                    )
                }
            }

            for _ in 0..<min(concurrentRequestCount, assets.count) {
                addNextTask()
            }

            while let result = try await group.next() {
                try Task.checkCancellation()
                completed += 1
                state = .scanning(completed: completed, total: assets.count)
                if let result {
                    observations.append(result)
                }
                addNextTask()
            }
        }

        return observations
            .sorted { $0.0 < $1.0 }
            .map { ($0.1, $0.2) }
    }

    private nonisolated static func analyzeAsset(
        _ asset: PHAsset,
        index: Int,
        manager: PHImageManager
    ) async throws -> (Int, String, VNFeaturePrintObservation)? {
        do {
            let image = try await requestThumbnail(for: asset, manager: manager)
            try Task.checkCancellation()
            guard let cgImage = image.cgImage else { return nil }

            let observation = try await Task.detached(priority: .userInitiated) {
                try makeFeaturePrint(from: cgImage)
            }.value
            return (index, asset.localIdentifier, observation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // One inaccessible iCloud asset should not abort the entire scan.
            return nil
        }
    }

    private nonisolated static func requestThumbnail(
        for asset: PHAsset,
        manager: PHImageManager
    ) async throws -> UIImage {
        let token = ImageRequestToken(manager: manager)

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard token.install(continuation) else { return }

                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = true

                let requestID = manager.requestImage(
                    for: asset,
                    targetSize: CGSize(width: 320, height: 320),
                    contentMode: .aspectFill,
                    options: options
                ) { image, info in
                    if let error = info?[PHImageErrorKey] as? Error {
                        token.finish(.failure(error))
                    } else if (info?[PHImageCancelledKey] as? Bool) == true {
                        token.finish(.failure(CancellationError()))
                    } else if let image {
                        token.finish(.success(image))
                    } else {
                        token.finish(.failure(SimilarityError.imageUnavailable))
                    }
                }
                token.setRequestID(requestID)
            }
        } onCancel: {
            token.cancel()
        }
    }

    private nonisolated static func makeFeaturePrint(
        from image: CGImage
    ) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let observation =
            request.results?.first as? VNFeaturePrintObservation else {
            throw SimilarityError.featurePrintUnavailable
        }
        return observation
    }

    private nonisolated static func cluster(
        _ observations: [(String, VNFeaturePrintObservation)],
        threshold: Float
    ) throws -> [SimilarPhotoGroup] {
        var consumed = Set<String>()
        var results: [SimilarPhotoGroup] = []

        for (index, candidate) in observations.enumerated()
        where !consumed.contains(candidate.0) {
            try Task.checkCancellation()
            var group = [candidate.0]

            for comparison in observations.dropFirst(index + 1)
            where !consumed.contains(comparison.0) {
                var distance: Float = 0
                guard
                    (try? candidate.1.computeDistance(
                        &distance,
                        to: comparison.1
                    )) != nil,
                    distance <= threshold
                else { continue }

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
            case .imageUnavailable:
                "A photo thumbnail could not be loaded."
            case .featurePrintUnavailable:
                "Vision could not analyze a photo."
            }
        }
    }
}

private final class ImageRequestToken: @unchecked Sendable {
    private let manager: PHImageManager
    private let lock = NSLock()
    private var requestID = PHInvalidImageRequestID
    private var continuation: CheckedContinuation<UIImage, Error>?
    private var isFinished = false

    init(manager: PHImageManager) {
        self.manager = manager
    }

    func install(_ continuation: CheckedContinuation<UIImage, Error>) -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setRequestID(_ requestID: PHImageRequestID) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = isFinished
        lock.unlock()

        if shouldCancel {
            manager.cancelImageRequest(requestID)
        }
    }

    func finish(_ result: Result<UIImage, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let requestID = requestID
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        if requestID != PHInvalidImageRequestID {
            manager.cancelImageRequest(requestID)
        }
        continuation?.resume(throwing: CancellationError())
    }
}
