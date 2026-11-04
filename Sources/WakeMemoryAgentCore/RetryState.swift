import Foundation

/// Adapted from Wake's background memory request throttle.
/// All time is supplied by the caller so tests require no sleeps or network requests.
struct RetryState: Sendable {
    private(set) var consecutiveFailures = 0
    private(set) var nextAttemptAfter: Date?
    private(set) var lastAttemptAt: Date?
    let minimumInterval: TimeInterval
    let maximumFailureDelay: TimeInterval

    init(minimumInterval: TimeInterval = 60, maximumFailureDelay: TimeInterval = 1_800) {
        self.minimumInterval = minimumInterval
        self.maximumFailureDelay = maximumFailureDelay
    }

    func canAttempt(at now: Date) -> Bool {
        if let lastAttemptAt, now < lastAttemptAt { return true }
        return nextAttemptAfter.map { now >= $0 } ?? true
    }

    mutating func begin(at now: Date) {
        if let lastAttemptAt, now < lastAttemptAt { consecutiveFailures = 0 }
        lastAttemptAt = now
        nextAttemptAfter = now.addingTimeInterval(minimumInterval)
    }

    mutating func fail(at now: Date) {
        consecutiveFailures = min(6, consecutiveFailures + 1)
        let delay = min(maximumFailureDelay,
                        minimumInterval * pow(2, Double(consecutiveFailures - 1)))
        nextAttemptAfter = max(nextAttemptAfter ?? now, now.addingTimeInterval(delay))
    }

    mutating func succeed() { consecutiveFailures = 0 }
}

struct RequestBudget: Sendable {
    let dailyLimit: Int
    private var day: Int?
    private var count = 0

    mutating func consume(at date: Date) -> Bool {
        let currentDay = Int(floor(date.timeIntervalSince1970 / 86_400))
        if day == nil || currentDay > day! { day = currentDay; count = 0 }
        guard count < dailyLimit else { return false }
        count += 1
        return true
    }

    func nextRefill(at date: Date) -> Date {
        let currentDay = Int(floor(date.timeIntervalSince1970 / 86_400))
        return Date(timeIntervalSince1970: Double(max(day ?? currentDay, currentDay) + 1) * 86_400)
    }
}
