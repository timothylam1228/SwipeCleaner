import Foundation

enum PhotoDatePreset: String, CaseIterable, Identifiable {
    case all
    case last7Days
    case last30Days
    case thisYear
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All Photos"
        case .last7Days: "Last 7 Days"
        case .last30Days: "Last 30 Days"
        case .thisYear: "This Year"
        case .custom: "Custom Range"
        }
    }
}

struct PhotoDateFilter: Equatable {
    var preset: PhotoDatePreset = .all
    var startDate = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    var endDate = Date.now

    var title: String {
        guard preset == .custom else { return preset.title }
        return "\(startDate.formatted(date: .abbreviated, time: .omitted)) – \(endDate.formatted(date: .abbreviated, time: .omitted))"
    }

    func contains(_ creationDate: Date?, calendar: Calendar = .current, now: Date = .now) -> Bool {
        guard preset != .all else { return true }
        guard let creationDate else { return false }

        let today = calendar.startOfDay(for: now)
        let lowerBound: Date
        let upperBound: Date

        switch preset {
        case .all:
            return true
        case .last7Days:
            lowerBound = calendar.date(byAdding: .day, value: -6, to: today) ?? .distantPast
            upperBound = calendar.date(byAdding: .day, value: 1, to: today) ?? .distantFuture
        case .last30Days:
            lowerBound = calendar.date(byAdding: .day, value: -29, to: today) ?? .distantPast
            upperBound = calendar.date(byAdding: .day, value: 1, to: today) ?? .distantFuture
        case .thisYear:
            lowerBound = calendar.date(from: calendar.dateComponents([.year], from: now)) ?? .distantPast
            upperBound = calendar.date(byAdding: .year, value: 1, to: lowerBound) ?? .distantFuture
        case .custom:
            lowerBound = calendar.startOfDay(for: min(startDate, endDate))
            let finalDay = calendar.startOfDay(for: max(startDate, endDate))
            upperBound = calendar.date(byAdding: .day, value: 1, to: finalDay) ?? .distantFuture
        }
        return creationDate >= lowerBound && creationDate < upperBound
    }
}
