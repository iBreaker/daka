import AppKit
import DakaCore
import Foundation

final class StatsWindowController: NSWindowController {
    private var records: [DailyRecord]
    private var targetDurationSeconds: TimeInterval
    private let onSave: ([DailyRecord]) -> Void
    private let tableView = NSTableView()
    private let tabControl = NSSegmentedControl(labels: ["表格", "趋势", "热力图"], trackingMode: .selectOne, target: nil, action: nil)
    private let contentContainer = NSView()
    private let tableContainer = NSView()
    private let trendChartView = TrendChartView()
    private let heatmapView = HeatmapView()
    private let summary = NSTextField(labelWithString: "")
    private let editButton = NSButton(title: "编辑时间", target: nil, action: nil)

    init(records: [DailyRecord], targetDurationSeconds: TimeInterval, onSave: @escaping ([DailyRecord]) -> Void) {
        self.records = records.sorted { $0.date > $1.date }
        self.targetDurationSeconds = targetDurationSeconds
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Daka 统计"
        window.center()

        super.init(window: window)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(records: [DailyRecord], targetDurationSeconds: TimeInterval) {
        self.records = records.sorted { $0.date > $1.date }
        self.targetDurationSeconds = targetDurationSeconds
        summary.stringValue = summaryText
        refreshCharts()
        tableView.reloadData()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else {
            return
        }

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        summary.font = .systemFont(ofSize: 13, weight: .medium)
        summary.stringValue = summaryText
        root.addArrangedSubview(summary)

        tabControl.selectedSegment = 0
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        root.addArrangedSubview(tabControl)

        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.target = self
        tableView.doubleAction = #selector(editSelectedRecord)

        addColumn(id: "date", title: "日期", width: 120)
        addColumn(id: "first", title: "首次", width: 120)
        addColumn(id: "last", title: "最后", width: 120)
        addColumn(id: "span", title: "跨度", width: 100)
        addColumn(id: "progress", title: "完成率", width: 90)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(contentContainer)
        contentContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        setupTableContainer()
        setupChartContainers()
        showPanel(tableContainer)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 10
        root.addArrangedSubview(footer)

        let spacer = NSView()
        footer.addArrangedSubview(spacer)

        editButton.target = self
        editButton.action = #selector(editSelectedRecord)
        editButton.isEnabled = false
        footer.addArrangedSubview(editButton)
    }

    private func setupTableContainer() {
        tableContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(tableContainer)
        pin(tableContainer, to: contentContainer)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        tableContainer.addSubview(scrollView)
        pin(scrollView, to: tableContainer)
    }

    private func setupChartContainers() {
        trendChartView.records = records
        trendChartView.targetDurationSeconds = targetDurationSeconds
        heatmapView.records = records
        heatmapView.targetDurationSeconds = targetDurationSeconds

        for view in [trendChartView, heatmapView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(view)
            pin(view, to: contentContainer)
            view.isHidden = true
        }
    }

    private var summaryText: String {
        let completed = records.filter { $0.firstMatchedAt != nil && $0.lastMatchedAt != nil }
        return "共 \(records.count) 天记录，\(completed.count) 天有有效时间，目标 \(DakaFormatters.duration(targetDurationSeconds))"
    }

    private func addColumn(id: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        tableView.addTableColumn(column)
    }

    @objc private func editSelectedRecord() {
        let row = tableView.selectedRow
        guard row >= 0, row < records.count else {
            return
        }

        let original = records[row]
        guard let updated = RecordEditor.run(record: original) else {
            return
        }

        records[row] = updated
        records.sort { $0.date > $1.date }
        tableView.reloadData()
        summary.stringValue = summaryText
        refreshCharts()
        onSave(records)
    }

    @objc private func tabChanged() {
        switch tabControl.selectedSegment {
        case 1:
            showPanel(trendChartView)
            editButton.isEnabled = false
        case 2:
            showPanel(heatmapView)
            editButton.isEnabled = false
        default:
            showPanel(tableContainer)
            editButton.isEnabled = tableView.selectedRow >= 0
        }
    }

    private func showPanel(_ selected: NSView) {
        for view in [tableContainer, trendChartView, heatmapView] {
            view.isHidden = view !== selected
        }
    }

    private func refreshCharts() {
        trendChartView.records = records
        trendChartView.targetDurationSeconds = targetDurationSeconds
        heatmapView.records = records
        heatmapView.targetDurationSeconds = targetDurationSeconds
    }

    private func pin(_ child: NSView, to parent: NSView) {
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }
}

extension StatsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        records.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else {
            return nil
        }

        let record = records[row]
        let identifier = NSUserInterfaceItemIdentifier("statsCell")
        let field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.textColor = .labelColor

        switch tableColumn.identifier.rawValue {
        case "date":
            field.stringValue = record.date
        case "first":
            field.stringValue = DakaFormatters.shortTime(record.firstMatchedAt)
        case "last":
            field.stringValue = DakaFormatters.shortTime(record.lastMatchedAt)
        case "span":
            field.stringValue = DakaFormatters.duration(record.spanSeconds)
        case "progress":
            field.stringValue = DakaFormatters.percent(progress(for: record))
            field.textColor = color(for: record)
        default:
            field.stringValue = ""
        }

        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        editButton.isEnabled = tableView.selectedRow >= 0
    }

    private func progress(for record: DailyRecord) -> Double {
        guard let spanSeconds = record.spanSeconds, targetDurationSeconds > 0 else {
            return 0
        }

        return min(1, max(0, spanSeconds / targetDurationSeconds))
    }

    private func color(for record: DailyRecord) -> NSColor {
        switch ProgressStage.stage(spanSeconds: record.spanSeconds, targetSeconds: targetDurationSeconds) {
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
}

private enum RecordEditor {
    static func run(record: DailyRecord) -> DailyRecord? {
        let firstPicker = picker(date: record.firstMatchedAt ?? fallbackDate(record: record, hour: 9))
        let lastPicker = picker(date: record.lastMatchedAt ?? Date())

        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 12
        container.frame = NSRect(x: 0, y: 0, width: 300, height: 92)

        container.addArrangedSubview(row(label: "首次", view: firstPicker))
        container.addArrangedSubview(row(label: "最后", view: lastPicker))

        let alert = NSAlert()
        alert.messageText = "编辑 \(record.date)"
        alert.informativeText = "用于修正当天统计时间。"
        alert.accessoryView = container
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()

        guard response == .alertFirstButtonReturn else {
            return nil
        }

        var updated = record
        updated.firstMatchedAt = firstPicker.dateValue
        updated.lastMatchedAt = max(firstPicker.dateValue, lastPicker.dateValue)
        return updated
    }

    private static func picker(date: Date) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.dateValue = date
        picker.widthAnchor.constraint(equalToConstant: 210).isActive = true
        return picker
    }

    private static func row(label: String, view: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10

        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 54).isActive = true

        row.addArrangedSubview(labelView)
        row.addArrangedSubview(view)
        return row
    }

    private static func fallbackDate(record: DailyRecord, hour: Int) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(record.date) \(String(format: "%02d", hour)):00") ?? Date()
    }
}
