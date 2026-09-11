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

    func testRemovingOneQueuedPhotoPreservesOtherSelections() {
        var session = makeSession()
        session.decide(.delete)
        session.decide(.delete)

        session.removeFromDeletionQueue(assetID: "newest")

        XCTAssertEqual(session.deletionIDs, ["newer"])
    }

    private func makeSession() -> PhotoReviewSession {
        var session = PhotoReviewSession()
        session.updateAssets(["newest", "newer", "oldest"])
        return session
    }
}
