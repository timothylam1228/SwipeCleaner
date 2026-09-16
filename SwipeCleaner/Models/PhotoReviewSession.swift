import Foundation

enum SwipeDecision: String, Codable, Equatable {
    case delete
    case keep
}

struct SwipeHistoryEntry: Equatable {
    let assetID: String
    let decision: SwipeDecision
}

struct PhotoReviewSession: Equatable {
    struct Progress: Codable, Equatable {
        let reviewedIDs: Set<String>
        let deletionIDs: [String]
    }

    private(set) var assetIDs: [String] = []
    private(set) var reviewedIDs: Set<String> = []
    private(set) var deletionIDs: [String] = []
    private(set) var lastHistoryEntry: SwipeHistoryEntry?

    var currentAssetID: String? {
        assetIDs.first { !reviewedIDs.contains($0) }
    }

    var remainingCount: Int {
        assetIDs.lazy.filter { !reviewedIDs.contains($0) }.count
    }

    var unreviewedAssetIDs: [String] {
        assetIDs.filter { !reviewedIDs.contains($0) }
    }

    var progress: Progress {
        Progress(reviewedIDs: reviewedIDs, deletionIDs: deletionIDs)
    }

    mutating func restore(_ progress: Progress) {
        reviewedIDs = progress.reviewedIDs
        deletionIDs = progress.deletionIDs
        lastHistoryEntry = nil
    }

    mutating func updateAssets(_ newAssetIDs: [String], availableAssetIDs: Set<String>? = nil) {
        assetIDs = newAssetIDs
        let available = availableAssetIDs ?? Set(newAssetIDs)
        reviewedIDs.formIntersection(available)
        deletionIDs.removeAll { !available.contains($0) }
        if let entry = lastHistoryEntry, !available.contains(entry.assetID) {
            lastHistoryEntry = nil
        }
    }

    mutating func decide(_ decision: SwipeDecision) {
        guard let assetID = currentAssetID else { return }
        reviewedIDs.insert(assetID)
        if decision == .delete, !deletionIDs.contains(assetID) {
            deletionIDs.append(assetID)
        }
        lastHistoryEntry = SwipeHistoryEntry(assetID: assetID, decision: decision)
    }

    mutating func undoLastDecision() {
        guard let entry = lastHistoryEntry else { return }
        reviewedIDs.remove(entry.assetID)
        if entry.decision == .delete {
            deletionIDs.removeAll { $0 == entry.assetID }
        }
        lastHistoryEntry = nil
    }

    mutating func removeFromDeletionQueue(assetID: String) {
        deletionIDs.removeAll { $0 == assetID }
    }

    mutating func queueForDeletion(assetID: String) {
        guard assetIDs.contains(assetID) else { return }
        reviewedIDs.insert(assetID)
        if !deletionIDs.contains(assetID) {
            deletionIDs.append(assetID)
        }
        lastHistoryEntry = SwipeHistoryEntry(assetID: assetID, decision: .delete)
    }

    mutating func removeDeletedAssets(_ deletedIDs: Set<String>) {
        assetIDs.removeAll { deletedIDs.contains($0) }
        reviewedIDs.subtract(deletedIDs)
        deletionIDs.removeAll { deletedIDs.contains($0) }
        if let entry = lastHistoryEntry, deletedIDs.contains(entry.assetID) {
            lastHistoryEntry = nil
        }
    }
}
