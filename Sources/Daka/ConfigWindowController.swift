import AppKit
import DakaCore
import Foundation

final class ConfigWindowController: NSWindowController {
    private var config: AppConfig
    private let onSave: (AppConfig) -> Void
    private var drafts: [ConditionDraft]

    private let nameField = NSTextField()
    private let matchModePopup = NSPopUpButton()
    private let intervalField = NSTextField()
    private let targetHoursField = NSTextField()
    private let tableView = NSTableView()
    private let typePopup = NSPopUpButton()
    private let primaryField = NSTextField()
    private let secondaryField = NSTextField()
    private let ssidPopup = NSPopUpButton()
    private let refreshSSIDsButton = NSButton(title: "刷新", target: nil, action: nil)
    private let detailLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private var primaryRow: NSStackView!
    private var secondaryRow: NSStackView!
    private var ssidRow: NSStackView!
    private var ssidOptions: [String] = []
    private var ssidLoadGeneration = 0

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        self.config = config
        self.onSave = onSave
        self.drafts = config.rule.conditions.map(ConditionDraft.init(condition:))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Daka 配置"
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
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        root.addArrangedSubview(formRow(label: "规则名称", view: nameField))

        matchModePopup.addItems(withTitles: ["全部满足", "任一满足"])
        root.addArrangedSubview(formRow(label: "匹配方式", view: matchModePopup))

        intervalField.placeholderString = "60"
        root.addArrangedSubview(formRow(label: "检查间隔(秒)", view: intervalField))

        targetHoursField.placeholderString = "10.5"
        root.addArrangedSubview(formRow(label: "目标时长(小时)", view: targetHoursField))

        let body = NSStackView()
        body.orientation = .horizontal
        body.spacing = 16
        root.addArrangedSubview(body)
        body.heightAnchor.constraint(equalToConstant: 270).isActive = true

        setupTable()
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.widthAnchor.constraint(equalToConstant: 280).isActive = true
        body.addArrangedSubview(scrollView)

        let editor = NSStackView()
        editor.orientation = .vertical
        editor.spacing = 10
        body.addArrangedSubview(editor)

        typePopup.addItems(withTitles: ConditionDraft.Kind.allCases.map(\.title))
        typePopup.target = self
        typePopup.action = #selector(typeChanged)

        editor.addArrangedSubview(formRow(label: "条件类型", view: typePopup))

        ssidPopup.target = self
        ssidPopup.action = #selector(ssidChanged)
        refreshSSIDsButton.target = self
        refreshSSIDsButton.action = #selector(refreshSSIDOptions)
        let ssidControls = NSStackView()
        ssidControls.orientation = .horizontal
        ssidControls.spacing = 8
        ssidControls.addArrangedSubview(ssidPopup)
        ssidControls.addArrangedSubview(refreshSSIDsButton)
        refreshSSIDsButton.widthAnchor.constraint(equalToConstant: 58).isActive = true

        ssidRow = formRow(label: "Wi-Fi", view: ssidControls)
        primaryRow = formRow(label: "参数 1", view: primaryField)
        secondaryRow = formRow(label: "参数 2", view: secondaryField)
        editor.addArrangedSubview(ssidRow)
        editor.addArrangedSubview(primaryRow)
        editor.addArrangedSubview(secondaryRow)

        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 4
        editor.addArrangedSubview(detailLabel)

        let conditionButtons = NSStackView()
        conditionButtons.orientation = .horizontal
        conditionButtons.spacing = 8
        editor.addArrangedSubview(conditionButtons)

        let addButton = NSButton(title: "添加条件", target: self, action: #selector(addCondition))
        let removeButton = NSButton(title: "删除条件", target: self, action: #selector(removeCondition))
        conditionButtons.addArrangedSubview(addButton)
        conditionButtons.addArrangedSubview(removeButton)

        let spacer = NSView()
        editor.addArrangedSubview(spacer)

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

    private func formRow(label: String, view: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10

        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 92).isActive = true
        row.addArrangedSubview(labelView)
        row.addArrangedSubview(view)

        return row
    }

    private func loadConfig() {
        nameField.stringValue = config.rule.name
        matchModePopup.selectItem(at: config.rule.matchMode == .all ? 0 : 1)
        intervalField.stringValue = String(Int(config.evaluationIntervalSeconds))
        targetHoursField.stringValue = DakaFormatters.decimalHours(config.targetDurationSeconds)
        tableView.reloadData()

        if !drafts.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        loadSelectedDraft()
    }

    @objc private func addCondition() {
        saveEditorIntoSelectedDraft()
        drafts.append(ConditionDraft(kind: .screenUnlocked))
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
        let title = ssidPopup.titleOfSelectedItem ?? ""
        return title == "未发现可选 Wi-Fi" || title == "正在加载..." ? "" : title
    }

    private func loadSSIDOptionsAsync(keeping selected: String) {
        ssidLoadGeneration += 1
        let generation = ssidLoadGeneration

        ssidPopup.removeAllItems()
        ssidPopup.addItem(withTitle: "正在加载...")
        ssidPopup.isEnabled = false
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
        ssidOptions = options
        ssidPopup.removeAllItems()
        refreshSSIDsButton.isEnabled = true

        if ssidOptions.isEmpty {
            ssidPopup.addItem(withTitle: "未发现可选 Wi-Fi")
            ssidPopup.isEnabled = false
            return
        }

        ssidPopup.isEnabled = true
        ssidPopup.addItems(withTitles: ssidOptions)
        if !selected.isEmpty, ssidOptions.contains(selected) {
            ssidPopup.selectItem(withTitle: selected)
        } else {
            ssidPopup.selectItem(at: 0)
        }

        saveEditorIntoSelectedDraft()
        tableView.reloadData()
    }

    @objc private func save() {
        saveEditorIntoSelectedDraft()

        let conditions = drafts.compactMap(\.condition)
        guard !conditions.isEmpty else {
            showAlert(message: "至少需要一个条件。")
            return
        }

        let interval = TimeInterval(Int(intervalField.stringValue) ?? 60)
        let targetHours = Double(targetHoursField.stringValue) ?? 10.5
        let ruleName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        let nextConfig = AppConfig(
            rule: TimerRule(
                name: ruleName.isEmpty ? "Default" : ruleName,
                matchMode: matchModePopup.indexOfSelectedItem == 0 ? .all : .any,
                conditions: conditions
            ),
            evaluationIntervalSeconds: max(10, interval),
            targetDurationSeconds: max(0.25, targetHours) * 60 * 60
        )

        onSave(nextConfig)
        close()
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

extension ConfigWindowController: NSTableViewDataSource, NSTableViewDelegate {
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
}

private struct ConditionDraft {
    enum Kind: CaseIterable {
        case screenUnlocked
        case wifiConnected
        case powerConnected
        case networkReachable
        case timeRange

        var title: String {
            switch self {
            case .screenUnlocked: return "屏幕已解锁"
            case .wifiConnected: return "连接 Wi-Fi"
            case .powerConnected: return "插入电源"
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
            case .screenUnlocked, .powerConnected: return nil
            case .wifiConnected: return nil
            case .networkReachable: return "主机名或 IP"
            case .timeRange: return "开始，例如 08:00"
            }
        }

        var secondaryPlaceholder: String? {
            switch self {
            case .screenUnlocked, .wifiConnected, .powerConnected: return nil
            case .networkReachable: return "端口，例如 443"
            case .timeRange: return "结束，例如 20:00"
            }
        }

        var hint: String {
            switch self {
            case .screenUnlocked: return "屏幕未锁定且屏保未运行时满足。"
            case .wifiConnected: return "从当前可见 Wi-Fi 中选择一个 SSID，后续连接到它时满足。"
            case .powerConnected: return "Mac 接入外部电源时满足。"
            case .networkReachable: return "能建立 TCP 连接时满足，适合公司内网探测。"
            case .timeRange: return "当前时间落在范围内时满足，支持跨午夜。"
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
        case .networkReachable:
            guard !primary.isEmpty, let port = Int(secondary), (1...65_535).contains(port) else {
                return nil
            }
            return .networkReachable(host: primary, port: port)
        case .timeRange:
            return primary.isEmpty || secondary.isEmpty ? nil : .timeRange(start: primary, end: secondary)
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
        case .networkReachable:
            return "网络：\(primary.isEmpty ? "未设置" : primary):\(secondary.isEmpty ? "-" : secondary)"
        case .timeRange:
            return "时间：\(primary.isEmpty ? "--:--" : primary) - \(secondary.isEmpty ? "--:--" : secondary)"
        }
    }
}
