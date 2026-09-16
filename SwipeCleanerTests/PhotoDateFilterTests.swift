import XCTest

final class PhotoDateFilterTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 UTC

    func testAllPhotosIncludesMissingCreationDate() {
        XCTAssertTrue(PhotoDateFilter(preset: .all).contains(nil, calendar: calendar, now: now))
    }

    func testLastSevenDaysExcludesOlderPhoto() {
        let filter = PhotoDateFilter(preset: .last7Days)
        let eightDaysAgo = calendar.date(byAdding: .day, value: -8, to: now)!
        XCTAssertFalse(filter.contains(eightDaysAgo, calendar: calendar, now: now))
    }

    func testCustomRangeIncludesEntireFinalDay() {
        let start = calendar.date(byAdding: .day, value: -3, to: now)!
        let end = calendar.date(byAdding: .day, value: -1, to: now)!
        let lateOnEndDate = calendar.date(byAdding: .hour, value: 20, to: end)!
        let filter = PhotoDateFilter(preset: .custom, startDate: start, endDate: end)
        XCTAssertTrue(filter.contains(lateOnEndDate, calendar: calendar, now: now))
    }
}
