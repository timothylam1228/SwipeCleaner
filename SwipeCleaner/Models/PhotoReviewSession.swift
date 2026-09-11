import Foundation

enum SwipeDecision: Equatable {
    case delete
    case keep
}

struct SwipeHistoryEntry: Equatable {
    let assetID: String
    let decision: SwipeDecision
}

struct PhotoReviewSession: Equatable {
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

    mutating func updateAssets(_ newAssetIDs: [String]) {
        assetIDs = newAssetIDs
        let available = Set(newAssetIDs)
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

    mutating func removeDeletedAssets(_ deletedIDs: Set<String>) {
        assetIDs.removeAll { deletedIDs.contains($0) }
        reviewedIDs.subtract(deletedIDs)
        deletionIDs.removeAll { deletedIDs.contains($0) }
        if let entry = lastHistoryEntry, deletedIDs.contains(entry.assetID) {
            lastHistoryEntry = nil
        }
    }
}
