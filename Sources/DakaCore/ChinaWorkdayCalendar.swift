import Foundation

public struct ChinaHolidayYear: Codable, Equatable, Sendable {
    public var year: Int
    public var region: String
    public var dates: [ChinaHolidayDate]

    public init(year: Int, region: String, dates: [ChinaHolidayDate]) {
        self.year = year
        self.region = region
        self.dates = dates
    }
}

public struct ChinaHolidayDate: Codable, Equatable, Sendable {
    public var date: String
    public var name: String
    public var nameCN: String?
    public var nameEN: String?
    public var type: ChinaHolidayDateType

    private enum CodingKeys: String, CodingKey {
        case date
        case name
        case nameCN = "name_cn"
        case nameEN = "name_en"
        case type
    }
}

public enum ChinaHolidayDateType: String, Codable, Sendable {
    case publicHoliday = "public_holiday"
    case transferWorkday = "transfer_workday"
}

public final class ChinaWorkdayCalendar {
    public static let primaryDataBaseURL = URL(string: "https://unpkg.com/holiday-calendar/data/CN")!
    public static let fallbackDataBaseURL = URL(string: "https://gcore.jsdelivr.net/gh/cg-zhou/holiday-calendar@main/data/CN")!

    private let calendar: Calendar
    private let cacheDirectory: URL
    private let decoder = JSONDecoder()

    public init(calendar: Calendar = .current, cacheDirectory: URL? = nil) {
        self.calendar = calendar

        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else if let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            self.cacheDirectory = appSupport
                .appendingPathComponent("Daka", isDirectory: true)
                .appendingPathComponent("ChinaCalendar", isDirectory: true)
        } else {
            self.cacheDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Daka-ChinaCalendar", isDirectory: true)
        }

        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    public func loadCachedYears(_ years: Set<Int>) -> [Int: ChinaHolidayYear] {
        var result: [Int: ChinaHolidayYear] = [:]
        for year in years {
            guard let data = try? Data(contentsOf: cacheURL(for: year)),
                  let holidayYear = try? decoder.decode(ChinaHolidayYear.self, from: data) else {
                continue
            }
            result[year] = holidayYear
        }
        return result
    }

    public func refreshYears(_ years: Set<Int>, completion: @escaping ([Int: ChinaHolidayYear]) -> Void) {
        DispatchQueue.global(qos: .utility).async { [cacheDirectory, decoder] in
            var result: [Int: ChinaHolidayYear] = [:]

            for year in years.sorted() {
                for baseURL in [Self.primaryDataBaseURL, Self.fallbackDataBaseURL] {
                    let url = baseURL.appendingPathComponent("\(year).json")
                    guard let data = try? Data(contentsOf: url),
                          let holidayYear = try? decoder.decode(ChinaHolidayYear.self, from: data) else {
                        continue
                    }

                    let cacheURL = cacheDirectory.appendingPathComponent("CN-\(year).json")
                    try? data.write(to: cacheURL, options: .atomic)
                    result[year] = holidayYear
                    break
                }
            }

            completion(result)
        }
    }

    public func isWorkday(dateKey: String, holidayYear: ChinaHolidayYear?) -> Bool {
        if let entry = holidayYear?.dates.first(where: { $0.date == dateKey }) {
            switch entry.type {
            case .publicHoliday:
                return false
            case .transferWorkday:
                return true
            }
        }

        guard let date = Self.dateFormatter.date(from: dateKey) else {
            return false
        }

        let weekday = calendar.component(.weekday, from: date)
        return weekday >= 2 && weekday <= 6
    }

    public static func year(from dateKey: String) -> Int? {
        Int(dateKey.prefix(4))
    }

    public static func monthKey(from dateKey: String) -> String {
        String(dateKey.prefix(7))
    }

    public static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func cacheURL(for year: Int) -> URL {
        cacheDirectory.appendingPathComponent("CN-\(year).json")
    }
}

public struct MonthlyWorkdaySummary: Equatable, Sendable {
    public var month: String
    public var workdayCount: Int
    public var recordedWorkdayCount: Int
    public var totalSeconds: TimeInterval
    public var averageSeconds: TimeInterval
    public var targetSeconds: TimeInterval
    public var usesChinaCalendarData: Bool

    public var isPassing: Bool {
        workdayCount > 0 && averageSeconds >= targetSeconds
    }
}

public enum MonthlyWorkdaySummarizer {
    public static func summaries(
        records: [DailyRecord],
        targetSeconds: TimeInterval,
        holidayYears: [Int: ChinaHolidayYear],
        calendar: ChinaWorkdayCalendar = ChinaWorkdayCalendar(),
        today: Date = Date()
    ) -> [MonthlyWorkdaySummary] {
        let recordByDate = Dictionary(uniqueKeysWithValues: records.map { ($0.date, $0) })
        let recordMonths = Set(records.map { ChinaWorkdayCalendar.monthKey(from: $0.date) })
        let todayKey = ChinaWorkdayCalendar.dateFormatter.string(from: today)
        let currentMonth = ChinaWorkdayCalendar.monthKey(from: todayKey)
        let months = (recordMonths.union([currentMonth])).sorted(by: >)

        return months.compactMap { month in
            guard let year = Int(month.prefix(4)),
                  let monthNumber = Int(month.suffix(2)) else {
                return nil
            }

            let dateKeys = dateKeysInMonth(year: year, month: monthNumber, upTo: month == currentMonth ? todayKey : nil)
            let holidayYear = holidayYears[year]
            let workdayKeys = dateKeys.filter { calendar.isWorkday(dateKey: $0, holidayYear: holidayYear) }
            guard !workdayKeys.isEmpty else {
                return nil
            }

            let recordedWorkdayCount = workdayKeys.filter { (recordByDate[$0]?.spanSeconds ?? 0) > 0 }.count
            let totalSeconds = workdayKeys.reduce(TimeInterval(0)) { partial, dateKey in
                partial + (recordByDate[dateKey]?.spanSeconds ?? 0)
            }
            let averageSeconds = totalSeconds / TimeInterval(workdayKeys.count)

            return MonthlyWorkdaySummary(
                month: month,
                workdayCount: workdayKeys.count,
                recordedWorkdayCount: recordedWorkdayCount,
                totalSeconds: totalSeconds,
                averageSeconds: averageSeconds,
                targetSeconds: targetSeconds,
                usesChinaCalendarData: holidayYear != nil
            )
        }
    }

    private static func dateKeysInMonth(year: Int, month: Int, upTo todayKey: String?) -> [String] {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = year
        components.month = month
        components.day = 1

        guard let start = components.date,
              let range = components.calendar?.range(of: .day, in: .month, for: start) else {
            return []
        }

        return range.compactMap { day -> String? in
            components.day = day
            guard let date = components.date else {
                return nil
            }

            let key = ChinaWorkdayCalendar.dateFormatter.string(from: date)
            if let todayKey, key > todayKey {
                return nil
            }
            return key
        }
    }
}
