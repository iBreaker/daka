import Foundation
import Testing
@testable import DakaCore

struct DailyRecorderTests {
    @Test func firstAndLastAreSetWhenRuleFirstMatches() {
        let recorder = DailyRecorder(calendar: fixedCalendar)
        let date = makeDate("2026-05-20T09:10:00Z")

        let record = recorder.update(record: nil, matched: true, at: date)

        #expect(record.date == "2026-05-20")
        #expect(record.firstMatchedAt == date)
        #expect(record.lastMatchedAt == date)
        #expect(record.spanSeconds == 0)
    }

    @Test func unmatchedStateDoesNotMoveLastMatchedAt() {
        let recorder = DailyRecorder(calendar: fixedCalendar)
        let first = makeDate("2026-05-20T09:10:00Z")
        let away = makeDate("2026-05-20T12:00:00Z")
        let last = makeDate("2026-05-20T18:45:00Z")

        var record = recorder.update(record: nil, matched: true, at: first)
        record = recorder.update(record: record, matched: false, at: away)
        record = recorder.update(record: record, matched: true, at: last)

        #expect(record.firstMatchedAt == first)
        #expect(record.lastMatchedAt == last)
        #expect(record.spanSeconds == 34_500)
    }

    @Test func newDateStartsNewRecord() {
        let recorder = DailyRecorder(calendar: fixedCalendar)
        let first = makeDate("2026-05-20T09:10:00Z")
        let nextDay = makeDate("2026-05-21T08:55:00Z")

        let yesterday = recorder.update(record: nil, matched: true, at: first)
        let today = recorder.update(record: yesterday, matched: true, at: nextDay)

        #expect(today.date == "2026-05-21")
        #expect(today.firstMatchedAt == nextDay)
        #expect(today.lastMatchedAt == nextDay)
    }

    private var fixedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
