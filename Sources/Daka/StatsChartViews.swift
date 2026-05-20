import AppKit
import DakaCore
import Foundation

final class TrendChartView: NSView {
    var records: [DailyRecord] = [] {
        didSet { needsDisplay = true }
    }

    var targetDurationSeconds: TimeInterval = 10.5 * 60 * 60 {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 560, height: 280)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 36, dy: 30)
        guard rect.width > 80, rect.height > 80 else {
            return
        }

        drawAxes(in: rect)

        let sorted = records
            .filter { $0.spanSeconds != nil }
            .sorted { $0.date < $1.date }
            .suffix(45)

        guard sorted.count >= 1 else {
            drawEmptyMessage("暂无趋势数据")
            return
        }

        let maxSpan = sorted.compactMap(\.spanSeconds).max() ?? 0
        let maxValue = max(targetDurationSeconds, maxSpan, 1)
        drawTargetLine(in: rect, maxValue: maxValue)

        let points = sorted.enumerated().map { index, record -> NSPoint in
            let x: CGFloat
            if sorted.count == 1 {
                x = rect.midX
            } else {
                x = rect.minX + CGFloat(index) / CGFloat(sorted.count - 1) * rect.width
            }

            let y = rect.minY + CGFloat((record.spanSeconds ?? 0) / maxValue) * rect.height
            return NSPoint(x: x, y: y)
        }

        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }

        NSColor.systemBlue.setStroke()
        path.lineWidth = 2
        path.stroke()

        for point in points {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
            NSColor.systemBlue.setStroke()
            NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).stroke()
        }

        drawLabels(in: rect, maxValue: maxValue)
    }

    private func drawAxes(in rect: NSRect) {
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.lineWidth = 1
        path.stroke()
    }

    private func drawTargetLine(in rect: NSRect, maxValue: TimeInterval) {
        let y = rect.minY + CGFloat(targetDurationSeconds / maxValue) * rect.height
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: y))
        path.line(to: NSPoint(x: rect.maxX, y: y))
        path.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.systemGreen.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func drawLabels(in rect: NSRect, maxValue: TimeInterval) {
        drawText(DakaFormatters.duration(maxValue), at: NSPoint(x: 4, y: rect.maxY - 8), color: .secondaryLabelColor)
        drawText("目标 \(DakaFormatters.duration(targetDurationSeconds))", at: NSPoint(x: rect.maxX - 108, y: rect.maxY + 8), color: .systemGreen)
    }

    private func drawText(_ text: String, at point: NSPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: color
        ]
        text.draw(at: point, withAttributes: attributes)
    }

    private func drawEmptyMessage(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

final class HeatmapView: NSView {
    var records: [DailyRecord] = [] {
        didSet { needsDisplay = true }
    }

    var targetDurationSeconds: TimeInterval = 10.5 * 60 * 60 {
        didSet { needsDisplay = true }
    }

    private let cellSize: CGFloat = 14
    private let gap: CGFloat = 4

    override var intrinsicContentSize: NSSize {
        NSSize(width: 560, height: 220)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let sorted = records.sorted { $0.date < $1.date }
        guard !sorted.isEmpty else {
            drawEmptyMessage("暂无热力图数据")
            return
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let calendar = Calendar.current
        let datedRecords = sorted.compactMap { record -> (Date, DailyRecord)? in
            guard let date = dateFormatter.date(from: record.date) else {
                return nil
            }
            return (date, record)
        }

        guard let firstDate = datedRecords.first?.0 else {
            drawEmptyMessage("暂无热力图数据")
            return
        }

        let startWeekday = calendar.component(.weekday, from: firstDate) - 1
        let originX: CGFloat = 24
        let originY = bounds.maxY - 28

        for (date, record) in datedRecords {
            let dayOffset = calendar.dateComponents([.day], from: firstDate, to: date).day ?? 0
            let index = dayOffset + startWeekday
            let column = index / 7
            let row = index % 7
            let x = originX + CGFloat(column) * (cellSize + gap)
            let y = originY - CGFloat(row + 1) * (cellSize + gap)
            let rect = NSRect(x: x, y: y, width: cellSize, height: cellSize)

            color(for: record).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }

        drawWeekdayLabels(originX: originX, originY: originY)
        drawLegend()
    }

    private func color(for record: DailyRecord) -> NSColor {
        guard let spanSeconds = record.spanSeconds, targetDurationSeconds > 0 else {
            return .separatorColor.withAlphaComponent(0.45)
        }

        let progress = min(1, max(0, spanSeconds / targetDurationSeconds))
        switch progress {
        case 0..<0.4:
            return .systemRed.withAlphaComponent(0.75)
        case 0.4..<0.75:
            return .systemOrange.withAlphaComponent(0.8)
        case 0.75..<1:
            return .systemBlue.withAlphaComponent(0.82)
        default:
            return .systemGreen.withAlphaComponent(0.86)
        }
    }

    private func drawWeekdayLabels(originX: CGFloat, originY: CGFloat) {
        let labels = ["日", "一", "二", "三", "四", "五", "六"]
        for (index, label) in labels.enumerated() {
            drawText(
                label,
                at: NSPoint(x: 2, y: originY - CGFloat(index + 1) * (cellSize + gap) + 1),
                color: .secondaryLabelColor
            )
        }

        drawText("日期热力图", at: NSPoint(x: originX, y: bounds.maxY - 18), color: .secondaryLabelColor)
    }

    private func drawLegend() {
        let labels = [
            ("低", NSColor.systemRed.withAlphaComponent(0.75)),
            ("中", NSColor.systemOrange.withAlphaComponent(0.8)),
            ("高", NSColor.systemBlue.withAlphaComponent(0.82)),
            ("达标", NSColor.systemGreen.withAlphaComponent(0.86))
        ]

        var x = bounds.maxX - 160
        let y: CGFloat = 12
        for (label, color) in labels {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y + 2, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
            drawText(label, at: NSPoint(x: x + 16, y: y), color: .secondaryLabelColor)
            x += label == "达标" ? 48 : 38
        }
    }

    private func drawText(_ text: String, at point: NSPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: color
        ]
        text.draw(at: point, withAttributes: attributes)
    }

    private func drawEmptyMessage(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}
