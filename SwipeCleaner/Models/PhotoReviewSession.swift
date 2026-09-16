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

    private var availableAssetIDs: Set<String> = []
    private var deletionIDSet: Set<String> = []
    private var reviewQueue: [String] = []
    private var reviewIndex = 0

    var currentAssetID: String? {
        guard reviewQueue.indices.contains(reviewIndex) else { return nil }
        return reviewQueue[reviewIndex]
    }

    var nextAssetID: String? {
        let index = reviewIndex + 1
        guard reviewQueue.indices.contains(index) else { return nil }
        return reviewQueue[index]
    }

    var remainingCount: Int {
        max(0, reviewQueue.count - reviewIndex)
    }

    var unreviewedAssetIDs: [String] {
        guard reviewIndex < reviewQueue.count else { return [] }
        return Array(reviewQueue[reviewIndex...])
    }

    var progress: Progress {
        Progress(reviewedIDs: reviewedIDs, deletionIDs: deletionIDs)
    }

    func isQueuedForDeletion(_ assetID: String) -> Bool {
        deletionIDSet.contains(assetID)
    }

    func upcomingAssetIDs(limit: Int) -> [String] {
        guard limit > 0, reviewIndex < reviewQueue.count else { return [] }
        return Array(reviewQueue[reviewIndex..<min(reviewQueue.count, reviewIndex + limit)])
    }

    mutating func restore(_ progress: Progress) {
        reviewedIDs = progress.reviewedIDs
        deletionIDs = progress.deletionIDs
        deletionIDSet = Set(progress.deletionIDs)
        lastHistoryEntry = nil
    }

    mutating func updateAssets(_ newAssetIDs: [String], availableAssetIDs: Set<String>? = nil) {
        assetIDs = newAssetIDs
        self.availableAssetIDs = availableAssetIDs ?? Set(newAssetIDs)
        reviewedIDs.formIntersection(self.availableAssetIDs)
        deletionIDs.removeAll { !self.availableAssetIDs.contains($0) }
        deletionIDSet = Set(deletionIDs)
        rebuildReviewQueue()

        if let entry = lastHistoryEntry, !self.availableAssetIDs.contains(entry.assetID) {
            lastHistoryEntry = nil
        }
    }

    mutating func decide(_ decision: SwipeDecision) {
        guard let assetID = currentAssetID else { return }
        reviewedIDs.insert(assetID)
        if decision == .delete, deletionIDSet.insert(assetID).inserted {
            deletionIDs.append(assetID)
        }
        lastHistoryEntry = SwipeHistoryEntry(assetID: assetID, decision: decision)
        reviewIndex += 1
    }

    mutating func undoLastDecision() {
        guard let entry = lastHistoryEntry else { return }
        reviewedIDs.remove(entry.assetID)
        if entry.decision == .delete {
            deletionIDSet.remove(entry.assetID)
            deletionIDs.removeAll { $0 == entry.assetID }
        }
        lastHistoryEntry = nil
        rebuildReviewQueue()
    }

    mutating func removeFromDeletionQueue(assetID: String) {
        guard deletionIDSet.remove(assetID) != nil else { return }
        deletionIDs.removeAll { $0 == assetID }
    }

    mutating func queueForDeletion(assetID: String) {
        guard availableAssetIDs.contains(assetID) else { return }
        reviewedIDs.insert(assetID)
        if deletionIDSet.insert(assetID).inserted {
            deletionIDs.append(assetID)
        }
        lastHistoryEntry = SwipeHistoryEntry(assetID: assetID, decision: .delete)

        if let index = reviewQueue[reviewIndex...].firstIndex(of: assetID) {
            reviewQueue.remove(at: index)
        }
    }

    mutating func removeDeletedAssets(_ deletedIDs: Set<String>) {
        assetIDs.removeAll { deletedIDs.contains($0) }
        availableAssetIDs.subtract(deletedIDs)
        reviewedIDs.subtract(deletedIDs)
        deletionIDSet.subtract(deletedIDs)
        deletionIDs.removeAll { deletedIDs.contains($0) }
        if let entry = lastHistoryEntry, deletedIDs.contains(entry.assetID) {
            lastHistoryEntry = nil
        }
        rebuildReviewQueue()
    }

    private mutating func rebuildReviewQueue() {
        reviewQueue = assetIDs.filter { !reviewedIDs.contains($0) }
        reviewIndex = 0
    }
}
