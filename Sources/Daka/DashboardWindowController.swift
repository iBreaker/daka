import AppKit
import Combine
import DakaCore
import SwiftUI

enum DakaDashboardSection: String, CaseIterable, Identifiable {
    case today
    case records
    case trends
    case monthly
    case settings

    var id: String { rawValue }
}

final class DakaDashboardViewModel: ObservableObject {
    @Published var selection: DakaDashboardSection = .today
    @Published private(set) var records: [DailyRecord]
    @Published private(set) var monthlySummaries: [MonthlyWorkdaySummary] = []
    @Published private(set) var conditionMatched: Bool
    @Published private(set) var statsPaused: Bool
    @Published private(set) var config: AppConfig
    @Published private(set) var canConfirmClockIn: Bool
    @Published private(set) var locationPermissionTitle: String
    @Published private(set) var locationPermissionNeedsAction: Bool
    @Published private(set) var storageError: String?
    @Published private(set) var targetDurationSeconds: TimeInterval
    @Published private(set) var monthlyAverageTargetSeconds: TimeInterval

    let onTogglePause: () -> Void
    let onConfirmClockIn: () -> Void
    let onOpenLocationSettings: () -> Void
    let onShowStorageError: () -> Void
    let onQuit: () -> Void

    private let onSaveRecord: (DailyRecord) -> Bool
    private let onSaveConfig: (AppConfig) -> Bool
    private let chinaCalendar = ChinaWorkdayCalendar()
    private var holidayYears: [Int: ChinaHolidayYear] = [:]

    init(
        records: [DailyRecord],
        config: AppConfig,
        conditionMatched: Bool,
        statsPaused: Bool,
        canConfirmClockIn: Bool,
        locationPermissionTitle: String,
        locationPermissionNeedsAction: Bool,
        storageError: String?,
        fetchRemoteCalendar: Bool = true,
        onSaveRecord: @escaping (DailyRecord) -> Bool,
        onSaveConfig: @escaping (AppConfig) -> Bool,
        onTogglePause: @escaping () -> Void,
        onConfirmClockIn: @escaping () -> Void,
        onOpenLocationSettings: @escaping () -> Void,
        onShowStorageError: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.records = records.sorted { $0.date > $1.date }
        self.config = config
        self.targetDurationSeconds = config.targetDurationSeconds
        self.monthlyAverageTargetSeconds = config.monthlyAverageTargetSeconds
        self.conditionMatched = conditionMatched
        self.statsPaused = statsPaused
        self.canConfirmClockIn = canConfirmClockIn
        self.locationPermissionTitle = locationPermissionTitle
        self.locationPermissionNeedsAction = locationPermissionNeedsAction
        self.storageError = storageError
        self.onSaveRecord = onSaveRecord
        self.onSaveConfig = onSaveConfig
        self.onTogglePause = onTogglePause
        self.onConfirmClockIn = onConfirmClockIn
        self.onOpenLocationSettings = onOpenLocationSettings
        self.onShowStorageError = onShowStorageError
        self.onQuit = onQuit
        refreshCalendar(fetchRemote: fetchRemoteCalendar)
    }

    var todayRecord: DailyRecord {
        records.first { $0.date == Self.dateKeyFormatter.string(from: Date()) }
            ?? DailyRecord(date: Self.dateKeyFormatter.string(from: Date()))
    }

    var todayProgress: Double {
        guard let span = todayRecord.spanSeconds, targetDurationSeconds > 0 else {
            return 0
        }
        return min(1, max(0, span / targetDurationSeconds))
    }

    var visibleWorkdayRecords: [DailyRecord] {
        records.filter { record in
            guard let year = ChinaWorkdayCalendar.year(from: record.date) else {
                return false
            }
            return chinaCalendar.isWorkday(
                dateKey: record.date,
                holidayYear: holidayYears[year]
            )
        }
    }

    var includedCompletedRecords: [DailyRecord] {
        visibleWorkdayRecords.filter {
            !$0.excludedFromStats
                && $0.spanSeconds != nil
                && $0.date < Self.dateKeyFormatter.string(from: Date())
        }
    }

    var historicalWorkdayRecords: [DailyRecord] {
        visibleWorkdayRecords.filter {
            $0.date < Self.dateKeyFormatter.string(from: Date())
        }
    }

    var currentMonthSummary: MonthlyWorkdaySummary? {
        let month = ChinaWorkdayCalendar.monthKey(
            from: Self.dateKeyFormatter.string(from: Date())
        )
        return monthlySummaries.first { $0.month == month }
    }

    var statusTitle: String {
        if statsPaused {
            return "已暂停"
        }
        return conditionMatched ? "满足打卡条件" : "等待满足条件"
    }

    var statusColor: Color {
        if statsPaused {
            return .orange
        }
        return conditionMatched ? DakaTheme.green : .secondary
    }

    var remainingText: String {
        let remaining = targetDurationSeconds - (todayRecord.spanSeconds ?? 0)
        if remaining <= 0 {
            return "今日已达标"
        }
        return "还差 \(DakaFormatters.duration(remaining))"
    }

    func update(
        records: [DailyRecord],
        config: AppConfig,
        conditionMatched: Bool,
        statsPaused: Bool,
        canConfirmClockIn: Bool,
        locationPermissionTitle: String,
        locationPermissionNeedsAction: Bool,
        storageError: String?
    ) {
        self.records = records.sorted { $0.date > $1.date }
        self.config = config
        self.targetDurationSeconds = config.targetDurationSeconds
        self.monthlyAverageTargetSeconds = config.monthlyAverageTargetSeconds
        self.conditionMatched = conditionMatched
        self.statsPaused = statsPaused
        self.canConfirmClockIn = canConfirmClockIn
        self.locationPermissionTitle = locationPermissionTitle
        self.locationPermissionNeedsAction = locationPermissionNeedsAction
        self.storageError = storageError
        refreshCalendar(fetchRemote: false)
    }

    func edit(_ record: DailyRecord) {
        guard
            let updated = RecordEditor.run(record: record),
            onSaveRecord(updated)
        else {
            return
        }
        replace(updated)
    }

    func toggleExcluded(_ record: DailyRecord) {
        var updated = record
        updated.excludedFromStats.toggle()
        guard onSaveRecord(updated) else {
            return
        }
        replace(updated)
    }

    func addLeaveDay() {
        guard let dateKey = LeaveDayPicker.run() else {
            return
        }

        var updated =
            records.first { $0.date == dateKey }
            ?? DailyRecord(date: dateKey)
        updated.excludedFromStats = true
        guard onSaveRecord(updated) else {
            return
        }
        replace(updated)
    }

    @discardableResult
    func saveConfig(_ nextConfig: AppConfig) -> Bool {
        guard onSaveConfig(nextConfig) else {
            return false
        }
        config = nextConfig
        targetDurationSeconds = nextConfig.targetDurationSeconds
        monthlyAverageTargetSeconds = nextConfig.monthlyAverageTargetSeconds
        recomputeMonthlySummaries()
        return true
    }

    func confirmClockIn() {
        onConfirmClockIn()
    }

    func displayDate(_ key: String) -> String {
        guard let date = Self.dateKeyFormatter.date(from: key) else {
            return key
        }
        return Self.displayDateFormatter.string(from: date)
    }

    func displayMonth(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2 else {
            return key
        }
        return "\(parts[0]) 年 \(Int(parts[1]) ?? 0) 月"
    }

    func progress(for record: DailyRecord) -> Double {
        guard
            !record.excludedFromStats,
            let span = record.spanSeconds,
            targetDurationSeconds > 0
        else {
            return 0
        }
        return min(1, max(0, span / targetDurationSeconds))
    }

    func progressColor(for record: DailyRecord) -> Color {
        if record.excludedFromStats {
            return .orange
        }
        switch ProgressStage.stage(
            spanSeconds: record.spanSeconds,
            targetSeconds: targetDurationSeconds
        ) {
        case .empty: return .secondary
        case .low: return .red
        case .medium: return .orange
        case .high: return DakaTheme.blue
        case .complete: return DakaTheme.green
        }
    }

    private func replace(_ record: DailyRecord) {
        records.removeAll { $0.date == record.date }
        records.append(record)
        records.sort { $0.date > $1.date }
        refreshCalendar(fetchRemote: false)
    }

    private func refreshCalendar(fetchRemote: Bool) {
        var years = Set(
            records.compactMap { ChinaWorkdayCalendar.year(from: $0.date) }
        )
        years.insert(Calendar.current.component(.year, from: Date()))
        holidayYears.merge(chinaCalendar.loadCachedYears(years)) { _, cached in
            cached
        }
        recomputeMonthlySummaries()

        guard fetchRemote else {
            return
        }
        chinaCalendar.refreshYears(years) { [weak self] refreshed in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.holidayYears.merge(refreshed) { _, remote in remote }
                self.recomputeMonthlySummaries()
            }
        }
    }

    private func recomputeMonthlySummaries() {
        monthlySummaries = MonthlyWorkdaySummarizer.summaries(
            records: records,
            targetSeconds: monthlyAverageTargetSeconds,
            holidayYears: holidayYears,
            calendar: chinaCalendar
        )
    }

    private static let dateKeyFormatter = ChinaWorkdayCalendar.dateFormatter

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日  EEE"
        return formatter
    }()
}

final class DashboardWindowController: NSWindowController {
    private let viewModel: DakaDashboardViewModel

    init(
        records: [DailyRecord],
        config: AppConfig,
        conditionMatched: Bool,
        statsPaused: Bool,
        canConfirmClockIn: Bool,
        locationPermissionTitle: String,
        locationPermissionNeedsAction: Bool,
        storageError: String?,
        onSaveRecord: @escaping (DailyRecord) -> Bool,
        onSaveConfig: @escaping (AppConfig) -> Bool,
        onTogglePause: @escaping () -> Void,
        onConfirmClockIn: @escaping () -> Void,
        onOpenLocationSettings: @escaping () -> Void,
        onShowStorageError: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        viewModel = DakaDashboardViewModel(
            records: records,
            config: config,
            conditionMatched: conditionMatched,
            statsPaused: statsPaused,
            canConfirmClockIn: canConfirmClockIn,
            locationPermissionTitle: locationPermissionTitle,
            locationPermissionNeedsAction: locationPermissionNeedsAction,
            storageError: storageError,
            onSaveRecord: onSaveRecord,
            onSaveConfig: onSaveConfig,
            onTogglePause: onTogglePause,
            onConfirmClockIn: onConfirmClockIn,
            onOpenLocationSettings: onOpenLocationSettings,
            onShowStorageError: onShowStorageError,
            onQuit: onQuit
        )

        let rootView = DakaDashboardView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Daka"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView,
        ]
        window.setContentSize(NSSize(width: 980, height: 680))
        window.minSize = NSSize(width: 840, height: 580)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(
        records: [DailyRecord],
        config: AppConfig,
        conditionMatched: Bool,
        statsPaused: Bool,
        canConfirmClockIn: Bool,
        locationPermissionTitle: String,
        locationPermissionNeedsAction: Bool,
        storageError: String?
    ) {
        viewModel.update(
            records: records,
            config: config,
            conditionMatched: conditionMatched,
            statsPaused: statsPaused,
            canConfirmClockIn: canConfirmClockIn,
            locationPermissionTitle: locationPermissionTitle,
            locationPermissionNeedsAction: locationPermissionNeedsAction,
            storageError: storageError
        )
    }

    func show(section: DakaDashboardSection = .today) {
        viewModel.selection = section
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

func renderDakaDashboardPreview(
    records: [DailyRecord],
    config: AppConfig,
    section: DakaDashboardSection,
    settingsSection: DakaSettingsSection = .goals,
    outputURL: URL
) throws {
    let viewModel = DakaDashboardViewModel(
        records: records,
        config: config,
        conditionMatched: true,
        statsPaused: false,
        canConfirmClockIn: false,
        locationPermissionTitle: "已授权",
        locationPermissionNeedsAction: false,
        storageError: nil,
        fetchRemoteCalendar: false,
        onSaveRecord: { _ in true },
        onSaveConfig: { _ in true },
        onTogglePause: {},
        onConfirmClockIn: {},
        onOpenLocationSettings: {},
        onShowStorageError: {},
        onQuit: {}
    )
    viewModel.selection = section
    let root = DakaDashboardView(
        viewModel: viewModel,
        settingsSection: settingsSection
    )
    .frame(width: 980, height: 680)
    .environment(\.colorScheme, .light)
    let hostingView = NSHostingView(rootView: root)
    hostingView.frame = NSRect(x: 0, y: 0, width: 980, height: 680)
    hostingView.appearance = NSAppearance(named: .aqua)
    hostingView.layoutSubtreeIfNeeded()
    hostingView.displayIfNeeded()

    guard
        let bitmap = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        )
    else {
        throw NSError(
            domain: "local.daka.menu.preview",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "无法创建 Daka 界面预览"]
        )
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "local.daka.menu.preview",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "无法编码 Daka 界面预览"]
        )
    }
    try data.write(to: outputURL, options: .atomic)
}

private struct DakaDashboardView: View {
    @ObservedObject var viewModel: DakaDashboardViewModel
    var settingsSection: DakaSettingsSection = .goals

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 216)
                .frame(maxHeight: .infinity)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 840, minHeight: 580)
        .tint(DakaTheme.blue)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            DakaBrand()
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .fixedSize(horizontal: false, vertical: true)

            Text("概览")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.8))
                .padding(.horizontal, 22)
                .padding(.bottom, 6)

            VStack(spacing: 3) {
                DakaSidebarButton(
                    title: "今日",
                    icon: "sun.max.fill",
                    section: .today,
                    selection: $viewModel.selection
                )
                DakaSidebarButton(
                    title: "每日记录",
                    icon: "calendar",
                    section: .records,
                    selection: $viewModel.selection
                )
                DakaSidebarButton(
                    title: "趋势",
                    icon: "chart.xyaxis.line",
                    section: .trends,
                    selection: $viewModel.selection
                )
                DakaSidebarButton(
                    title: "月度",
                    icon: "calendar.badge.clock",
                    section: .monthly,
                    selection: $viewModel.selection
                )
            }
            .padding(.horizontal, 12)

            Spacer()

            Divider()
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            DakaSidebarButton(
                title: "设置",
                icon: "gearshape.fill",
                section: .settings,
                selection: $viewModel.selection
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.selection {
        case .today:
            TodayDashboardView(viewModel: viewModel)
        case .records:
            DailyRecordsView(viewModel: viewModel)
        case .trends:
            TrendsDashboardView(viewModel: viewModel)
        case .monthly:
            MonthlyDashboardView(viewModel: viewModel)
        case .settings:
            DakaSettingsView(
                viewModel: viewModel,
                initialSection: settingsSection
            )
        }
    }
}

private struct DakaBrand: View {
    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [DakaTheme.blue, DakaTheme.green],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "clock.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 38, height: 38)
            .shadow(color: DakaTheme.blue.opacity(0.18), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text("Daka")
                    .font(.system(size: 16, weight: .semibold))
                Text("工作节奏")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct DakaSidebarButton: View {
    let title: String
    let icon: String
    let section: DakaDashboardSection
    @Binding var selection: DakaDashboardSection

    private var isSelected: Bool { selection == section }

    var body: some View {
        Button {
            selection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                    .foregroundColor(isSelected ? DakaTheme.blue : .secondary)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? DakaTheme.blue : .primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(
                ZStack(alignment: .leading) {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(DakaTheme.blue.opacity(0.11))
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(DakaTheme.blue)
                            .frame(width: 3)
                            .padding(.vertical, 7)
                    }
                }
            )
        }
        .buttonStyle(.plain)
    }
}

private struct TodayDashboardView: View {
    @ObservedObject var viewModel: DakaDashboardViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                todayHero
                timeCards
                monthCard
                recentRecords
            }
            .padding(30)
            .frame(maxWidth: 920, alignment: .leading)
        }
    }

    private var header: some View {
        DakaPageHeader(
            "今天，保持节奏",
            subtitle: Date().formatted(date: .long, time: .omitted)
        ) {
            HStack(spacing: 10) {
                if viewModel.canConfirmClockIn {
                    Button {
                        viewModel.confirmClockIn()
                    } label: {
                        Label("确认已打卡", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                DakaStatusPill(
                    text: viewModel.statusTitle,
                    tint: viewModel.statusColor
                )
            }
        }
    }

    private var todayHero: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text("今日跨度")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                Text(DakaFormatters.duration(viewModel.todayRecord.spanSeconds))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(viewModel.remainingText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.16))
                    .clipShape(Capsule())
            }

            Spacer()

            ZStack {
                DakaProgressRing(value: viewModel.todayProgress)
                    .frame(width: 118, height: 118)
                VStack(spacing: 2) {
                    Text(DakaFormatters.percent(viewModel.todayProgress))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("目标 \(DakaFormatters.duration(viewModel.targetDurationSeconds))")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.75))
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(DakaTheme.heroGradient)
                .shadow(color: DakaTheme.blue.opacity(0.30), radius: 14, y: 6)
        )
    }

    private var timeCards: some View {
        HStack(spacing: 12) {
            DakaMetricCard(
                title: "首次满足",
                value: DakaFormatters.shortTime(viewModel.todayRecord.firstMatchedAt),
                detail: "今天的起点",
                icon: "sunrise.fill",
                tint: DakaTheme.blue
            )
            DakaMetricCard(
                title: "最后满足",
                value: DakaFormatters.shortTime(viewModel.todayRecord.lastMatchedAt),
                detail: "最近一次更新",
                icon: "sunset.fill",
                tint: DakaTheme.orange
            )
            DakaMetricCard(
                title: "日目标",
                value: DakaFormatters.duration(viewModel.targetDurationSeconds),
                detail: "当前配置",
                icon: "scope",
                tint: DakaTheme.green
            )
        }
    }

    @ViewBuilder
    private var monthCard: some View {
        if let month = viewModel.currentMonthSummary {
            MonthlyAverageCard(
                summary: month,
                targetSeconds: viewModel.monthlyAverageTargetSeconds
            )
        }
    }

    private var recentRecords: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("最近记录")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("查看全部") {
                    viewModel.selection = .records
                }
                .buttonStyle(.link)
            }

            VStack(spacing: 0) {
                if viewModel.visibleWorkdayRecords.isEmpty {
                    DakaEmptyState(
                        icon: "calendar.badge.clock",
                        title: "还没有工作日记录",
                        detail: "满足打卡条件后，记录会自动出现在这里。"
                    )
                    .padding(.vertical, 18)
                } else {
                    ForEach(
                        Array(viewModel.visibleWorkdayRecords.prefix(5).enumerated()),
                        id: \.element.date
                    ) { index, record in
                        CompactRecordRow(record: record, viewModel: viewModel)
                        if index < min(4, viewModel.visibleWorkdayRecords.count - 1) {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            .background(DakaCardBackground())
            .overlay(DakaCardBorder(radius: 15))
        }
    }
}

private struct DailyRecordsView: View {
    @ObservedObject var viewModel: DakaDashboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            DakaPageHeader(
                "每日记录",
                subtitle: "\(viewModel.visibleWorkdayRecords.count) 个工作日记录"
            ) {
                Button {
                    viewModel.addLeaveDay()
                } label: {
                    Label("添加请假日", systemImage: "calendar.badge.minus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)

            Divider()

            ScrollView {
                if viewModel.visibleWorkdayRecords.isEmpty {
                    DakaEmptyState(
                        icon: "calendar.badge.clock",
                        title: "暂无每日记录",
                        detail: "满足打卡条件后，Daka 会自动记录每日跨度。"
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .padding(24)
                } else {
                    LazyVStack(spacing: 9) {
                        ForEach(viewModel.visibleWorkdayRecords, id: \.date) { record in
                            DailyRecordCard(record: record, viewModel: viewModel)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 860)
                }
            }
        }
    }
}

private struct TrendsDashboardView: View {
    @ObservedObject var viewModel: DakaDashboardViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DakaPageHeader(
                    "趋势",
                    subtitle: "最近的工作时长变化与完成分布。"
                )

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("最近 30 个工作日")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Label(
                            "目标 \(DakaFormatters.duration(viewModel.targetDurationSeconds))",
                            systemImage: "minus"
                        )
                        .font(.system(size: 10))
                        .foregroundColor(DakaTheme.green)
                    }
                    DakaTrendChart(
                        records: Array(
                            viewModel.includedCompletedRecords
                                .sorted { $0.date < $1.date }
                                .suffix(30)
                        ),
                        targetSeconds: viewModel.targetDurationSeconds
                    )
                    .frame(height: 260)
                }
                .padding(18)
                .background(DakaCardBackground(radius: 16))
                .overlay(DakaCardBorder(radius: 16))

                VStack(alignment: .leading, spacing: 14) {
                    Text("完成热力图")
                        .font(.system(size: 14, weight: .semibold))
                    DakaHeatmap(
                        records: Array(
                            viewModel.historicalWorkdayRecords
                                .sorted { $0.date < $1.date }
                                .suffix(84)
                        ),
                        targetSeconds: viewModel.targetDurationSeconds
                    )
                    .frame(height: 166)
                }
                .padding(18)
                .background(DakaCardBackground(radius: 16))
                .overlay(DakaCardBorder(radius: 16))
            }
            .padding(30)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }
}

private struct MonthlyDashboardView: View {
    @ObservedObject var viewModel: DakaDashboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            DakaPageHeader(
                "月度",
                subtitle: "月均目标 \(DakaFormatters.duration(viewModel.monthlyAverageTargetSeconds))"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)

            Divider()

            ScrollView {
                if viewModel.monthlySummaries.isEmpty {
                    DakaEmptyState(
                        icon: "calendar.badge.clock",
                        title: "暂无月度汇总",
                        detail: "产生工作日记录后，这里会展示月均进度。"
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .padding(24)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.monthlySummaries, id: \.month) { summary in
                            MonthlySummaryCard(
                                summary: summary,
                                title: viewModel.displayMonth(summary.month),
                                targetSeconds: viewModel.monthlyAverageTargetSeconds
                            )
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 850)
                }
            }
        }
    }
}

private struct CompactRecordRow: View {
    let record: DailyRecord
    @ObservedObject var viewModel: DakaDashboardViewModel

    var body: some View {
        HStack(spacing: 13) {
            Circle()
                .fill(viewModel.progressColor(for: record))
                .frame(width: 7, height: 7)
            Text(viewModel.displayDate(record.date))
                .font(.system(size: 12, weight: .medium))
                .frame(width: 105, alignment: .leading)
            Text(
                "\(DakaFormatters.shortTime(record.firstMatchedAt)) – \(DakaFormatters.shortTime(record.lastMatchedAt))"
            )
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)
            Spacer()
            Text(
                record.excludedFromStats
                    ? "请假"
                    : DakaFormatters.duration(record.spanSeconds)
            )
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(
                record.excludedFromStats
                    ? .orange
                    : viewModel.progressColor(for: record)
            )
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
    }
}

private struct DailyRecordCard: View {
    let record: DailyRecord
    @ObservedObject var viewModel: DakaDashboardViewModel

    var body: some View {
        HStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.displayDate(record.date))
                    .font(.system(size: 13, weight: .semibold))
                Text(
                    "\(DakaFormatters.shortTime(record.firstMatchedAt)) – \(DakaFormatters.shortTime(record.lastMatchedAt))"
                )
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            }
            .frame(width: 145, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(DakaFormatters.duration(record.spanSeconds))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(DakaFormatters.percent(viewModel.progress(for: record)))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(viewModel.progressColor(for: record))
                }
                DakaLinearProgress(
                    value: viewModel.progress(for: record),
                    tint: viewModel.progressColor(for: record)
                )
            }

            if record.excludedFromStats {
                DakaStatusPill(text: "不计入", tint: .orange)
            }

            Button {
                viewModel.edit(record)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑时间")

            Button {
                viewModel.toggleExcluded(record)
            } label: {
                Image(
                    systemName: record.excludedFromStats
                        ? "arrow.uturn.backward.circle"
                        : "minus.circle"
                )
            }
            .buttonStyle(.borderless)
            .help(record.excludedFromStats ? "恢复计入统计" : "不计入统计")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DakaCardBackground(radius: 14))
        .overlay(DakaCardBorder(radius: 14))
    }
}

private struct MonthlyAverageCard: View {
    let summary: MonthlyWorkdaySummary
    let targetSeconds: TimeInterval

    /// 今日页优先展示含今日的实时值，只有今天不计入统计时才回落到已结束的月均。
    private var headlineSeconds: TimeInterval {
        summary.includesToday ? summary.projectedAverageSeconds : summary.averageSeconds
    }

    private var headlinePassing: Bool {
        summary.includesToday ? summary.isProjectedPassing : summary.isPassing
    }

    private var workdayCount: Int {
        summary.includesToday ? summary.projectedWorkdayCount : summary.workdayCount
    }

    private var recordedWorkdayCount: Int {
        summary.includesToday ? summary.projectedRecordedWorkdayCount : summary.recordedWorkdayCount
    }

    var body: some View {
        HStack(spacing: 16) {
            DakaGlyph(icon: "calendar", tint: DakaTheme.blue)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text("本月平均")
                        .font(.system(size: 13, weight: .semibold))
                    if summary.includesToday {
                        DakaStatusPill(text: "含今日", tint: DakaTheme.blue)
                    }
                }
                Text("\(recordedWorkdayCount) 天有记录 · \(workdayCount) 个统计工作日")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                if summary.includesToday {
                    Text(
                        "已结束 \(DakaFormatters.duration(summary.averageSeconds)) · 今日 \(DakaFormatters.duration(summary.todaySeconds))"
                    )
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Text(DakaFormatters.duration(headlineSeconds))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    DakaStatusPill(
                        text: headlinePassing ? "达标" : "未达标",
                        tint: headlinePassing ? DakaTheme.green : DakaTheme.orange
                    )
                }
                DakaLinearProgress(
                    value: targetSeconds > 0 ? headlineSeconds / targetSeconds : 0,
                    tint: headlinePassing ? DakaTheme.green : DakaTheme.blue
                )
                .frame(width: 170)
                if summary.includesToday {
                    Text("今日还在计时，数值会随实时跨度变化")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .background(DakaCardBackground())
        .overlay(DakaCardBorder(radius: 15))
    }
}

private struct MonthlySummaryCard: View {
    let summary: MonthlyWorkdaySummary
    let title: String
    let targetSeconds: TimeInterval

    var body: some View {
        VStack(spacing: 13) {
            HStack(spacing: 16) {
                DakaGlyph(icon: "calendar", tint: DakaTheme.blue)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                        if !summary.usesChinaCalendarData {
                            DakaStatusPill(text: "估算", tint: DakaTheme.orange)
                        }
                    }
                    Text(
                        "\(summary.recordedWorkdayCount) 天有记录 / \(summary.workdayCount) 个工作日"
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("日均 \(DakaFormatters.duration(summary.averageSeconds))")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("合计 \(DakaFormatters.duration(summary.totalSeconds))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                DakaStatusPill(
                    text: summary.isPassing ? "达标" : "未达标",
                    tint: summary.isPassing ? DakaTheme.green : DakaTheme.orange
                )
            }

            HStack(spacing: 10) {
                DakaLinearProgress(
                    value: targetSeconds > 0
                        ? summary.averageSeconds / targetSeconds
                        : 0,
                    tint: summary.isPassing ? DakaTheme.green : DakaTheme.blue
                )
                Text(
                    DakaFormatters.percent(
                        targetSeconds > 0 ? summary.averageSeconds / targetSeconds : 0
                    )
                )
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(summary.isPassing ? DakaTheme.green : DakaTheme.blue)
                .frame(width: 38, alignment: .trailing)
            }

            if summary.includesToday {
                Divider()
                HStack(spacing: 10) {
                    DakaStatusPill(text: "含今日", tint: DakaTheme.blue)
                    Text(
                        "今日 \(DakaFormatters.duration(summary.todaySeconds)) · \(summary.projectedWorkdayCount) 个工作日"
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    Spacer()
                    Text("日均 \(DakaFormatters.duration(summary.projectedAverageSeconds))")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(
                            summary.isProjectedPassing ? DakaTheme.green : DakaTheme.blue
                        )
                    Text(
                        DakaFormatters.percent(
                            targetSeconds > 0
                                ? summary.projectedAverageSeconds / targetSeconds
                                : 0
                        )
                    )
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                    .frame(width: 38, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .background(DakaCardBackground(radius: 14))
        .overlay(DakaCardBorder(radius: 14))
    }
}

private struct DakaSettingRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(DakaTheme.blue)
                .frame(width: 28)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }
}

private struct DakaMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.11))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(value)
                .font(.system(size: 21, weight: .bold, design: .rounded))
            Text(detail)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
        .background(DakaCardBackground())
        .overlay(DakaCardBorder(radius: 15))
    }
}

private struct DakaGlyph: View {
    let icon: String
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(tint.opacity(0.12))
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(tint)
        }
        .frame(width: 42, height: 42)
    }
}

private struct DakaStatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.11))
            .clipShape(Capsule())
    }
}

private struct DakaLinearProgress: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(
                        width: max(
                            value > 0 ? 7 : 0,
                            geometry.size.width * min(1, max(0, value))
                        )
                    )
            }
        }
        .frame(height: 7)
    }
}

private struct DakaTrendChart: View {
    let records: [DailyRecord]
    let targetSeconds: TimeInterval

    var body: some View {
        Canvas { context, size in
            let inset = EdgeInsets(top: 12, leading: 46, bottom: 24, trailing: 12)
            let rect = CGRect(
                x: inset.leading,
                y: inset.top,
                width: max(1, size.width - inset.leading - inset.trailing),
                height: max(1, size.height - inset.top - inset.bottom)
            )
            let values = records.compactMap(\.spanSeconds)
            guard !values.isEmpty else {
                return
            }
            let observedMin = min(targetSeconds, values.min() ?? targetSeconds)
            let observedMax = max(targetSeconds, values.max() ?? targetSeconds)
            let padding = max(30 * 60, (observedMax - observedMin) * 0.18)
            let lowerBound = max(0, observedMin - padding)
            let upperBound = max(lowerBound + 1, observedMax + padding)
            let range = upperBound - lowerBound

            func yPosition(_ value: TimeInterval) -> CGFloat {
                rect.maxY - rect.height * CGFloat((value - lowerBound) / range)
            }

            for step in 0...3 {
                let ratio = Double(step) / 3
                let tickValue = upperBound - range * ratio
                let y = rect.minY + rect.height * CGFloat(ratio)
                var grid = Path()
                grid.move(to: CGPoint(x: rect.minX, y: y))
                grid.addLine(to: CGPoint(x: rect.maxX, y: y))
                context.stroke(grid, with: .color(.primary.opacity(0.07)))

                context.draw(
                    Text(axisLabel(tickValue))
                        .font(.system(size: 9, design: .rounded))
                        .foregroundColor(.secondary),
                    at: CGPoint(x: rect.minX - 8, y: y),
                    anchor: .trailing
                )
            }

            let targetY = yPosition(targetSeconds)
            var target = Path()
            target.move(to: CGPoint(x: rect.minX, y: targetY))
            target.addLine(to: CGPoint(x: rect.maxX, y: targetY))
            context.stroke(
                target,
                with: .color(DakaTheme.green.opacity(0.7)),
                style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
            )

            let points = values.enumerated().map { index, value -> CGPoint in
                let x =
                    values.count == 1
                    ? rect.midX
                    : rect.minX
                        + CGFloat(index) / CGFloat(values.count - 1) * rect.width
                let y = yPosition(value)
                return CGPoint(x: x, y: y)
            }

            var line = Path()
            line.move(to: points[0])
            if points.count == 1 {
                line.addLine(to: points[0])
            } else {
                for index in 0..<(points.count - 1) {
                    let previous = points[max(0, index - 1)]
                    let current = points[index]
                    let next = points[index + 1]
                    let following = points[min(points.count - 1, index + 2)]
                    let control1 = CGPoint(
                        x: current.x + (next.x - previous.x) / 6,
                        y: current.y + (next.y - previous.y) / 6
                    )
                    let control2 = CGPoint(
                        x: next.x - (following.x - current.x) / 6,
                        y: next.y - (following.y - current.y) / 6
                    )
                    line.addCurve(to: next, control1: control1, control2: control2)
                }
            }

            var area = line
            area.addLine(to: CGPoint(x: points.last?.x ?? rect.maxX, y: rect.maxY))
            area.addLine(to: CGPoint(x: points.first?.x ?? rect.minX, y: rect.maxY))
            area.closeSubpath()
            context.fill(area, with: .color(DakaTheme.blue.opacity(0.10)))

            context.stroke(
                line,
                with: .color(DakaTheme.blue),
                style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round)
            )
            for point in points {
                let dot = Path(
                    ellipseIn: CGRect(
                        x: point.x - 3,
                        y: point.y - 3,
                        width: 6,
                        height: 6
                    )
                )
                context.fill(dot, with: .color(DakaTheme.blue))
            }

            for index in xAxisIndices(count: records.count) {
                let x =
                    records.count == 1
                    ? rect.midX
                    : rect.minX
                        + CGFloat(index) / CGFloat(records.count - 1) * rect.width
                context.draw(
                    Text(shortDate(records[index].date))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary),
                    at: CGPoint(x: x, y: rect.maxY + 15)
                )
            }
        }
        .overlay {
            if records.isEmpty {
                Text("暂无趋势数据")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func axisLabel(_ seconds: TimeInterval) -> String {
        let hours = seconds / 3600
        if abs(hours.rounded() - hours) < 0.05 {
            return "\(Int(hours.rounded()))h"
        }
        return String(format: "%.1fh", hours)
    }

    private func shortDate(_ dateKey: String) -> String {
        let components = dateKey.split(separator: "-")
        guard components.count == 3 else {
            return dateKey
        }
        return "\(Int(components[1]) ?? 0)/\(Int(components[2]) ?? 0)"
    }

    private func xAxisIndices(count: Int) -> [Int] {
        guard count > 1 else {
            return count == 1 ? [0] : []
        }
        return Array(Set([0, count / 2, count - 1])).sorted()
    }
}

private struct DakaHeatmap: View {
    let records: [DailyRecord]
    let targetSeconds: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Canvas { context, size in
                let cell: CGFloat = 14
                let gap: CGFloat = 5
                for (index, record) in records.enumerated() {
                    let column = index / 7
                    let row = index % 7
                    let rect = CGRect(
                        x: CGFloat(column) * (cell + gap),
                        y: CGFloat(row) * (cell + gap),
                        width: cell,
                        height: cell
                    )
                    let path = Path(
                        roundedRect: rect,
                        cornerRadius: 3
                    )
                    context.fill(
                        path,
                        with: .color(color(for: record))
                    )
                }
            }
            .overlay {
                if records.isEmpty {
                    Text("暂无热力图数据")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 8) {
                Text("少")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                ForEach(heatLevels, id: \.self) { opacity in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(DakaTheme.blue.opacity(opacity))
                        .frame(width: 10, height: 10)
                }
                Text("多")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
                HeatLegend(label: "请假", color: DakaTheme.orange.opacity(0.55))
            }
        }
    }

    private let heatLevels: [Double] = [0.12, 0.30, 0.50, 0.72, 0.94]

    private func color(for record: DailyRecord) -> Color {
        guard !record.excludedFromStats else {
            return DakaTheme.orange.opacity(0.55)
        }
        switch ProgressStage.stage(
            spanSeconds: record.spanSeconds,
            targetSeconds: targetSeconds
        ) {
        case .empty: return DakaTheme.blue.opacity(0.12)
        case .low: return DakaTheme.blue.opacity(0.30)
        case .medium: return DakaTheme.blue.opacity(0.50)
        case .high: return DakaTheme.blue.opacity(0.72)
        case .complete: return DakaTheme.blue.opacity(0.94)
        }
    }
}

private struct HeatLegend: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }
}

private struct DakaEmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(DakaTheme.blue.opacity(0.75))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DakaCardBackground: View {
    var radius: CGFloat = 15

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(DakaTheme.cardFill)
            .shadow(color: DakaTheme.cardShadow, radius: 7, y: 3)
    }
}

private struct DakaCardBorder: View {
    let radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(DakaTheme.cardStroke, lineWidth: 1)
    }
}

private struct DakaProgressRing: View {
    let value: Double
    var tint: Color = .white
    var track: Color = .white.opacity(0.30)
    var lineWidth: CGFloat = 9

    var body: some View {
        ZStack {
            Circle()
                .stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, value)))
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct DakaPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let trailing: Trailing

    init(
        _ title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

extension DakaPageHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

enum DakaTheme {
    static let blue = Color(red: 0.18, green: 0.42, blue: 0.94)
    static let green = Color(red: 0.08, green: 0.62, blue: 0.41)
    static let orange = Color(red: 0.93, green: 0.52, blue: 0.10)
    static let red = Color(red: 0.88, green: 0.24, blue: 0.21)

    static let heroGradient = LinearGradient(
        colors: [
            Color(red: 0.14, green: 0.34, blue: 0.88),
            Color(red: 0.08, green: 0.58, blue: 0.62),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let cardStroke = Color.primary.opacity(0.07)
    static let cardShadow = Color.black.opacity(0.05)
}
