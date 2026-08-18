import AppKit

final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Palette.separator.cgColor
    }

    required init?(coder: NSCoder) { nil }
}

final class StatusDotView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = Palette.gray.cgColor
        setAccessibilityLabel("状态未知")
    }

    required init?(coder: NSCoder) { nil }

    func set(color: NSColor, label: String) {
        layer?.backgroundColor = color.cgColor
        setAccessibilityLabel(label)
    }
}

class DragRegionView: NSView {
    private var initialMouseLocation = NSPoint.zero
    private var initialWindowOrigin = NSPoint.zero
    var actionMenu: NSMenu?
    var onDragEnded: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? { actionMenu }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowOrigin = window.frame.origin
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let location = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: initialWindowOrigin.x + location.x - initialMouseLocation.x,
            y: initialWindowOrigin.y + location.y - initialMouseLocation.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.openHand.set()
        onDragEnded?()
    }
}

final class ModelRowView: NSView {
    private let modelLabel = NSTextField(labelWithString: "")
    private let statusDot = StatusDotView()
    private let statusLabel = NSTextField(labelWithString: "--")
    private let historyLabel = NSTextField(labelWithString: "--")

    init(modelName: String, showsSeparator: Bool = true) {
        super.init(frame: .zero)
        modelLabel.stringValue = modelName
        modelLabel.font = .systemFont(ofSize: 14, weight: .medium)
        modelLabel.textColor = Palette.text
        modelLabel.lineBreakMode = .byTruncatingTail

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        statusLabel.textColor = Palette.text
        statusLabel.lineBreakMode = .byTruncatingTail

        historyLabel.font = .systemFont(ofSize: 13, weight: .regular)
        historyLabel.textColor = Palette.text
        historyLabel.lineBreakMode = .byTruncatingTail

        let statusCell = NSView()
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusCell.addSubview(statusDot)
        statusCell.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusDot.leadingAnchor.constraint(equalTo: statusCell.leadingAnchor),
            statusDot.centerYAnchor.constraint(equalTo: statusCell.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: statusCell.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusCell.trailingAnchor)
        ])

        [modelLabel, statusCell, historyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        let separator = SeparatorView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.isHidden = !showsSeparator
        addSubview(separator)

        NSLayoutConstraint.activate([
            modelLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            modelLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            modelLabel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.32),
            statusCell.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24).withPriority(.defaultLow),
            statusCell.leadingAnchor.constraint(equalTo: modelLabel.trailingAnchor, constant: 8),
            statusCell.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusCell.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.27),
            historyLabel.leadingAnchor.constraint(equalTo: statusCell.trailingAnchor, constant: 10),
            historyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            historyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ presentation: ProbePresentation) {
        switch presentation.phase {
        case .unknown:
            statusDot.set(color: Palette.gray, label: "状态未知")
            statusLabel.stringValue = "--"
            historyLabel.stringValue = "--"
        case .online:
            let latency = presentation.latencyMilliseconds ?? 0
            let isSlow = latency >= AppConfig.slowLatencyMilliseconds
            statusDot.set(color: isSlow ? Palette.amber : Palette.green, label: isSlow ? "正常但延迟较高" : "正常")
            statusLabel.stringValue = formatLatency(latency)
            historyLabel.stringValue = presentation.previousOppositeDuration.map {
                "异常 \(formatDuration($0))"
            } ?? "异常 --"
        case .failed:
            statusDot.set(color: Palette.red, label: "失败")
            statusLabel.stringValue = "失败"
            historyLabel.stringValue = presentation.previousOppositeDuration.map {
                "正常 \(formatDuration($0))"
            } ?? "正常 --"
        }
    }
}

final class SegmentedUsageBar: NSView {
    private let currentLayer = CALayer()
    private let otherLayer = CALayer()
    private let remainingLayer = CALayer()
    private var currentUsage: Double = 0
    private var otherUsage: Double = 0
    private var remainingUsage: Double = 0
    private var totalQuota: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Palette.separator.cgColor
        layer?.cornerRadius = 3
        layer?.masksToBounds = true
        currentLayer.backgroundColor = Palette.green.cgColor
        otherLayer.backgroundColor = Palette.amber.cgColor
        remainingLayer.backgroundColor = Palette.gray.cgColor
        currentLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        otherLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        remainingLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(currentLayer)
        layer?.addSublayer(otherLayer)
        layer?.addSublayer(remainingLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard totalQuota > 0 else {
            currentLayer.frame = .zero
            otherLayer.frame = .zero
            remainingLayer.frame = .zero
            return
        }

        let current = min(max(currentUsage, 0), totalQuota)
        let other = min(max(otherUsage, 0), totalQuota - current)
        let remaining = min(max(remainingUsage, 0), totalQuota - current - other)
        let currentWidth = width * CGFloat(current / totalQuota)
        let otherWidth = width * CGFloat(other / totalQuota)
        let remainingWidth = width * CGFloat(remaining / totalQuota)
        currentLayer.frame = NSRect(x: 0, y: 0, width: currentWidth, height: bounds.height)
        otherLayer.frame = NSRect(x: currentWidth, y: 0, width: otherWidth, height: bounds.height)
        remainingLayer.frame = NSRect(
            x: currentWidth + otherWidth,
            y: 0,
            width: remainingWidth,
            height: bounds.height
        )
    }

    func update(current: Double, other: Double, remaining: Double, total: Double) {
        currentUsage = max(current, 0)
        otherUsage = max(other, 0)
        remainingUsage = max(remaining, 0)
        totalQuota = max(total, 0)
        needsLayout = true
    }
}

final class QuotaLegendView: NSView {
    private let dot = StatusDotView()
    private let label = NSTextField(labelWithString: "--")

    init(alignment: NSLayoutConstraint.Attribute) {
        super.init(frame: .zero)

        dot.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = Palette.text
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [dot, label])
        content.orientation = .horizontal
        content.spacing = 6
        content.alignment = .centerY
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        let horizontalConstraint: NSLayoutConstraint
        switch alignment {
        case .centerX:
            horizontalConstraint = content.centerXAnchor.constraint(equalTo: centerXAnchor)
        case .trailing:
            horizontalConstraint = content.trailingAnchor.constraint(equalTo: trailingAnchor)
        default:
            horizontalConstraint = content.leadingAnchor.constraint(equalTo: leadingAnchor)
        }

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            horizontalConstraint,
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(text: String, color: NSColor, accessibilityLabel: String) {
        label.stringValue = text
        dot.set(color: color, label: accessibilityLabel)
    }
}

final class QuotaView: NSView {
    private let currentLegend = QuotaLegendView(alignment: .leading)
    private let otherLegend = QuotaLegendView(alignment: .centerX)
    private let remainingLegend = QuotaLegendView(alignment: .trailing)
    private let progress = SegmentedUsageBar()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        progress.translatesAutoresizingMaskIntoConstraints = false

        let legends = NSStackView(views: [currentLegend, otherLegend, remainingLegend])
        legends.orientation = .horizontal
        legends.distribution = .fillEqually
        legends.spacing = 8
        legends.translatesAutoresizingMaskIntoConstraints = false

        addSubview(progress)
        addSubview(legends)
        NSLayoutConstraint.activate([
            progress.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            progress.heightAnchor.constraint(equalToConstant: 6),
            legends.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 12),
            legends.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            legends.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func showEmpty() {
        updateLegends(current: "当前 --", other: "其他 --", remaining: "剩余 --")
        progress.update(current: 0, other: 0, remaining: 0, total: 0)
    }

    func showLoading() {
        updateLegends(current: "当前 更新中", other: "其他 --", remaining: "剩余 --")
        progress.update(current: 0, other: 0, remaining: 0, total: 0)
    }

    func showError(_ message: String) {
        currentLegend.update(text: message, color: Palette.red, accessibilityLabel: message)
        otherLegend.update(text: "其他 --", color: Palette.gray, accessibilityLabel: "其他未知")
        remainingLegend.update(text: "剩余 --", color: Palette.gray, accessibilityLabel: "剩余未知")
        progress.update(current: 0, other: 0, remaining: 0, total: 0)
    }

    func show(snapshot: QuotaSnapshot) {
        update(current: snapshot.current, other: snapshot.other, total: snapshot.total)
    }

    private func update(current: Double, other: Double, total: Double) {
        let remaining = max(total - current - other, 0)
        updateLegends(
            current: "当前 \(money(current))",
            other: "其他 \(money(other))",
            remaining: "剩余 \(money(remaining))"
        )
        progress.update(current: current, other: other, remaining: remaining, total: total)
    }

    private func updateLegends(current: String, other: String, remaining: String) {
        currentLegend.update(text: current, color: Palette.green, accessibilityLabel: current)
        otherLegend.update(text: other, color: Palette.amber, accessibilityLabel: other)
        remainingLegend.update(text: remaining, color: Palette.gray, accessibilityLabel: remaining)
    }

    private func money(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}

final class AlphaSliderMenuView: NSView {
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider: NSSlider
    var onChange: ((CGFloat) -> Void)?

    init(alpha: CGFloat) {
        slider = NSSlider(value: Double(alpha * 100), minValue: 20, maxValue: 100, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 52))

        let title = NSTextField(labelWithString: "透明度")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = Palette.secondaryText
        valueLabel.alignment = .right

        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.toolTip = "拖动调整背景透明度"

        [title, valueLabel, slider].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            valueLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])
        updateLabel()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func sliderChanged() {
        updateLabel()
        onChange?(CGFloat(slider.doubleValue / 100))
    }

    private func updateLabel() {
        valueLabel.stringValue = "\(Int(slider.doubleValue.rounded()))%"
    }
}

final class RefreshIntervalMenuView: NSView {
    private static let intervals = AppConfig.allowedRefreshIntervals
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider: NSSlider
    var onChange: ((TimeInterval) -> Void)?

    init(interval: TimeInterval) {
        let initialIndex = Self.intervals.firstIndex(of: interval) ?? 0
        slider = NSSlider(
            value: Double(initialIndex),
            minValue: 0,
            maxValue: Double(Self.intervals.count - 1),
            target: nil,
            action: nil
        )
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 52))

        let title = NSTextField(labelWithString: "刷新频率")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = Palette.secondaryText
        valueLabel.alignment = .right

        slider.numberOfTickMarks = Self.intervals.count
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.toolTip = "拖动调整自动刷新频率"

        [title, valueLabel, slider].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            valueLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])
        updateLabel()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func sliderChanged() {
        let index = min(max(Int(slider.doubleValue.rounded()), 0), Self.intervals.count - 1)
        slider.doubleValue = Double(index)
        updateLabel()
        onChange?(Self.intervals[index])
    }

    private func updateLabel() {
        let index = min(max(Int(slider.doubleValue.rounded()), 0), Self.intervals.count - 1)
        valueLabel.stringValue = "每 \(Int(Self.intervals[index] / 60)) 分钟"
    }
}

final class StatusWidgetView: NSView {
    private let aggregateDot = StatusDotView()
    private let titleLabel = NSTextField(labelWithString: AppConfig.appName)
    private let availabilityLabel = NSTextField(labelWithString: "等待检测")
    private let refreshButton = NSButton()
    private let collapseButton = NSButton()
    private let menuButton = NSButton()
    private let quotaView = QuotaView()
    private let footerUpdatedLabel = NSTextField(labelWithString: "上次更新 --")
    private let footerKeyLabel = NSTextField(labelWithString: "Key 未配置")
    private let dragRegion = DragRegionView()
    private var rows: [String: ModelRowView] = [:]

    var onRefresh: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onMenu: ((NSView) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 0.55, alpha: 0.65).cgColor

        dragRegion.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dragRegion)

        aggregateDot.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 21, weight: .bold)
        titleLabel.textColor = Palette.text
        availabilityLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        availabilityLabel.textColor = Palette.text

        configureIconButton(refreshButton, symbol: "arrow.clockwise", tooltip: "立即刷新", action: #selector(refreshClicked))
        configureIconButton(collapseButton, symbol: "arrow.down.right.and.arrow.up.left", tooltip: "收起为悬浮球", action: #selector(collapseClicked))
        configureIconButton(menuButton, symbol: "ellipsis", tooltip: "更多操作", action: #selector(menuClicked))

        [aggregateDot, titleLabel, availabilityLabel, refreshButton, collapseButton, menuButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        let firstSeparator = SeparatorView()
        firstSeparator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(firstSeparator)

        quotaView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(quotaView)

        let secondSeparator = SeparatorView()
        secondSeparator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(secondSeparator)

        let table = NSView()
        table.translatesAutoresizingMaskIntoConstraints = false
        addSubview(table)
        buildTable(in: table)

        let footerSeparator = SeparatorView()
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footerSeparator)

        footerUpdatedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        footerKeyLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        footerUpdatedLabel.textColor = Palette.secondaryText
        footerKeyLabel.textColor = Palette.secondaryText
        footerKeyLabel.alignment = .right
        [footerUpdatedLabel, footerKeyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            dragRegion.topAnchor.constraint(equalTo: topAnchor),
            dragRegion.leadingAnchor.constraint(equalTo: leadingAnchor),
            dragRegion.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragRegion.heightAnchor.constraint(equalToConstant: 64),

            aggregateDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            aggregateDot.centerYAnchor.constraint(equalTo: topAnchor, constant: 32),
            aggregateDot.widthAnchor.constraint(equalToConstant: 12),
            aggregateDot.heightAnchor.constraint(equalToConstant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: aggregateDot.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: aggregateDot.centerYAnchor),
            availabilityLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 16),
            availabilityLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            availabilityLabel.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -10),

            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            menuButton.centerYAnchor.constraint(equalTo: aggregateDot.centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 34),
            menuButton.heightAnchor.constraint(equalToConstant: 34),
            collapseButton.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -5),
            collapseButton.centerYAnchor.constraint(equalTo: menuButton.centerYAnchor),
            collapseButton.widthAnchor.constraint(equalToConstant: 34),
            collapseButton.heightAnchor.constraint(equalToConstant: 34),
            refreshButton.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor, constant: -5),
            refreshButton.centerYAnchor.constraint(equalTo: menuButton.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 34),
            refreshButton.heightAnchor.constraint(equalToConstant: 34),

            firstSeparator.topAnchor.constraint(equalTo: topAnchor, constant: 64),
            firstSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            firstSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            firstSeparator.heightAnchor.constraint(equalToConstant: 1),

            quotaView.topAnchor.constraint(equalTo: firstSeparator.bottomAnchor),
            quotaView.leadingAnchor.constraint(equalTo: leadingAnchor),
            quotaView.trailingAnchor.constraint(equalTo: trailingAnchor),
            quotaView.heightAnchor.constraint(equalToConstant: 82),
            secondSeparator.topAnchor.constraint(equalTo: quotaView.bottomAnchor),
            secondSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            secondSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            secondSeparator.heightAnchor.constraint(equalToConstant: 1),

            table.topAnchor.constraint(equalTo: secondSeparator.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: leadingAnchor),
            table.trailingAnchor.constraint(equalTo: trailingAnchor),
            table.heightAnchor.constraint(equalToConstant: 258),

            footerSeparator.topAnchor.constraint(equalTo: table.bottomAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerSeparator.heightAnchor.constraint(equalToConstant: 1),
            footerUpdatedLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            footerUpdatedLabel.centerYAnchor.constraint(equalTo: footerSeparator.bottomAnchor, constant: 23),
            footerKeyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            footerKeyLabel.centerYAnchor.constraint(equalTo: footerUpdatedLabel.centerYAnchor),
            footerKeyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: footerUpdatedLabel.trailingAnchor, constant: 12)
        ])
    }

    required init?(coder: NSCoder) { nil }

    var actionMenu: NSMenu? {
        get { dragRegion.actionMenu }
        set { dragRegion.actionMenu = newValue }
    }

    var onDragEnded: (() -> Void)? {
        get { dragRegion.onDragEnded }
        set { dragRegion.onDragEnded = newValue }
    }

    func setBackgroundAlpha(_ alpha: CGFloat) {
        layer?.backgroundColor = NSColor(calibratedWhite: 0.985, alpha: alpha).cgColor
    }

    func setRefreshing(_ refreshing: Bool) {
        refreshButton.isEnabled = !refreshing
        refreshButton.contentTintColor = refreshing ? Palette.tertiaryText : Palette.text
        if refreshing, rows.isEmpty {
            availabilityLabel.stringValue = "正在检测"
        }
    }

    func updateModel(id: String, presentation: ProbePresentation) {
        rows[id]?.update(presentation)
    }

    func updateAggregate(available: Int, total: Int, hasResults: Bool) {
        guard hasResults else {
            availabilityLabel.stringValue = "等待检测"
            aggregateDot.set(color: Palette.gray, label: "等待检测")
            return
        }
        availabilityLabel.stringValue = "\(available) / \(total) 可用"
        let color = available > 0 ? Palette.green : Palette.red
        aggregateDot.set(color: color, label: availabilityLabel.stringValue)
    }

    func updateFooter(date: Date?, maskedKey: String?) {
        if let date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "HH:mm:ss"
            footerUpdatedLabel.stringValue = "上次更新 \(formatter.string(from: date))"
        } else {
            footerUpdatedLabel.stringValue = "上次更新 --"
        }
        footerKeyLabel.stringValue = maskedKey.map { "Key \($0)" } ?? "Key 未配置"
    }

    func showQuotaEmpty() { quotaView.showEmpty() }
    func showQuotaLoading() { quotaView.showLoading() }
    func showQuotaError(_ message: String) { quotaView.showError(message) }
    func showQuota(_ snapshot: QuotaSnapshot) { quotaView.show(snapshot: snapshot) }

    private func buildTable(in table: NSView) {
        let header = NSView()
        let modelHeader = headerLabel("模型")
        let statusHeader = headerLabel("状态 / 延迟")
        let historyHeader = headerLabel("上次")
        [header, modelHeader, statusHeader, historyHeader].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        table.addSubview(header)
        [modelHeader, statusHeader, historyHeader].forEach { header.addSubview($0) }

        let headerSeparator = SeparatorView()
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerSeparator)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: table.topAnchor),
            header.leadingAnchor.constraint(equalTo: table.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: table.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 38),
            modelHeader.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24),
            modelHeader.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            modelHeader.widthAnchor.constraint(equalTo: header.widthAnchor, multiplier: 0.32),
            statusHeader.leadingAnchor.constraint(equalTo: modelHeader.trailingAnchor, constant: 8),
            statusHeader.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusHeader.widthAnchor.constraint(equalTo: header.widthAnchor, multiplier: 0.27),
            historyHeader.leadingAnchor.constraint(equalTo: statusHeader.trailingAnchor, constant: 10),
            historyHeader.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -24),
            historyHeader.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerSeparator.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
            headerSeparator.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -18),
            headerSeparator.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            headerSeparator.heightAnchor.constraint(equalToConstant: 1)
        ])

        var previous: NSView = header
        for (index, model) in ModelDefinition.monitored.enumerated() {
            let row = ModelRowView(
                modelName: model.name,
                showsSeparator: index < ModelDefinition.monitored.count - 1
            )
            row.translatesAutoresizingMaskIntoConstraints = false
            table.addSubview(row)
            rows[model.id] = row
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: previous.bottomAnchor),
                row.leadingAnchor.constraint(equalTo: table.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: table.trailingAnchor),
                row.heightAnchor.constraint(equalToConstant: 55)
            ])
            previous = row
        }
    }

    private func headerLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = Palette.secondaryText
        return label
    }

    private func configureIconButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.contentTintColor = Palette.text
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.setAccessibilityLabel(tooltip)
    }

    @objc private func refreshClicked() { onRefresh?() }
    @objc private func collapseClicked() { onCollapse?() }
    @objc private func menuClicked() { onMenu?(menuButton) }
}
