import AppKit
import CoreGraphics
import CoreLocation
import DakaCore
import Foundation

private func dakaDisplayReconfigurationCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else {
        return
    }

    let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async {
        delegate.evaluateAndRender()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var config: AppConfig = .default
    private var records: [DailyRecord] = []
    private var currentRecord: DailyRecord?
    private let checker = MacConditionChecker()
    private let recorder = DailyRecorder()
    private var store: DakaStore?
    private var storageError: String?
    private var lastMatched = false
    private let evaluationQueue = DispatchQueue(label: "local.daka.menu.condition-evaluation", qos: .userInitiated)
    private var evaluationInProgress = false
    private var evaluationRequestedWhileBusy = false
    private var statsWindowController: DashboardWindowController?
    private var showDashboardObserver: NSObjectProtocol?
    private var isShowingClockInReminder = false
    private var nextClockInReminderAt: Date?
    private let chinaCalendar = ChinaWorkdayCalendar()
    private var holidayYears: [Int: ChinaHolidayYear] = [:]
    private var statsPaused = UserDefaults.standard.bool(forKey: "Daka.statsPaused")
    private var displayReconfigurationCallbackRegistered = false
    private lazy var locationPermissionRequester = LocationPermissionRequester { [weak self] in
        self?.renderMenu()
        self?.updateDashboardIfVisible()
        self?.evaluateAndRender()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStore()
        setupChinaCalendar()
        setupStatusItem()
        setupNotifications()
        setupDisplayNotifications()
        requestWiFiPermissionIfNeeded()
        evaluateAndRender()
        startTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistCurrentRecord()
        if let showDashboardObserver {
            DistributedNotificationCenter.default().removeObserver(
                showDashboardObserver
            )
        }
        if displayReconfigurationCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(
                dakaDisplayReconfigurationCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showStats()
        return true
    }

    private func setupStore() {
        do {
            let paths = try DakaPaths()
            let openedStore = try DakaStore(paths: paths)
            store = openedStore
            config = try openedStore.loadConfig()
            records = try openedStore.loadRecords()
            currentRecord = records.first { $0.date == recorder.dateKey(for: Date()) }
            storageError = nil
        } catch {
            store = nil
            config = .default
            records = []
            currentRecord = nil
            storageError = "无法打开数据存储：\(error.localizedDescription)"
            NSLog("Daka storage setup failed: \(error)")
        }
    }

    private func setupDisplayNotifications() {
        let error = CGDisplayRegisterReconfigurationCallback(
            dakaDisplayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        displayReconfigurationCallbackRegistered = error == .success
        if error != .success {
            NSLog("Daka failed to register display callback: \(error.rawValue)")
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Daka"
        renderMenu()
    }

    private func setupNotifications() {
        let center = DistributedNotificationCenter.default()
        let notifications: [(String, Bool?)] = [
            ("com.apple.screensaver.didstart", true),
            ("com.apple.screensaver.didstop", false),
            ("com.apple.screenIsLocked", nil),
            ("com.apple.screenIsUnlocked", nil)
        ]

        for (name, screenSaverState) in notifications {
            center.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                if let screenSaverState {
                    self?.checker.isScreenSaverRunning = screenSaverState
                }
                self?.evaluateAndRender()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.evaluateAndRender()
        }

        showDashboardObserver = center.addObserver(
            forName: Notification.Name("local.daka.menu.show"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let section = (notification.object as? String)
                .flatMap(DakaDashboardSection.init(rawValue:))
                ?? .today
            self?.showDashboard(section: section)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: max(10, config.evaluationIntervalSeconds),
            repeats: true
        ) { [weak self] _ in
            self?.evaluateAndRender()
        }
    }

    @objc fileprivate func evaluateAndRender() {
        guard !evaluationInProgress else {
            evaluationRequestedWhileBusy = true
            return
        }

        evaluationInProgress = true
        let now = Date()
        let rule = config.rule
        let checker = checker

        evaluationQueue.async { [weak self] in
            let evaluator = RuleEvaluator(checker: checker)
            let matched = evaluator.evaluate(rule, at: now)
            DispatchQueue.main.async {
                self?.finishEvaluation(matched: matched, at: now)
            }
        }
    }

    private func finishEvaluation(matched: Bool, at now: Date) {
        evaluationInProgress = false
        let shouldRecord = matched && !statsPaused
        let wasRecording = lastMatched

        currentRecord = recorder.update(record: currentRecord, matched: false, at: now)

        if shouldRecord {
            if currentRecord?.firstMatchedAt == nil {
                if usesExternalDisplayCondition {
                    currentRecord = recorder.update(record: currentRecord, matched: true, at: now)
                    persistCurrentRecord()
                } else {
                    showClockInReminderIfNeeded(at: now)
                }
            } else {
                currentRecord = recorder.update(record: currentRecord, matched: true, at: now)
                persistCurrentRecord()
            }
        } else if shouldCloseExternalDisplaySession(wasRecording: wasRecording, matched: matched) {
            currentRecord?.lastMatchedAt = now
            persistCurrentRecord()
        }
        lastMatched = shouldRecord

        showRestDayReminderIfNeeded(at: now)

        renderStatusTitle()
        renderMenu()
        updateDashboardIfVisible()

        if evaluationRequestedWhileBusy {
            evaluationRequestedWhileBusy = false
            evaluateAndRender()
        }
    }

    private func persistCurrentRecord() {
        guard let currentRecord else {
            return
        }

        records.removeAll { $0.date == currentRecord.date }
        records.append(currentRecord)

        _ = persist(record: currentRecord, operation: "保存打卡记录", presentError: false)
    }

    private func renderStatusTitle() {
        let title = DakaFormatters.duration(currentRecord?.spanSeconds)
        let text = title
        let attributedTitle = NSMutableAttributedString(
            string: text,
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.menuBarFont(ofSize: 0)
            ]
        )
        statusItem.button?.image = ProgressBarImageRenderer.image(value: progressValue, color: progressColor)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.attributedTitle = attributedTitle
    }

    private func renderMenu() {
        let menu = NSMenu()

        menu.addItem(withTitle: "今日首次：\(DakaFormatters.shortTime(currentRecord?.firstMatchedAt))", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "今日最后：\(DakaFormatters.shortTime(currentRecord?.lastMatchedAt))", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "今日跨度：\(DakaFormatters.duration(currentRecord?.spanSeconds))", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "目标时长：\(DakaFormatters.duration(config.targetDurationSeconds))", action: nil, keyEquivalent: "")
        menu.addItem(progressMenuItem())
        menu.addItem(.separator())
        menu.addItem(statusMenuItem())

        if requiresWiFiPermission {
            let permissionStatus = locationPermissionRequester.status
            let item = NSMenuItem(
                title: "Wi-Fi 权限：\(permissionStatus.title)",
                action: permissionStatus.needsUserAction ? #selector(openLocationSettings) : nil,
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }

        if storageError != nil {
            let item = NSMenuItem(title: "数据存储：异常（点击查看）", action: #selector(showStorageError), keyEquivalent: "")
            item.target = self
            item.attributedTitle = NSAttributedString(
                string: item.title,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
            menu.addItem(item)
        }
        menu.addItem(.separator())

        if lastMatched && currentRecord?.firstMatchedAt == nil {
            let confirmItem = NSMenuItem(title: "确认今日已打卡", action: #selector(confirmTodayClockIn), keyEquivalent: "d")
            confirmItem.target = self
            menu.addItem(confirmItem)
            menu.addItem(.separator())
        }

        let recordsItem = NSMenuItem(
            title: "打开 Daka",
            action: #selector(showStats),
            keyEquivalent: "o"
        )
        recordsItem.target = self
        menu.addItem(recordsItem)

        let configItem = NSMenuItem(
            title: "设置…",
            action: #selector(showConfig),
            keyEquivalent: ","
        )
        configItem.target = self
        menu.addItem(configItem)

        let leaveItem = NSMenuItem(title: "添加请假日…", action: #selector(addLeaveDayFromMenu), keyEquivalent: "l")
        leaveItem.target = self
        menu.addItem(leaveItem)

        let pauseItem = NSMenuItem(title: statsPaused ? "恢复统计" : "暂停统计", action: #selector(toggleStatsPaused), keyEquivalent: "p")
        pauseItem.target = self
        pauseItem.state = statsPaused ? .on : .off
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private var statusText: String {
        if statsPaused {
            return "已暂停统计"
        }

        return lastMatched ? "满足条件" : "未满足条件"
    }

    private var statusDetailText: String {
        if statsPaused {
            return "暂停后不会更新今日最后时间"
        }

        if lastMatched {
            return "正在记录今日时长"
        }

        return usesExternalDisplayCondition
            ? "外接显示屏未连接，已停止刷新"
            : "等待规则满足后开始记录"
    }

    private var statusColor: NSColor {
        if statsPaused {
            return .secondaryLabelColor
        }

        return lastMatched ? .systemGreen : .systemRed
    }

    private var progressValue: Double {
        guard let spanSeconds = currentRecord?.spanSeconds, config.targetDurationSeconds > 0 else {
            return 0
        }

        return min(1, max(0, spanSeconds / config.targetDurationSeconds))
    }

    private var progressColor: NSColor {
        switch ProgressStage.stage(
            spanSeconds: currentRecord?.spanSeconds,
            targetSeconds: config.targetDurationSeconds
        ) {
        case .empty:
            return .tertiaryLabelColor
        case .low:
            return .systemRed
        case .medium:
            return .systemOrange
        case .high:
            return .systemBlue
        case .complete:
            return .systemGreen
        }
    }

    private func progressMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)

        let label = NSTextField(labelWithString: "完成进度：\(DakaFormatters.percent(progressValue))")
        label.textColor = progressColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        container.addArrangedSubview(label)

        let progress = ProgressBarView()
        progress.value = progressValue
        progress.fillColor = progressColor
        progress.widthAnchor.constraint(equalToConstant: 220).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 10).isActive = true
        container.addArrangedSubview(progress)

        item.view = container
        return item
    }

    private func statusMenuItem() -> NSMenuItem {
        let title = "● 当前状态：\(statusText) - \(statusDetailText)"
        let item = NSMenuItem(
            title: title,
            action: #selector(ignoreStatusMenuItem),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = true
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: statusColor,
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
            ]
        )
        return item
    }

    @objc private func ignoreStatusMenuItem() {}

    @objc private func showConfig() {
        showDashboard(section: .settings)
    }

    @objc private func toggleStatsPaused() {
        statsPaused.toggle()
        UserDefaults.standard.set(statsPaused, forKey: "Daka.statsPaused")
        evaluateAndRender()
    }

    @objc private func showStats() {
        showDashboard(section: .today)
    }

    private func showDashboard(section: DakaDashboardSection) {
        persistCurrentRecord()

        if let statsWindowController {
            statsWindowController.update(
                records: records,
                config: config,
                conditionMatched: lastMatched,
                statsPaused: statsPaused,
                canConfirmClockIn: canConfirmClockIn,
                locationPermissionTitle: locationPermissionTitle,
                locationPermissionNeedsAction: locationPermissionNeedsAction,
                storageError: storageError
            )
            statsWindowController.show(section: section)
            return
        }

        let controller = DashboardWindowController(
            records: records,
            config: config,
            conditionMatched: lastMatched,
            statsPaused: statsPaused,
            canConfirmClockIn: canConfirmClockIn,
            locationPermissionTitle: locationPermissionTitle,
            locationPermissionNeedsAction: locationPermissionNeedsAction,
            storageError: storageError,
            onSaveRecord: { [weak self] updatedRecord in
                self?.saveRecordFromStats(updatedRecord) ?? false
            },
            onSaveConfig: { [weak self] nextConfig in
                self?.saveConfig(nextConfig) ?? false
            },
            onTogglePause: { [weak self] in
                self?.toggleStatsPaused()
            },
            onConfirmClockIn: { [weak self] in
                self?.confirmTodayClockIn()
            },
            onOpenLocationSettings: { [weak self] in
                self?.openLocationSettings()
            },
            onShowStorageError: { [weak self] in
                self?.showStorageError()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
        statsWindowController = controller
        controller.show(section: section)
    }

    @objc private func addLeaveDayFromMenu() {
        persistCurrentRecord()

        guard let dateKey = LeaveDayPicker.run() else {
            return
        }

        markLeaveDay(dateKey)
        statsWindowController?.update(
            records: records,
            config: config,
            conditionMatched: lastMatched,
            statsPaused: statsPaused,
            canConfirmClockIn: canConfirmClockIn,
            locationPermissionTitle: locationPermissionTitle,
            locationPermissionNeedsAction: locationPermissionNeedsAction,
            storageError: storageError
        )
    }

    private func markLeaveDay(_ dateKey: String) {
        let updatedRecord: DailyRecord
        if let recordIndex = records.firstIndex(where: { $0.date == dateKey }) {
            var record = records[recordIndex]
            record.excludedFromStats = true
            updatedRecord = record
        } else {
            updatedRecord = DailyRecord(date: dateKey, excludedFromStats: true)
        }

        guard persist(record: updatedRecord, operation: "保存请假日", presentError: true) else {
            return
        }
        replaceRecordInMemory(updatedRecord)
        currentRecord = records.first { $0.date == recorder.dateKey(for: Date()) }
        renderStatusTitle()
        renderMenu()
    }

    @discardableResult
    private func saveConfig(_ nextConfig: AppConfig) -> Bool {
        guard let store else {
            presentStorageError(operation: "保存配置")
            return false
        }

        do {
            try store.saveConfig(nextConfig)
            storageError = nil
            config = nextConfig
            startTimer()
            requestWiFiPermissionIfNeeded()
            evaluateAndRender()
            return true
        } catch {
            reportStorageError(error, operation: "保存配置", present: true)
            return false
        }
    }

    @discardableResult
    private func saveRecordFromStats(_ updatedRecord: DailyRecord) -> Bool {
        guard persist(record: updatedRecord, operation: "保存统计记录", presentError: true) else {
            return false
        }

        replaceRecordInMemory(updatedRecord)
        currentRecord = records.first { $0.date == recorder.dateKey(for: Date()) }
        renderStatusTitle()
        renderMenu()
        return true
    }

    private func replaceRecordInMemory(_ record: DailyRecord) {
        records.removeAll { $0.date == record.date }
        records.append(record)
        records.sort { $0.date < $1.date }
    }

    private func updateDashboardIfVisible() {
        statsWindowController?.update(
            records: records,
            config: config,
            conditionMatched: lastMatched,
            statsPaused: statsPaused,
            canConfirmClockIn: canConfirmClockIn,
            locationPermissionTitle: locationPermissionTitle,
            locationPermissionNeedsAction: locationPermissionNeedsAction,
            storageError: storageError
        )
    }

    @discardableResult
    private func persist(record: DailyRecord, operation: String, presentError: Bool) -> Bool {
        guard let store else {
            if presentError {
                presentStorageError(operation: operation)
            }
            return false
        }

        do {
            try store.upsertRecord(record)
            storageError = nil
            return true
        } catch {
            reportStorageError(error, operation: operation, present: presentError)
            return false
        }
    }

    private func reportStorageError(_ error: Error, operation: String, present: Bool) {
        storageError = "\(operation)失败：\(error.localizedDescription)"
        NSLog("Daka \(operation) failed: \(error)")
        if statusItem != nil {
            renderMenu()
            updateDashboardIfVisible()
        }
        if present {
            presentStorageError(operation: operation)
        }
    }

    private func presentStorageError(operation: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "\(operation)失败"
        alert.informativeText = storageError ?? "数据存储当前不可用，请检查日志后重试。"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    @objc private func showStorageError() {
        presentStorageError(operation: "数据存储")
    }

    private var requiresWiFiPermission: Bool {
        config.rule.conditions.contains {
            if case .wifiConnected = $0 {
                return true
            }
            return false
        }
    }

    private var usesExternalDisplayCondition: Bool {
        config.rule.conditions.contains {
            if case .externalDisplayConnected = $0 {
                return true
            }
            return false
        }
    }

    private func shouldCloseExternalDisplaySession(wasRecording: Bool, matched: Bool) -> Bool {
        wasRecording
            && !matched
            && !statsPaused
            && usesExternalDisplayCondition
            && currentRecord?.firstMatchedAt != nil
    }

    private var canConfirmClockIn: Bool {
        lastMatched
            && !statsPaused
            && currentRecord?.firstMatchedAt == nil
    }

    private var locationPermissionTitle: String {
        requiresWiFiPermission
            ? locationPermissionRequester.status.title
            : "当前规则不需要"
    }

    private var locationPermissionNeedsAction: Bool {
        requiresWiFiPermission
            && locationPermissionRequester.status.needsUserAction
    }

    private func requestWiFiPermissionIfNeeded() {
        locationPermissionRequester.requestIfNeeded(required: requiresWiFiPermission)
    }

    @objc private func openLocationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func showClockInReminderIfNeeded(at date: Date) {
        guard !isShowingClockInReminder else {
            return
        }

        if let nextClockInReminderAt, date < nextClockInReminderAt {
            return
        }

        isShowingClockInReminder = true
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "今天第一次满足打卡条件"
        alert.informativeText = "请确认你已经完成打卡。确认后才会记录今天的首次时间。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "已打卡")
        alert.addButton(withTitle: "稍后提醒")

        let response = alert.runModal()
        isShowingClockInReminder = false

        if response == .alertFirstButtonReturn {
            recordConfirmedClockIn(at: Date())
        } else {
            nextClockInReminderAt = Date().addingTimeInterval(10 * 60)
        }
    }

    @objc private func confirmTodayClockIn() {
        recordConfirmedClockIn(at: Date())
        renderStatusTitle()
        renderMenu()
        updateDashboardIfVisible()
    }

    private func recordConfirmedClockIn(at date: Date) {
        currentRecord = recorder.update(record: currentRecord, matched: true, at: date)
        nextClockInReminderAt = nil
        persistCurrentRecord()
        showRestDayReminderIfNeeded(at: date)
    }

    private func setupChinaCalendar() {
        let years = requiredChinaCalendarYears(around: Date())
        holidayYears = chinaCalendar.loadCachedYears(years)
        chinaCalendar.refreshYears(years) { [weak self] refreshed in
            DispatchQueue.main.async {
                self?.holidayYears.merge(refreshed) { _, remote in remote }
            }
        }
    }

    private func requiredChinaCalendarYears(around date: Date) -> Set<Int> {
        let calendar = Calendar.current
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: date) ?? date
        return [
            calendar.component(.year, from: date),
            calendar.component(.year, from: nextWeek)
        ]
    }

    private func showRestDayReminderIfNeeded(at date: Date) {
        guard config.restDayReminderEnabled else {
            return
        }

        let todayKey = ChinaWorkdayCalendar.dateFormatter.string(from: date)
        let tomorrowKey = dateKey(daysAfter: 1, from: date)
        let dayAfterTomorrowKey = dateKey(daysAfter: 2, from: date)

        guard isChinaWorkday(todayKey) else {
            return
        }

        let tomorrowIsWorkday = isChinaWorkday(tomorrowKey)
        let dayAfterTomorrowIsWorkday = isChinaWorkday(dayAfterTomorrowKey)
        let reminderKind: RestDayReminderKind?
        let reminderTime: String

        if !tomorrowIsWorkday {
            reminderKind = .lastWorkdayBeforeRest
            reminderTime = config.restDayReminderTime
        } else if !dayAfterTomorrowIsWorkday {
            reminderKind = .dayBeforeLastWorkday
            reminderTime = config.dayBeforeRestReminderTime
        } else {
            reminderKind = nil
            reminderTime = ""
        }

        guard let reminderKind,
              isAtOrAfterReminderTime(reminderTime, at: date),
              !hasShownRestDayReminder(kind: reminderKind, dateKey: todayKey) else {
            return
        }

        let status = WeeklyWorkdaySummarizer.status(
            records: records,
            targetSeconds: config.weeklyTargetSeconds,
            holidayYears: holidayYears,
            calendar: chinaCalendar,
            at: date
        )

        guard !status.isTargetReached else {
            return
        }

        markRestDayReminderShown(kind: reminderKind, dateKey: todayKey)
        showRestDayReminder(kind: reminderKind, status: status)
    }

    private func showRestDayReminder(kind: RestDayReminderKind, status: WeeklyWorkdayStatus) {
        let remainingSeconds = max(0, status.targetSeconds - status.totalSeconds)
        let message: String

        switch kind {
        case .lastWorkdayBeforeRest:
            message = config.restDayReminderMessage
        case .dayBeforeLastWorkday:
            message = config.dayBeforeRestReminderMessage
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "休息日前提醒"
        alert.informativeText = """
        \(message)

        本周已记录：\(DakaFormatters.duration(status.totalSeconds))
        本周平均：\(DakaFormatters.duration(status.averageSeconds)) / 工作日
        周目标：\(DakaFormatters.duration(status.targetSeconds))
        还差：\(DakaFormatters.duration(remainingSeconds))
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func isChinaWorkday(_ dateKey: String) -> Bool {
        guard let year = ChinaWorkdayCalendar.year(from: dateKey) else {
            return false
        }
        return chinaCalendar.isWorkday(dateKey: dateKey, holidayYear: holidayYears[year])
    }

    private func dateKey(daysAfter days: Int, from date: Date) -> String {
        let nextDate = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
        return ChinaWorkdayCalendar.dateFormatter.string(from: nextDate)
    }

    private func isAtOrAfterReminderTime(_ reminderTime: String, at date: Date) -> Bool {
        let parts = reminderTime.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return true
        }

        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let currentMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return currentMinutes >= hour * 60 + minute
    }

    private func hasShownRestDayReminder(kind: RestDayReminderKind, dateKey: String) -> Bool {
        UserDefaults.standard.bool(forKey: restDayReminderDefaultsKey(kind: kind, dateKey: dateKey))
    }

    private func markRestDayReminderShown(kind: RestDayReminderKind, dateKey: String) {
        UserDefaults.standard.set(true, forKey: restDayReminderDefaultsKey(kind: kind, dateKey: dateKey))
    }

    private func restDayReminderDefaultsKey(kind: RestDayReminderKind, dateKey: String) -> String {
        "Daka.restDayReminder.\(kind.rawValue).\(dateKey)"
    }
}

private enum RestDayReminderKind: String {
    case lastWorkdayBeforeRest
    case dayBeforeLastWorkday
}

private enum LocationPermissionStatus {
    case authorized
    case notDetermined
    case denied
    case disabled
    case restricted

    var title: String {
        switch self {
        case .authorized: return "已授权"
        case .notDetermined: return "等待授权"
        case .denied: return "未授权，点击设置"
        case .disabled: return "定位服务已关闭，点击设置"
        case .restricted: return "受系统限制"
        }
    }

    var needsUserAction: Bool {
        switch self {
        case .denied, .disabled:
            return true
        case .authorized, .notDetermined, .restricted:
            return false
        }
    }
}

private final class LocationPermissionRequester: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let onAuthorizationChange: () -> Void

    init(onAuthorizationChange: @escaping () -> Void) {
        self.onAuthorizationChange = onAuthorizationChange
        super.init()
        manager.delegate = self
    }

    var status: LocationPermissionStatus {
        guard CLLocationManager.locationServicesEnabled() else {
            return .disabled
        }

        switch manager.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }

    func requestIfNeeded(required: Bool) {
        guard required else {
            return
        }

        guard CLLocationManager.locationServicesEnabled() else {
            NSLog("Daka location services are disabled; Wi-Fi SSID may be unavailable.")
            return
        }

        switch manager.authorizationStatus {
        case .notDetermined:
            NSLog("Daka requesting location authorization for Wi-Fi SSID access.")
            NSApp.activate(ignoringOtherApps: true)
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            NSLog("Daka location authorization is granted.")
            return
        case .denied, .restricted:
            NSLog("Daka location authorization is denied or restricted; Wi-Fi SSID may be unavailable.")
            return
        @unknown default:
            NSLog("Daka location authorization has an unknown status; Wi-Fi SSID may be unavailable.")
            return
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        NSLog("Daka location authorization changed: \(status.title).")
        onAuthorizationChange()
    }
}
