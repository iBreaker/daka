import AppKit
import DakaCore
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var config: AppConfig = .default
    private var records: [DailyRecord] = []
    private var currentRecord: DailyRecord?
    private let checker = MacConditionChecker()
    private let recorder = DailyRecorder()
    private var store: DakaStore!
    private var paths: DakaPaths!
    private var lastMatched = false
    private var configWindowController: ConfigWindowController?
    private var statsWindowController: StatsWindowController?
    private var isShowingClockInReminder = false
    private var nextClockInReminderAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStore()
        setupStatusItem()
        setupNotifications()
        evaluateAndRender()
        startTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistCurrentRecord()
    }

    private func setupStore() {
        do {
            paths = try DakaPaths()
            store = try DakaStore(paths: paths)
            config = try store.loadConfig()
            records = try store.loadRecords()
            currentRecord = records.first { $0.date == recorder.dateKey(for: Date()) }
        } catch {
            config = .default
            records = []
            currentRecord = nil
            NSLog("Daka storage setup failed: \(error)")
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

    @objc private func evaluateAndRender() {
        let now = Date()
        let evaluator = RuleEvaluator(checker: checker)
        let matched = evaluator.evaluate(config.rule, at: now)

        currentRecord = recorder.update(record: currentRecord, matched: false, at: now)
        lastMatched = matched

        if matched {
            if currentRecord?.firstMatchedAt == nil {
                showClockInReminderIfNeeded(at: now)
            } else {
                currentRecord = recorder.update(record: currentRecord, matched: true, at: now)
                persistCurrentRecord()
            }
        }

        renderStatusTitle()
        renderMenu()
    }

    private func persistCurrentRecord() {
        guard let currentRecord, store != nil else {
            return
        }

        records.removeAll { $0.date == currentRecord.date }
        records.append(currentRecord)

        do {
            try store.saveRecords(records)
        } catch {
            NSLog("Daka record save failed: \(error)")
        }
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
        menu.addItem(withTitle: "当前状态：\(lastMatched ? "满足条件" : "未满足条件")", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "规则：\(config.rule.name)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        if lastMatched && currentRecord?.firstMatchedAt == nil {
            let confirmItem = NSMenuItem(title: "确认今日已打卡", action: #selector(confirmTodayClockIn), keyEquivalent: "d")
            confirmItem.target = self
            menu.addItem(confirmItem)
            menu.addItem(.separator())
        }

        let configItem = NSMenuItem(title: "配置...", action: #selector(showConfig), keyEquivalent: ",")
        configItem.target = self
        menu.addItem(configItem)

        let recordsItem = NSMenuItem(title: "统计...", action: #selector(showStats), keyEquivalent: "r")
        recordsItem.target = self
        menu.addItem(recordsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
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

    @objc private func showConfig() {
        if let configWindowController {
            configWindowController.update(config: config)
            configWindowController.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = ConfigWindowController(config: config) { [weak self] nextConfig in
            self?.saveConfig(nextConfig)
        }
        configWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showStats() {
        persistCurrentRecord()

        if let statsWindowController {
            statsWindowController.update(records: records, targetDurationSeconds: config.targetDurationSeconds)
            statsWindowController.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = StatsWindowController(
            records: records,
            targetDurationSeconds: config.targetDurationSeconds
        ) { [weak self] updatedRecords in
            self?.saveRecordsFromStats(updatedRecords)
        }
        statsWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func saveConfig(_ nextConfig: AppConfig) {
        do {
            try store.saveConfig(nextConfig)
            config = nextConfig
            startTimer()
            evaluateAndRender()
        } catch {
            NSLog("Daka config save failed: \(error)")
        }
    }

    private func saveRecordsFromStats(_ updatedRecords: [DailyRecord]) {
        records = updatedRecords
        currentRecord = records.first { $0.date == recorder.dateKey(for: Date()) }

        do {
            try store.saveRecords(records)
            renderStatusTitle()
            renderMenu()
        } catch {
            NSLog("Daka records save failed: \(error)")
        }
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
    }

    private func recordConfirmedClockIn(at date: Date) {
        currentRecord = recorder.update(record: currentRecord, matched: true, at: date)
        nextClockInReminderAt = nil
        persistCurrentRecord()
    }
}
