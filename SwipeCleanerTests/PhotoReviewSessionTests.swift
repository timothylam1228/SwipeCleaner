import XCTest

final class PhotoReviewSessionTests: XCTestCase {
    func testDeleteQueuesPhotoAndAdvances() {
        var session = makeSession()
        session.decide(.delete)
        XCTAssertEqual(session.currentAssetID, "newer")
        XCTAssertEqual(session.deletionIDs, ["newest"])
        XCTAssertEqual(session.remainingCount, 2)
    }

    func testKeepDoesNotQueuePhoto() {
        var session = makeSession()
        session.decide(.keep)
        XCTAssertEqual(session.currentAssetID, "newer")
        XCTAssertTrue(session.deletionIDs.isEmpty)
    }

    func testUpcomingAssetsUsesIndexedWindow() {
        var session = makeSession()
        XCTAssertEqual(session.upcomingAssetIDs(limit: 2), ["newest", "newer"])
        session.decide(.keep)
        XCTAssertEqual(session.upcomingAssetIDs(limit: 2), ["newer", "oldest"])
    }

    func testUndoRestoresLastDeletedPhotoAndRemovesItFromQueue() {
        var session = makeSession()
        session.decide(.delete)
        session.undoLastDecision()
        XCTAssertEqual(session.currentAssetID, "newest")
        XCTAssertTrue(session.deletionIDs.isEmpty)
        XCTAssertEqual(session.remainingCount, 3)
        XCTAssertNil(session.lastHistoryEntry)
    }

    func testUndoRestoresKeptPhoto() {
        var session = makeSession()
        session.decide(.keep)
        session.undoLastDecision()
        XCTAssertEqual(session.currentAssetID, "newest")
        XCTAssertEqual(session.remainingCount, 3)
    }

    func testLibraryInsertionDoesNotSkipNewPhoto() {
        var session = makeSession()
        session.decide(.keep)
        session.updateAssets(["just-added", "newest", "newer", "oldest"])
        XCTAssertEqual(session.currentAssetID, "just-added")
        XCTAssertEqual(session.remainingCount, 3)
    }

    func testUnavailablePhotosAreRemovedFromQueue() {
        var session = makeSession()
        session.decide(.delete)
        session.updateAssets(["newer", "oldest"])
        XCTAssertTrue(session.deletionIDs.isEmpty)
        XCTAssertNil(session.lastHistoryEntry)
    }

    func testChangingVisibleRangePreservesDeletionQueue() {
        var session = makeSession()
        session.decide(.delete)
        session.updateAssets(
            ["older"],
            availableAssetIDs: ["newest", "newer", "oldest", "older"]
        )
        XCTAssertEqual(session.deletionIDs, ["newest"])
        XCTAssertEqual(session.currentAssetID, "older")
    }

    func testRemovingOneQueuedPhotoPreservesOtherSelections() {
        var session = makeSession()
        session.decide(.delete)
        session.decide(.delete)
        session.removeFromDeletionQueue(assetID: "newest")
        XCTAssertEqual(session.deletionIDs, ["newer"])
        XCTAssertFalse(session.isQueuedForDeletion("newest"))
        XCTAssertTrue(session.isQueuedForDeletion("newer"))
    }

    func testProgressRoundTripPreservesReviewedAndQueuedPhotos() throws {
        var original = makeSession()
        original.decide(.delete)
        original.decide(.keep)
        let data = try JSONEncoder().encode(original.progress)
        let decoded = try JSONDecoder().decode(
            PhotoReviewSession.Progress.self,
            from: data
        )
        var restored = PhotoReviewSession()
        restored.restore(decoded)
        restored.updateAssets(["newest", "newer", "oldest"])
        XCTAssertEqual(restored.deletionIDs, ["newest"])
        XCTAssertEqual(restored.currentAssetID, "oldest")
        XCTAssertEqual(restored.remainingCount, 1)
    }

    func testSimilaritySelectionQueuesPhotoAndRemovesItFromUpcoming() {
        var session = makeSession()
        session.queueForDeletion(assetID: "newer")
        XCTAssertEqual(session.deletionIDs, ["newer"])
        XCTAssertEqual(session.currentAssetID, "newest")
        XCTAssertEqual(
            session.upcomingAssetIDs(limit: 3),
            ["newest", "oldest"]
        )
    }

    func testUndoAfterSimilaritySelectionRebuildsOriginalOrder() {
        var session = makeSession()
        session.queueForDeletion(assetID: "newer")
        session.undoLastDecision()
        XCTAssertEqual(
            session.upcomingAssetIDs(limit: 3),
            ["newest", "newer", "oldest"]
        )
        XCTAssertTrue(session.deletionIDs.isEmpty)
    }

    func testLargeSessionAdvancesInOrder() {
        let identifiers = (0..<50_000).map { "asset-\($0)" }
        var session = PhotoReviewSession()
        session.updateAssets(identifiers)

        for index in 0..<10_000 {
            XCTAssertEqual(session.currentAssetID, "asset-\(index)")
            session.decide(.keep)
        }

        XCTAssertEqual(session.currentAssetID, "asset-10000")
        XCTAssertEqual(session.remainingCount, 40_000)
        XCTAssertEqual(
            session.upcomingAssetIDs(limit: 3),
            ["asset-10000", "asset-10001", "asset-10002"]
        )
    }

    private func makeSession() -> PhotoReviewSession {
        var session = PhotoReviewSession()
        session.updateAssets(["newest", "newer", "oldest"])
        return session
    }
}
