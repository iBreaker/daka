import Foundation
import Testing

@testable import DakaCore

struct DakaStoreTests {
    @Test func savesAndLoadsConfigAndRecordsFromSQLite() throws {
        let directory = try temporaryDirectory()
        let paths = try DakaPaths(baseDirectory: directory)
        let store = try DakaStore(paths: paths)
        let config = AppConfig(
            rule: TimerRule(name: "Office", matchMode: .all, conditions: [.screenUnlocked, .powerConnected]),
            evaluationIntervalSeconds: 30,
            targetDurationSeconds: 8 * 60 * 60
        )
        let first = Date(timeIntervalSince1970: 1_779_250_400)
        let last = Date(timeIntervalSince1970: 1_779_282_800)
        let record = DailyRecord(
            date: "2026-05-20",
            firstMatchedAt: first,
            lastMatchedAt: last,
            excludedFromStats: true
        )

        try store.saveConfig(config)
        try store.saveRecords([record])

        let reloaded = try DakaStore(paths: paths)

        #expect(try reloaded.loadConfig() == config)
        #expect(try reloaded.loadRecords() == [record])
        #expect(FileManager.default.fileExists(atPath: paths.databaseURL.path))
    }

    @Test func upsertingOneRecordPreservesOtherRecords() throws {
        let directory = try temporaryDirectory()
        let store = try DakaStore(paths: DakaPaths(baseDirectory: directory))
        let first = DailyRecord(
            date: "2026-05-20",
            firstMatchedAt: Date(timeIntervalSince1970: 1_779_250_400),
            lastMatchedAt: Date(timeIntervalSince1970: 1_779_282_800)
        )
        let second = DailyRecord(date: "2026-05-21", excludedFromStats: true)
        try store.saveRecords([first, second])

        var updated = first
        updated.lastMatchedAt = first.lastMatchedAt?.addingTimeInterval(3_600)
        try store.upsertRecord(updated)

        #expect(try store.loadRecords() == [updated, second])
    }

    @Test func oldRecordJSONDefaultsToIncludedInStats() throws {
        let json = """
            {
              "date": "2026-05-20",
              "firstMatchedAt": "2026-05-20T09:00:00Z",
              "lastMatchedAt": "2026-05-20T18:00:00Z"
            }
            """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let record = try decoder.decode(DailyRecord.self, from: Data(json.utf8))

        #expect(record.excludedFromStats == false)
    }

    @Test func manualExcludedRecordsAreSkippedByMonthlyAndWeeklyStats() throws {
        let first = Date(timeIntervalSince1970: 1_779_250_400)
        let last = first.addingTimeInterval(8 * 60 * 60)
        let records = [
            DailyRecord(date: "2026-05-18", firstMatchedAt: first, lastMatchedAt: last),
            DailyRecord(date: "2026-05-19", firstMatchedAt: first, lastMatchedAt: last, excludedFromStats: true),
            DailyRecord(date: "2026-05-20", firstMatchedAt: first, lastMatchedAt: last),
        ]
        let monthlyDate = try #require(ISO8601DateFormatter().date(from: "2026-05-21T12:00:00Z"))
        let weeklyDate = try #require(ISO8601DateFormatter().date(from: "2026-05-20T12:00:00Z"))

        let monthly = MonthlyWorkdaySummarizer.summaries(
            records: records,
            targetSeconds: 8 * 60 * 60,
            holidayYears: [:],
            today: monthlyDate
        )
        let weekly = WeeklyWorkdaySummarizer.status(
            records: records,
            targetSeconds: 24 * 60 * 60,
            holidayYears: [:],
            at: weeklyDate
        )

        #expect(monthly.first?.workdayCount == 13)
        #expect(monthly.first?.recordedWorkdayCount == 2)
        #expect(monthly.first?.totalSeconds == TimeInterval(16 * 60 * 60))
        #expect(weekly.workdayCount == 2)
        #expect(weekly.totalSeconds == 16 * 60 * 60)
    }

    @Test func leaveDayWithoutClockRecordsReducesMonthlyWorkdayCount() throws {
        let records = [
            DailyRecord(date: "2026-06-10", excludedFromStats: true)
        ]
        let holidayYear = ChinaHolidayYear(
            year: 2026,
            region: "CN",
            dates: [
                ChinaHolidayDate(
                    date: "2026-06-19",
                    name: "Dragon Boat Festival",
                    nameCN: "端午节",
                    nameEN: "Dragon Boat Festival",
                    type: .publicHoliday
                )
            ]
        )
        let date = try #require(ISO8601DateFormatter().date(from: "2026-06-26T12:00:00Z"))

        let monthly = MonthlyWorkdaySummarizer.summaries(
            records: records,
            targetSeconds: 8 * 60 * 60,
            holidayYears: [2026: holidayYear],
            today: date
        )

        #expect(monthly.first?.month == "2026-06")
        #expect(monthly.first?.workdayCount == 17)
        #expect(monthly.first?.recordedWorkdayCount == 0)
        #expect(monthly.first?.totalSeconds == 0)
    }

    @Test func currentDayIsNotIncludedInMonthlyStatsUntilItEnds() throws {
        let first = Date(timeIntervalSince1970: 1_779_250_400)
        let records = [
            DailyRecord(
                date: "2026-05-19",
                firstMatchedAt: first,
                lastMatchedAt: first.addingTimeInterval(8 * 60 * 60)
            ),
            DailyRecord(
                date: "2026-05-20",
                firstMatchedAt: first,
                lastMatchedAt: first.addingTimeInterval(2 * 60 * 60)
            ),
        ]
        let date = try #require(ISO8601DateFormatter().date(from: "2026-05-20T12:00:00Z"))

        let monthly = MonthlyWorkdaySummarizer.summaries(
            records: records,
            targetSeconds: 8 * 60 * 60,
            holidayYears: [:],
            today: date
        )

        #expect(monthly.first?.workdayCount == 13)
        #expect(monthly.first?.recordedWorkdayCount == 1)
        #expect(monthly.first?.totalSeconds == TimeInterval(8 * 60 * 60))
        #expect(monthly.first?.averageSeconds == TimeInterval(8 * 60 * 60) / 13)
    }

    @Test func monthlyProjectionAddsTodayOnTopOfSettledDays() throws {
        let first = Date(timeIntervalSince1970: 1_779_250_400)
        let records = [
            DailyRecord(
                date: "2026-05-19",
                firstMatchedAt: first,
                lastMatchedAt: first.addingTimeInterval(8 * 60 * 60)
            ),
            DailyRecord(
                date: "2026-05-20",
                firstMatchedAt: first,
                lastMatchedAt: first.addingTimeInterval(2 * 60 * 60)
            ),
        ]
        let date = try #require(ISO8601DateFormatter().date(from: "2026-05-20T12:00:00Z"))

        let summary = try #require(
            MonthlyWorkdaySummarizer.summaries(
                records: records,
                targetSeconds: 8 * 60 * 60,
                holidayYears: [:],
                today: date
            ).first
        )

        // 已结束口径保持不变：不含今天。
        #expect(summary.workdayCount == 13)
        #expect(summary.totalSeconds == TimeInterval(8 * 60 * 60))

        // 含今日口径：多一个工作日，多今天这 2 小时。
        #expect(summary.includesToday)
        #expect(summary.todaySeconds == TimeInterval(2 * 60 * 60))
        #expect(summary.projectedWorkdayCount == 14)
        #expect(summary.projectedRecordedWorkdayCount == 2)
        #expect(summary.projectedTotalSeconds == TimeInterval(10 * 60 * 60))
        #expect(summary.projectedAverageSeconds == TimeInterval(10 * 60 * 60) / 14)
        #expect(summary.isProjectedPassing == false)
    }

    @Test func monthlyProjectionCountsTodayWithoutRecordAsZero() throws {
        let first = Date(timeIntervalSince1970: 1_779_250_400)
        let records = [
            DailyRecord(
                date: "2026-05-19",
                firstMatchedAt: first,
                lastMatchedAt: first.addingTimeInterval(8 * 60 * 60)
            )
        ]
        let date = try #require(ISO8601DateFormatter().date(from: "2026-05-20T12:00:00Z"))

        let summary = try #require(
            MonthlyWorkdaySummarizer.summaries(
                records: records,
                targetSeconds: 8 * 60 * 60,
                holidayYears: [:],
                today: date
            ).first
        )

        #expect(summary.includesToday)
        #expect(summary.todaySeconds == 0)
        #expect(summary.projectedWorkdayCount == 14)
        #expect(summary.projectedRecordedWorkdayCount == 1)
        #expect(summary.projectedTotalSeconds == TimeInterval(8 * 60 * 60))
    }

    @Test func monthlyProjectionSkipsTodayWhenExcludedFromStats() throws {
        let first = Date(timeIntervalSince1970: 1_779_250_400)
        let records = [
            DailyRecord(
                date: "2026-05-19",
                firstMatchedAt: first,
                lastMatchedAt: first.addingTimeInterval(8 * 60 * 60)
            ),
            DailyRecord(
                date: "2026-05-20",
                firstMatchedAt: first,
                lastMatchedAt: first.addingTimeInterval(2 * 60 * 60),
                excludedFromStats: true
            ),
        ]
        let date = try #require(ISO8601DateFormatter().date(from: "2026-05-20T12:00:00Z"))

        let summary = try #require(
            MonthlyWorkdaySummarizer.summaries(
                records: records,
                targetSeconds: 8 * 60 * 60,
                holidayYears: [:],
                today: date
            ).first
        )

        #expect(summary.includesToday == false)
        #expect(summary.todaySeconds == nil)
        #expect(summary.projectedWorkdayCount == summary.workdayCount)
        #expect(summary.projectedAverageSeconds == summary.averageSeconds)
    }

    @Test func monthlySummaryAppearsOnFirstWorkdayOfMonth() throws {
        let first = Date(timeIntervalSince1970: 1_779_250_400)
        let records = [
            DailyRecord(
                date: "2026-06-01",
                firstMatchedAt: first,
                lastMatchedAt: first.addingTimeInterval(3 * 60 * 60)
            )
        ]
        let date = try #require(ISO8601DateFormatter().date(from: "2026-06-01T12:00:00Z"))

        let summary = try #require(
            MonthlyWorkdaySummarizer.summaries(
                records: records,
                targetSeconds: 8 * 60 * 60,
                holidayYears: [:],
                today: date
            ).first { $0.month == "2026-06" }
        )

        // 当月还没有已结束的工作日，旧口径为空，但含今日口径仍然要能看到。
        #expect(summary.workdayCount == 0)
        #expect(summary.averageSeconds == 0)
        #expect(summary.includesToday)
        #expect(summary.projectedWorkdayCount == 1)
        #expect(summary.projectedAverageSeconds == TimeInterval(3 * 60 * 60))
    }

    @Test func migratesLegacyJSONIntoSQLite() throws {
        let directory = try temporaryDirectory()
        let paths = try DakaPaths(baseDirectory: directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601

        let config = AppConfig(
            rule: TimerRule(name: "Legacy", matchMode: .any, conditions: [.screenUnlocked]),
            evaluationIntervalSeconds: 45,
            targetDurationSeconds: 10.5 * 60 * 60
        )
        let record = DailyRecord(
            date: "2026-05-20",
            firstMatchedAt: Date(timeIntervalSince1970: 1_779_250_400),
            lastMatchedAt: Date(timeIntervalSince1970: 1_779_282_800)
        )

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(config).write(to: paths.configURL)
        try encoder.encode([record]).write(to: paths.recordsURL)

        let store = try DakaStore(paths: paths)

        #expect(try store.loadConfig() == config)
        #expect(try store.loadRecords() == [record])
    }

    @Test func migratesLegacyRecordsEvenWhenConfigAlreadyExists() throws {
        let directory = try temporaryDirectory()
        let paths = try DakaPaths(baseDirectory: directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = DailyRecord(
            date: "2026-05-20",
            firstMatchedAt: Date(timeIntervalSince1970: 1_779_250_400),
            lastMatchedAt: Date(timeIntervalSince1970: 1_779_282_800)
        )

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode([record]).write(to: paths.recordsURL)

        let firstStore = try DakaStore(paths: paths)
        try firstStore.saveConfig(.default)

        let reloaded = try DakaStore(paths: paths)

        #expect(try reloaded.loadRecords() == [record])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DakaStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
