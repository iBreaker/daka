import AppKit
import DakaCore
import Foundation

final class ConfigWindowController: NSWindowController {
    private var config: AppConfig
    private let onSave: (AppConfig) -> Bool
    private var drafts: [ConditionDraft]

    private let matchModePopup = NSPopUpButton()
    private let intervalField = NSTextField()
    private let targetHoursField = NSTextField()
    private let monthlyAverageTargetHoursField = NSTextField()
    private let restDayReminderEnabledButton = NSButton(checkboxWithTitle: "开启休息日前提醒", target: nil, action: nil)
    private let weeklyTargetHoursField = NSTextField()
    private let restDayReminderTimeField = NSTextField()
    private let dayBeforeRestReminderTimeField = NSTextField()
    private let restDayReminderMessageField = NSTextField()
    private let dayBeforeRestReminderMessageField = NSTextField()
    private let tableView = NSTableView()
    private let typePopup = NSPopUpButton()
    private let primaryField = NSTextField()
    private let secondaryField = NSTextField()
    private let ssidComboBox = NSComboBox()
    private let refreshSSIDsButton = NSButton(title: "刷新", target: nil, action: nil)
    private let detailLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private var primaryRow: NSStackView!
    private var secondaryRow: NSStackView!
    private var ssidRow: NSStackView!
    private var ssidOptions: [String] = []
    private var ssidLoadGeneration = 0
    private var isUpdatingSSIDOptions = false

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Bool) {
        self.config = config
        self.onSave = onSave
        self.drafts = config.rule.conditions.map(ConditionDraft.init(condition:))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Daka 配置"
        window.minSize = NSSize(width: 680, height: 460)
        window.center()

        super.init(window: window)
        setupUI()
        loadConfig()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(config: AppConfig) {
        self.config = config
        self.drafts = config.rule.conditions.map(ConditionDraft.init(condition:))
        loadConfig()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else {
            return
        }

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let tabView = NSTabView()
        root.addArrangedSubview(tabView)

        matchModePopup.addItems(withTitles: ["全部满足", "任一满足"])

        let targetTab = tabContent(in: tabView, title: "目标")

        targetHoursField.placeholderString = "10.5"
        targetTab.addArrangedSubview(formRow(label: "目标时长(小时)", view: targetHoursField, width: 120))

        monthlyAverageTargetHoursField.placeholderString = "10.5"
        targetTab.addArrangedSubview(formRow(label: "月均达标(小时)", view: monthlyAverageTargetHoursField, width: 120))

        weeklyTargetHoursField.placeholderString = "47.5"
        targetTab.addArrangedSubview(formRow(label: "周目标(小时)", view: weeklyTargetHoursField, width: 120))
        targetTab.addArrangedSubview(NSView())

        let conditionTab = tabContent(in: tabView, title: "条件")
        intervalField.placeholderString = "60"
        conditionTab.addArrangedSubview(formRow(label: "检查间隔(秒)", view: intervalField, width: 120))
        conditionTab.addArrangedSubview(formRow(label: "匹配方式", view: matchModePopup, width: 110))

        let body = NSStackView()
        body.orientation = .horizontal
        body.spacing = 16
        conditionTab.addArrangedSubview(body)
        body.heightAnchor.constraint(equalToConstant: 300).isActive = true

        setupTable()
        let listColumn = NSStackView()
        listColumn.orientation = .vertical
        listColumn.spacing = 8
        body.addArrangedSubview(listColumn)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.widthAnchor.constraint(equalToConstant: 280).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: 260).isActive = true
        listColumn.addArrangedSubview(scrollView)

        let conditionButtons = NSStackView()
        conditionButtons.orientation = .horizontal
        conditionButtons.spacing = 8
        listColumn.addArrangedSubview(conditionButtons)

        let addButton = NSButton(title: "添加条件", target: self, action: #selector(addCondition))
        let removeButton = NSButton(title: "删除条件", target: self, action: #selector(removeCondition))
        conditionButtons.addArrangedSubview(addButton)
        conditionButtons.addArrangedSubview(removeButton)
        conditionButtons.addArrangedSubview(NSView())

        let editor = NSStackView()
        editor.orientation = .vertical
        editor.spacing = 10
        body.addArrangedSubview(editor)
        editor.widthAnchor.constraint(equalToConstant: 380).isActive = true

        typePopup.addItems(withTitles: ConditionDraft.Kind.allCases.map(\.title))
        typePopup.target = self
        typePopup.action = #selector(typeChanged)

        editor.addArrangedSubview(formRow(label: "条件类型", view: typePopup, width: 150))

        ssidComboBox.delegate = self
        ssidComboBox.completes = true
        ssidComboBox.numberOfVisibleItems = 8
        ssidComboBox.hasVerticalScroller = true
        ssidComboBox.target = self
        ssidComboBox.action = #selector(ssidChanged)
        refreshSSIDsButton.target = self
        refreshSSIDsButton.action = #selector(refreshSSIDOptions)
        let ssidControls = NSStackView()
        ssidControls.orientation = .horizontal
        ssidControls.spacing = 8
        ssidControls.addArrangedSubview(ssidComboBox)
        ssidControls.addArrangedSubview(refreshSSIDsButton)
        ssidComboBox.widthAnchor.constraint(equalToConstant: 250).isActive = true
        refreshSSIDsButton.widthAnchor.constraint(equalToConstant: 58).isActive = true

        ssidRow = formRow(label: "Wi-Fi", view: ssidControls, fills: true)
        primaryRow = formRow(label: "参数 1", view: primaryField, fills: true)
        secondaryRow = formRow(label: "参数 2", view: secondaryField, fills: true)
        editor.addArrangedSubview(ssidRow)
        editor.addArrangedSubview(primaryRow)
        editor.addArrangedSubview(secondaryRow)

        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 4
        editor.addArrangedSubview(formRow(label: "", view: detailLabel, fills: true))

        let spacer = NSView()
        editor.addArrangedSubview(spacer)

        let reminderTab = tabContent(in: tabView, title: "提醒")
        reminderTab.addArrangedSubview(formRow(label: "提醒开关", view: restDayReminderEnabledButton))

        restDayReminderTimeField.placeholderString = AppConfig.defaultRestDayReminderTime
        reminderTab.addArrangedSubview(formRow(label: "休息前时间", view: restDayReminderTimeField, width: 120))

        dayBeforeRestReminderTimeField.placeholderString = AppConfig.defaultDayBeforeRestReminderTime
        reminderTab.addArrangedSubview(formRow(label: "前一天时间", view: dayBeforeRestReminderTimeField, width: 120))

        restDayReminderMessageField.placeholderString = AppConfig.defaultRestDayReminderMessage
        reminderTab.addArrangedSubview(formRow(label: "休息前文案", view: restDayReminderMessageField, fills: true))

        dayBeforeRestReminderMessageField.placeholderString = AppConfig.defaultDayBeforeRestReminderMessage
        reminderTab.addArrangedSubview(formRow(label: "前一天文案", view: dayBeforeRestReminderMessageField, fills: true))
        reminderTab.addArrangedSubview(NSView())

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 10
        root.addArrangedSubview(footer)

        let footerSpacer = NSView()
        footer.addArrangedSubview(footerSpacer)

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        footer.addArrangedSubview(cancelButton)
        footer.addArrangedSubview(saveButton)

        primaryField.target = self
        primaryField.action = #selector(editorFieldChanged)
        secondaryField.target = self
        secondaryField.action = #selector(editorFieldChanged)
    }

    private func setupTable() {
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsEmptySelection = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("condition"))
        column.width = 260
        tableView.addTableColumn(column)
        tableView.target = self
        tableView.action = #selector(selectionChanged)
    }

    private func tabContent(in tabView: NSTabView, title: String) -> NSStackView {
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 12
        container.edgeInsets = NSEdgeInsets(top: 16, left: 12, bottom: 12, right: 12)

        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = container
        tabView.addTabViewItem(item)

        return container
    }

    private func formRow(label: String, view: NSView, fills: Bool = false, width: CGFloat? = nil) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10

        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.textColor = label.isEmpty ? .clear : .labelColor
        labelView.widthAnchor.constraint(equalToConstant: 110).isActive = true
        row.addArrangedSubview(labelView)
        row.addArrangedSubview(view)

        if let width {
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        }

        if !fills {
            row.addArrangedSubview(NSView())
        }

        return row
    }

    private func loadConfig() {
        matchModePopup.selectItem(at: config.rule.matchMode == .all ? 0 : 1)
        intervalField.stringValue = String(Int(config.evaluationIntervalSeconds))
        targetHoursField.stringValue = DakaFormatters.decimalHours(config.targetDurationSeconds)
        monthlyAverageTargetHoursField.stringValue = DakaFormatters.decimalHours(config.monthlyAverageTargetSeconds)
        weeklyTargetHoursField.stringValue = DakaFormatters.decimalHours(config.weeklyTargetSeconds)
        restDayReminderEnabledButton.state = config.restDayReminderEnabled ? .on : .off
        restDayReminderTimeField.stringValue = config.restDayReminderTime
        dayBeforeRestReminderTimeField.stringValue = config.dayBeforeRestReminderTime
        restDayReminderMessageField.stringValue = config.restDayReminderMessage
        dayBeforeRestReminderMessageField.stringValue = config.dayBeforeRestReminderMessage
        tableView.reloadData()

        if !drafts.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        loadSelectedDraft()
    }

    @objc private func addCondition() {
        saveEditorIntoSelectedDraft()
        let kind = ConditionDraft.Kind.allCases.first { !isDuplicateSingleton(kind: $0, ignoring: nil) } ?? .wifiConnected
        drafts.append(ConditionDraft(kind: kind))
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: drafts.count - 1), byExtendingSelection: false)
        loadSelectedDraft()
    }

    @objc private func removeCondition() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < drafts.count else {
            return
        }

        drafts.remove(at: tableView.selectedRow)
        tableView.reloadData()

        if !drafts.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: min(tableView.selectedRow, drafts.count - 1)), byExtendingSelection: false)
        }
        loadSelectedDraft()
    }

    @objc private func selectionChanged() {
        loadSelectedDraft()
    }

    @objc private func typeChanged() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < drafts.count,
              let kind = ConditionDraft.Kind(title: typePopup.titleOfSelectedItem ?? "") else {
            return
        }

        if isDuplicateSingleton(kind: kind, ignoring: tableView.selectedRow) {
            showAlert(message: "\(kind.title) 已经存在，不能重复添加。")
            loadSelectedDraft()
            return
        }

        drafts[tableView.selectedRow] = ConditionDraft(kind: kind)
        tableView.reloadData()
        loadSelectedDraft()
    }

    @objc private func editorFieldChanged() {
        saveEditorIntoSelectedDraft()
        tableView.reloadData()
    }

    private func loadSelectedDraft() {
        let selected = tableView.selectedRow
        let hasSelection = selected >= 0 && selected < drafts.count
        typePopup.isEnabled = hasSelection
        primaryField.isEnabled = hasSelection
        secondaryField.isEnabled = hasSelection

        guard hasSelection else {
            typePopup.selectItem(at: 0)
            primaryField.stringValue = ""
            secondaryField.stringValue = ""
            detailLabel.stringValue = "添加至少一个条件后保存。"
            return
        }

        let draft = drafts[selected]
        typePopup.selectItem(withTitle: draft.kind.title)
        if draft.kind == .wifiConnected {
            ssidComboBox.stringValue = draft.primary
            loadSSIDOptionsAsync(keeping: draft.primary)
        }
        primaryField.stringValue = draft.primary
        secondaryField.stringValue = draft.secondary
        primaryField.placeholderString = draft.kind.primaryPlaceholder
        secondaryField.placeholderString = draft.kind.secondaryPlaceholder
        ssidRow.isHidden = draft.kind != .wifiConnected
        primaryRow.isHidden = draft.kind == .wifiConnected || draft.kind.primaryPlaceholder == nil
        secondaryRow.isHidden = draft.kind.secondaryPlaceholder == nil
        detailLabel.stringValue = draft.kind.hint
    }

    private func saveEditorIntoSelectedDraft() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < drafts.count else {
            return
        }

        if drafts[tableView.selectedRow].kind == .wifiConnected {
            drafts[tableView.selectedRow].primary = selectedSSID()
        } else {
            drafts[tableView.selectedRow].primary = primaryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        drafts[tableView.selectedRow].secondary = secondaryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func ssidChanged() {
        saveEditorIntoSelectedDraft()
        tableView.reloadData()
    }

    @objc private func refreshSSIDOptions() {
        let current = selectedSSID()
        loadSSIDOptionsAsync(keeping: current)
        saveEditorIntoSelectedDraft()
        tableView.reloadData()
    }

    private func selectedSSID() -> String {
        let value = ssidComboBox.stringValue
        return value == "正在加载..." ? "" : value
    }

    private func loadSSIDOptionsAsync(keeping selected: String) {
        ssidLoadGeneration += 1
        let generation = ssidLoadGeneration

        ssidComboBox.placeholderString = "正在加载..."
        ssidComboBox.isEnabled = true
        refreshSSIDsButton.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let options = WiFiSSIDProvider.availableSSIDs(keeping: selected)

            DispatchQueue.main.async {
                guard let self, self.ssidLoadGeneration == generation else {
                    return
                }

                self.applySSIDOptions(options, keeping: selected)
            }
        }
    }

    private func applySSIDOptions(_ options: [String], keeping selected: String) {
        let textBeforeReload = ssidComboBox.stringValue
        isUpdatingSSIDOptions = true
        defer {
            ssidComboBox.stringValue = textBeforeReload
            isUpdatingSSIDOptions = false
        }

        ssidOptions = options
        ssidComboBox.removeAllItems()
        refreshSSIDsButton.isEnabled = true
        ssidComboBox.isEnabled = true
        ssidComboBox.placeholderString = ssidOptions.isEmpty ? "未发现可选 Wi-Fi，可手动输入" : "选择或输入 Wi-Fi 名称"
        ssidComboBox.addItems(withObjectValues: ssidOptions)
    }

    @objc private func save() {
        saveEditorIntoSelectedDraft()

        if let duplicate = duplicateSingletonKind() {
            showAlert(message: "\(duplicate.title) 已经存在，不能重复添加。")
            return
        }

        if let invalid = drafts.first(where: { $0.condition == nil }) {
            showAlert(message: "\(invalid.kind.title) 条件还没填完整。")
            return
        }

        let conditions = drafts.compactMap(\.condition)
        guard !conditions.isEmpty else {
            showAlert(message: "至少需要一个条件。")
            return
        }

        guard let interval = DakaInputValidator.evaluationInterval(intervalField.stringValue) else {
            showAlert(message: "检查间隔必须是 10 到 86400 之间的整数秒。")
            return
        }
        guard let targetHours = DakaInputValidator.positiveNumber(targetHoursField.stringValue, range: 0.25...24) else {
            showAlert(message: "目标时长必须是 0.25 到 24 之间的小时数。")
            return
        }
        guard let monthlyAverageTargetHours = DakaInputValidator.positiveNumber(
            monthlyAverageTargetHoursField.stringValue,
            range: 0.25...24
        ) else {
            showAlert(message: "月均目标必须是 0.25 到 24 之间的小时数。")
            return
        }
        guard let weeklyTargetHours = DakaInputValidator.positiveNumber(
            weeklyTargetHoursField.stringValue,
            range: 0.25...168
        ) else {
            showAlert(message: "周目标必须是 0.25 到 168 之间的小时数。")
            return
        }
        guard let restDayReminderTime = DakaInputValidator.normalizedTime(restDayReminderTimeField.stringValue) else {
            showAlert(message: "休息前提醒时间格式应为 HH:mm，例如 09:30。")
            return
        }
        guard let dayBeforeRestReminderTime = DakaInputValidator.normalizedTime(dayBeforeRestReminderTimeField.stringValue) else {
            showAlert(message: "前一天提醒时间格式应为 HH:mm，例如 18:00。")
            return
        }
        let restDayReminderMessage = restDayReminderMessageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let dayBeforeRestReminderMessage = dayBeforeRestReminderMessageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        let nextConfig = AppConfig(
            rule: TimerRule(
                name: config.rule.name.isEmpty ? "Default" : config.rule.name,
                matchMode: matchModePopup.indexOfSelectedItem == 0 ? .all : .any,
                conditions: conditions
            ),
            evaluationIntervalSeconds: interval,
            targetDurationSeconds: targetHours * 60 * 60,
            monthlyAverageTargetSeconds: monthlyAverageTargetHours * 60 * 60,
            restDayReminderEnabled: restDayReminderEnabledButton.state == .on,
            weeklyTargetSeconds: weeklyTargetHours * 60 * 60,
            restDayReminderTime: restDayReminderTime,
            dayBeforeRestReminderTime: dayBeforeRestReminderTime,
            restDayReminderMessage: restDayReminderMessage.isEmpty ? AppConfig.defaultRestDayReminderMessage : restDayReminderMessage,
            dayBeforeRestReminderMessage: dayBeforeRestReminderMessage.isEmpty ? AppConfig.defaultDayBeforeRestReminderMessage : dayBeforeRestReminderMessage
        )

        if onSave(nextConfig) {
            close()
        }
    }

    private func isDuplicateSingleton(kind: ConditionDraft.Kind, ignoring index: Int?) -> Bool {
        guard kind.isSingleton else {
            return false
        }

        return drafts.enumerated().contains { offset, draft in
            offset != index && draft.kind == kind
        }
    }

    private func duplicateSingletonKind() -> ConditionDraft.Kind? {
        var seen = Set<ConditionDraft.Kind>()
        for draft in drafts where draft.kind.isSingleton {
            if seen.contains(draft.kind) {
                return draft.kind
            }
            seen.insert(draft.kind)
        }
        return nil
    }

    @objc private func cancel() {
        close()
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

}

extension ConfigWindowController: NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        drafts.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("conditionCell")
        let field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.stringValue = drafts[row].summary
        return field
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSSIDOptions else {
            return
        }

        saveEditorIntoSelectedDraft()
        tableView.reloadData()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isUpdatingSSIDOptions else {
            return
        }

        guard notification.object as? NSComboBox === ssidComboBox else {
            return
        }

        saveEditorIntoSelectedDraft()
        tableView.reloadData()
    }
}

private struct ConditionDraft {
    enum Kind: CaseIterable, Hashable {
        case screenUnlocked
        case wifiConnected
        case powerConnected
        case externalDisplayConnected
        case networkReachable
        case timeRange

        var title: String {
            switch self {
            case .screenUnlocked: return "屏幕已解锁"
            case .wifiConnected: return "连接 Wi-Fi"
            case .powerConnected: return "插入电源"
            case .externalDisplayConnected: return "连接外接显示屏"
            case .networkReachable: return "网络可达"
            case .timeRange: return "时间范围"
            }
        }

        init?(title: String) {
            guard let kind = Self.allCases.first(where: { $0.title == title }) else {
                return nil
            }
            self = kind
        }

        var primaryPlaceholder: String? {
            switch self {
            case .screenUnlocked, .powerConnected, .externalDisplayConnected: return nil
            case .wifiConnected: return nil
            case .networkReachable: return "主机名或 IP"
            case .timeRange: return "开始，例如 08:00"
            }
        }

        var secondaryPlaceholder: String? {
            switch self {
            case .screenUnlocked, .wifiConnected, .powerConnected, .externalDisplayConnected: return nil
            case .networkReachable: return "端口，例如 443"
            case .timeRange: return "结束，例如 20:00"
            }
        }

        var hint: String {
            switch self {
            case .screenUnlocked: return "屏幕未锁定且屏保未运行时满足。"
            case .wifiConnected: return "从当前可见 Wi-Fi 中选择一个 SSID，后续连接到它时满足。"
            case .powerConnected: return "Mac 接入外部电源时满足。"
            case .externalDisplayConnected: return "检测到任意非内建显示屏在线时满足；当天最早连接作为上班，最后断开前的最后一次满足作为下班。"
            case .networkReachable: return "能建立 TCP 连接时满足，适合公司内网探测。"
            case .timeRange: return "当前时间落在范围内时满足，支持跨午夜。"
            }
        }

        var isSingleton: Bool {
            switch self {
            case .screenUnlocked, .powerConnected, .externalDisplayConnected:
                return true
            case .wifiConnected, .networkReachable, .timeRange:
                return false
            }
        }
    }

    var kind: Kind
    var primary: String = ""
    var secondary: String = ""

    init(kind: Kind) {
        self.kind = kind
    }

    init(condition: TimerCondition) {
        switch condition {
        case .screenUnlocked:
            self.kind = .screenUnlocked
        case let .wifiConnected(ssid):
            self.kind = .wifiConnected
            self.primary = ssid
        case .powerConnected:
            self.kind = .powerConnected
        case .externalDisplayConnected:
            self.kind = .externalDisplayConnected
        case let .networkReachable(host, port):
            self.kind = .networkReachable
            self.primary = host
            self.secondary = String(port)
        case let .timeRange(start, end):
            self.kind = .timeRange
            self.primary = start
            self.secondary = end
        }
    }

    var condition: TimerCondition? {
        switch kind {
        case .screenUnlocked:
            return .screenUnlocked
        case .wifiConnected:
            return primary.isEmpty ? nil : .wifiConnected(ssid: primary)
        case .powerConnected:
            return .powerConnected
        case .externalDisplayConnected:
            return .externalDisplayConnected
        case .networkReachable:
            guard !primary.isEmpty, let port = Int(secondary), (1...65_535).contains(port) else {
                return nil
            }
            return .networkReachable(host: primary, port: port)
        case .timeRange:
            guard let start = DakaInputValidator.normalizedTime(primary),
                  let end = DakaInputValidator.normalizedTime(secondary) else {
                return nil
            }
            return .timeRange(start: start, end: end)
        }
    }

    var summary: String {
        switch kind {
        case .screenUnlocked:
            return "屏幕已解锁"
        case .wifiConnected:
            return "Wi-Fi：\(primary.isEmpty ? "未设置" : primary)"
        case .powerConnected:
            return "插入电源"
        case .externalDisplayConnected:
            return "连接外接显示屏"
        case .networkReachable:
            return "网络：\(primary.isEmpty ? "未设置" : primary):\(secondary.isEmpty ? "-" : secondary)"
        case .timeRange:
            return "时间：\(primary.isEmpty ? "--:--" : primary) - \(secondary.isEmpty ? "--:--" : secondary)"
        }
    }
}
