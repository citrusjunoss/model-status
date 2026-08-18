import AppKit
import CoreGraphics
import CryptoKit
import Security

private enum AppConfig {
    static let appName = "InputStatus"
    static let legacyWindowFrameKey = "ModelStatusDesktopWidget"
    static let orbFrameKey = "orbFrame.v1"
    static let detailFrameKey = "detailFrame.v1"
    static let backgroundAlphaKey = "backgroundAlpha"
    static let refreshIntervalKey = "refreshIntervalSeconds"
    static let probeHistoryKey = "probeHistory.v1"
    static let probeBackoffKey = "probeBackoff.v1"
    static let defaultSize = NSSize(width: 500, height: 470)
    static let minimumSize = NSSize(width: 430, height: 450)
    static let orbSize = NSSize(width: 104, height: 104)
    static let orbInfoSize = NSSize(width: 272, height: 170)
    static let defaultBackgroundAlpha = 0.92
    static let defaultRefreshInterval: TimeInterval = 60
    static let allowedRefreshIntervals: [TimeInterval] = [60, 120, 300, 600, 900]
    static let probeTimeout: TimeInterval = 45
    static let slowLatencyMilliseconds = 5_000
    static let stabilityWindow: TimeInterval = 60 * 60
    static let keychainService = "im.input.model-status.secure-v2"
    static let keychainAccount = "quota-api-key"
    static let usageURL = URL(string: "https://ai.input.im/v1/usage")!
    static let probeURL = URL(string: "https://ai.input.im/v1/responses")!
    static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
    static let githubRepository = "citrusjunoss/model-status"
    static let probeBackoffDelays: [TimeInterval] = [5 * 60, 10 * 60, 30 * 60]

    static var desktopLevel: NSWindow.Level {
        // Matches the level used by WidgetKit desktop widgets.
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
    }
}

private enum WidgetMode: String {
    case orb
    case detail
}

private enum PauseReason: Hashable {
    case session
    case systemSleep
}

private enum Palette {
    static let text = NSColor(calibratedWhite: 0.08, alpha: 1)
    static let secondaryText = NSColor(calibratedWhite: 0.40, alpha: 1)
    static let tertiaryText = NSColor(calibratedWhite: 0.54, alpha: 1)
    static let separator = NSColor(calibratedWhite: 0.78, alpha: 0.55)
    static let green = NSColor(calibratedRed: 0.08, green: 0.68, blue: 0.32, alpha: 1)
    static let amber = NSColor(calibratedRed: 0.95, green: 0.58, blue: 0.02, alpha: 1)
    static let red = NSColor(calibratedRed: 0.88, green: 0.12, blue: 0.10, alpha: 1)
    static let gray = NSColor(calibratedWhite: 0.62, alpha: 1)
}

private enum KeychainStore {
    static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.keychainService,
            kSecAttrAccount as String: AppConfig.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveAPIKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.keychainService,
            kSecAttrAccount as String: AppConfig.keychainAccount
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = query
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        addQuery[kSecValueData as String] = data
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.keychainService,
            kSecAttrAccount as String: AppConfig.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private struct ModelDefinition {
    let id: String
    let name: String
    let shortName: String

    static let monitored = [
        ModelDefinition(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", shortName: "S"),
        ModelDefinition(id: "gpt-5.6-terra", name: "GPT-5.6 Terra", shortName: "T"),
        ModelDefinition(id: "gpt-5.6-luna", name: "GPT-5.6 Lunna", shortName: "L"),
        ModelDefinition(id: "gpt-5.5", name: "GPT-5.5", shortName: "5.5")
    ]

    static var orbModel: ModelDefinition { monitored[0] }
    static var orbModels: [ModelDefinition] { [orbModel] }
    static var detailOnlyModels: [ModelDefinition] { Array(monitored.dropFirst()) }
}

private struct ProbeHistoryEntry: Codable {
    var isOnline: Bool
    var statusStartedAt: Date
    var previousOppositeDuration: TimeInterval?
    var lastLatencyMilliseconds: Int?
    var lastCheckedAt: Date
}

private struct ProbeBackoffState: Codable {
    var consecutiveFailures: Int
    var nextAllowedAt: Date
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let body: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case assets
    }
}

private enum ProbePhase {
    case unknown
    case online
    case failed
}

private struct ProbePresentation {
    let phase: ProbePhase
    let latencyMilliseconds: Int?
    let previousOppositeDuration: TimeInterval?
    let hasRecentInterruption: Bool
}

private struct UsageResponse: Decodable {
    struct Quota: Decodable {
        let limit: Double
        let used: Double
        let remaining: Double
    }

    struct Subscription: Decodable {
        let dailyUsageUSD: Double?
        let dailyLimitUSD: Double?
        let weeklyUsageUSD: Double?
        let weeklyLimitUSD: Double?
        let monthlyUsageUSD: Double?
        let monthlyLimitUSD: Double?

        enum CodingKeys: String, CodingKey {
            case dailyUsageUSD = "daily_usage_usd"
            case dailyLimitUSD = "daily_limit_usd"
            case weeklyUsageUSD = "weekly_usage_usd"
            case weeklyLimitUSD = "weekly_limit_usd"
            case monthlyUsageUSD = "monthly_usage_usd"
            case monthlyLimitUSD = "monthly_limit_usd"
        }
    }

    struct Usage: Decodable {
        struct Today: Decodable {
            let actualCost: Double?

            enum CodingKeys: String, CodingKey {
                case actualCost = "actual_cost"
            }
        }

        let actualCost: Double?
        let today: Today?

        enum CodingKeys: String, CodingKey {
            case actualCost = "actual_cost"
            case today
        }
    }

    struct DailyUsage: Decodable {
        let actualCost: Double?

        enum CodingKeys: String, CodingKey {
            case actualCost = "actual_cost"
        }
    }

    let mode: String?
    let planName: String?
    let quota: Quota?
    let subscription: Subscription?
    let balance: Double?
    let remaining: Double?
    let usage: Usage?
    let dailyUsage: [DailyUsage]?

    var currentActualCost: Double? {
        usage?.today?.actualCost ?? usage?.actualCost ?? dailyUsage?.first?.actualCost
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case planName
        case quota
        case subscription
        case balance
        case remaining
        case usage
        case dailyUsage = "daily_usage"
    }
}

private struct QuotaSnapshot {
    let current: Double
    let other: Double
    let remaining: Double
    let total: Double
    let remainingFraction: Double
    let updatedAt: Date

    init(response: UsageResponse, now: Date = Date()) {
        let period: (used: Double, limit: Double)
        if let subscription = response.subscription,
           let limit = subscription.dailyLimitUSD, limit > 0 {
            period = (subscription.dailyUsageUSD ?? 0, limit)
        } else if let quota = response.quota, quota.limit > 0 {
            period = (quota.used, quota.limit)
        } else if let subscription = response.subscription,
                  let limit = subscription.weeklyLimitUSD, limit > 0 {
            period = (subscription.weeklyUsageUSD ?? 0, limit)
        } else if let subscription = response.subscription,
                  let limit = subscription.monthlyLimitUSD, limit > 0 {
            period = (subscription.monthlyUsageUSD ?? 0, limit)
        } else {
            let used = max(response.currentActualCost ?? 0, 0)
            period = (used, used + max(response.remaining ?? response.balance ?? 0, 0))
        }

        let used = min(max(period.used, 0), max(period.limit, 0))
        let current = min(max(response.currentActualCost ?? response.quota?.used ?? 0, 0), used)
        let other = max(used - current, 0)
        let remaining = max(period.limit - used, 0)
        self.current = current
        self.other = other
        self.remaining = remaining
        self.total = max(period.limit, 0)
        self.remainingFraction = period.limit > 0 ? min(max(remaining / period.limit, 0), 1) : 0
        updatedAt = now
    }

    init(current: Double, other: Double, remaining: Double, total: Double, updatedAt: Date) {
        self.current = current
        self.other = other
        self.remaining = remaining
        self.total = total
        self.remainingFraction = total > 0 ? min(max(remaining / total, 0), 1) : 0
        self.updatedAt = updatedAt
    }
}

private final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Palette.separator.cgColor
    }

    required init?(coder: NSCoder) { nil }
}

private final class StatusDotView: NSView {
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

private class DragRegionView: NSView {
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

private final class ModelRowView: NSView {
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

private final class SegmentedUsageBar: NSView {
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

private final class QuotaLegendView: NSView {
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

private final class QuotaView: NSView {
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

private final class AlphaSliderMenuView: NSView {
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

private final class RefreshIntervalMenuView: NSView {
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

private final class StatusWidgetView: NSView {
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

private final class OrbWidgetView: NSView {
    private var presentations: [String: ProbePresentation] = [:]
    private var quota: QuotaSnapshot?
    private var wavePhase: CGFloat = 0
    private var waveTimer: Timer?
    private var displayedLatencyProgress: CGFloat?
    private var targetLatencyProgress: CGFloat?
    private var latencyAnimationTimer: Timer?
    private var trackingArea: NSTrackingArea?
    private var mouseDownLocation = NSPoint.zero
    private var windowOriginAtMouseDown = NSPoint.zero
    private var didDrag = false

    var actionMenu: NSMenu?
    var onOpenDetail: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onDragEnded: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("InputStatus 悬浮球")
        toolTip = "单击展开，拖动移动"
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        waveTimer?.invalidate()
        latencyAnimationTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWaveTimer()
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? { actionMenu }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        mouseDownLocation = NSEvent.mouseLocation
        windowOriginAtMouseDown = window.frame.origin
        didDrag = false
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - mouseDownLocation.x
        let dy = current.y - mouseDownLocation.y
        if hypot(dx, dy) >= 3 { didDrag = true }
        guard didDrag else { return }
        window.setFrameOrigin(NSPoint(x: windowOriginAtMouseDown.x + dx, y: windowOriginAtMouseDown.y + dy))
        onHoverChanged?(false)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.openHand.set()
        if didDrag {
            onDragEnded?()
        } else {
            onOpenDetail?()
        }
    }

    func setBackgroundAlpha(_ alpha: CGFloat) {
        alphaValue = min(max(alpha, 0.2), 1)
    }

    func update(presentations: [String: ProbePresentation], quota: QuotaSnapshot?) {
        updateLatencyAnimation(for: presentations[ModelDefinition.orbModel.id])
        self.presentations = presentations
        self.quota = quota
        let percent = quota.map { Int(($0.remainingFraction * 100).rounded()) }
        let status = orbStatusText(presentations[ModelDefinition.orbModel.id])
        setAccessibilityValue("\(percent.map { "剩余额度 \($0)%" } ?? "剩余额度未知")，Sol \(status)")
        updateWaveTimer()
        needsDisplay = true
    }

    private func updateLatencyAnimation(for presentation: ProbePresentation?) {
        guard presentation?.phase == .online,
              let milliseconds = presentation?.latencyMilliseconds else {
            latencyAnimationTimer?.invalidate()
            latencyAnimationTimer = nil
            displayedLatencyProgress = nil
            targetLatencyProgress = nil
            return
        }

        let target = latencySpeedProgress(milliseconds)
        if let currentTarget = targetLatencyProgress, abs(target - currentTarget) <= 0.001 {
            return
        }

        latencyAnimationTimer?.invalidate()
        latencyAnimationTimer = nil
        targetLatencyProgress = target
        guard let start = displayedLatencyProgress,
              abs(target - start) > 0.001,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            displayedLatencyProgress = target
            return
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let duration: TimeInterval = 0.5
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let fraction = min(max(elapsed / duration, 0), 1)
            let eased = 1 - pow(1 - fraction, 3)
            displayedLatencyProgress = start + (target - start) * CGFloat(eased)
            needsDisplay = true
            if fraction >= 1 {
                timer.invalidate()
                latencyAnimationTimer = nil
            }
        }
        latencyAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateWaveTimer() {
        waveTimer?.invalidate()
        waveTimer = nil
        guard window != nil,
              quota != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        waveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            wavePhase += 0.085
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = min(bounds.width / AppConfig.orbSize.width, bounds.height / AppConfig.orbSize.height)
        let offset = NSPoint(
            x: (bounds.width - AppConfig.orbSize.width * scale) / 2,
            y: (bounds.height - AppConfig.orbSize.height * scale) / 2
        )
        context.saveGState()
        context.translateBy(x: offset.x, y: offset.y)
        context.scaleBy(x: scale, y: scale)
        drawOrb(in: context)
        context.restoreGState()
    }

    private func drawOrb(in context: CGContext) {
        let center = CGPoint(x: 52, y: 52)
        drawMetalBase(context, center: center)
        drawLatencyGauge(context, center: center, presentation: presentations[ModelDefinition.orbModel.id])
        drawCenterGauge(context, center: center)
    }

    private func drawMetalBase(_ context: CGContext, center: CGPoint) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2.2), blur: 5.5, color: NSColor.black.withAlphaComponent(0.78).cgColor)
        context.setFillColor(NSColor(calibratedWhite: 0.025, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: 2, y: 2, width: 100, height: 100))
        context.restoreGState()

        let brass = NSColor(calibratedRed: 0.64, green: 0.45, blue: 0.24, alpha: 1)
        let brassHighlight = NSColor(calibratedRed: 0.88, green: 0.70, blue: 0.44, alpha: 1)
        strokeCircle(context, center: center, radius: 49.2, width: 2.3, color: brass)
        strokeCircle(context, center: center, radius: 47.5, width: 0.8, color: brassHighlight.withAlphaComponent(0.84))
        strokeCircle(context, center: center, radius: 45.8, width: 1.4, color: NSColor.black.withAlphaComponent(0.94))
        drawArc(context, center: center, radius: 49.1, startDegrees: 34, endDegrees: 132, width: 0.9, color: brassHighlight.withAlphaComponent(0.62))
        drawArc(context, center: center, radius: 49.0, startDegrees: 205, endDegrees: 316, width: 1.0, color: NSColor(calibratedRed: 0.18, green: 0.10, blue: 0.05, alpha: 0.9))
    }

    private func drawLatencyGauge(
        _ context: CGContext,
        center: CGPoint,
        presentation: ProbePresentation?
    ) {
        let startDegrees: CGFloat = 230
        let sweepDegrees: CGFloat = 280
        let radius: CGFloat = 39
        let trackWidth: CGFloat = 3.8
        let stabilityRadius: CGFloat = 45
        let stabilityWidth: CGFloat = 1.4

        drawArc(context, center: center, radius: radius, startDegrees: startDegrees, endDegrees: startDegrees - sweepDegrees, width: 7, color: NSColor(calibratedWhite: 0.015, alpha: 0.98), clockwise: true)
        drawArc(context, center: center, radius: radius, startDegrees: startDegrees, endDegrees: startDegrees - sweepDegrees, width: trackWidth, color: NSColor(calibratedWhite: 0.19, alpha: 0.96), clockwise: true)
        drawArc(context, center: center, radius: radius + 2.8, startDegrees: startDegrees, endDegrees: startDegrees - sweepDegrees, width: 0.75, color: NSColor(calibratedRed: 0.76, green: 0.57, blue: 0.35, alpha: 0.62), clockwise: true)
        drawArc(context, center: center, radius: radius - 2.8, startDegrees: startDegrees, endDegrees: startDegrees - sweepDegrees, width: 0.65, color: NSColor(calibratedRed: 0.45, green: 0.33, blue: 0.20, alpha: 0.62), clockwise: true)

        for index in 0...20 {
            let progress = CGFloat(index) / 20
            let degrees = startDegrees - sweepDegrees * progress
            let major = index % 5 == 0
            let inner = point(center: center, radius: radius - (major ? 5.2 : 3.7), degrees: degrees)
            let outer = point(center: center, radius: radius + (major ? 4.8 : 3.1), degrees: degrees)
            context.saveGState()
            context.setStrokeColor(
                NSColor(
                    calibratedRed: major ? 0.84 : 0.45,
                    green: major ? 0.68 : 0.37,
                    blue: major ? 0.43 : 0.28,
                    alpha: major ? 0.88 : 0.62
                ).cgColor
            )
            context.setLineWidth(major ? 1.2 : 0.72)
            context.setLineCap(.round)
            context.move(to: inner)
            context.addLine(to: outer)
            context.strokePath()
            context.restoreGState()
        }

        let phase = presentation?.phase ?? .unknown
        let latency = presentation?.latencyMilliseconds
        let color: NSColor
        switch phase {
        case .unknown:
            color = Palette.gray
        case .failed:
            color = Palette.red
        case .online:
            if (latency ?? 0) >= AppConfig.slowLatencyMilliseconds {
                color = Palette.amber
            } else {
                color = Palette.green
            }
        }

        switch phase {
        case .online:
            let progress = displayedLatencyProgress ?? latencySpeedProgress(latency ?? 0)
            let visibleProgress = max(progress, 0.025)
            let endDegrees = startDegrees - sweepDegrees * visibleProgress
            drawArc(context, center: center, radius: radius, startDegrees: startDegrees, endDegrees: endDegrees, width: trackWidth * 0.68, color: color, clockwise: true)
            drawArc(context, center: center, radius: radius, startDegrees: startDegrees, endDegrees: endDegrees, width: 0.7, color: NSColor(calibratedRed: 1, green: 0.93, blue: 0.72, alpha: 0.48), clockwise: true)
            drawNeedle(context, center: center, radius: radius, degrees: startDegrees - sweepDegrees * progress)
        case .failed:
            drawArc(context, center: center, radius: radius, startDegrees: startDegrees, endDegrees: startDegrees - sweepDegrees, width: trackWidth * 0.72, color: color, clockwise: true)
        case .unknown:
            drawArc(context, center: center, radius: radius, startDegrees: startDegrees, endDegrees: startDegrees - sweepDegrees, width: trackWidth * 0.58, color: color, clockwise: true, dash: [3, 3])
        }

        strokeCircle(context, center: center, radius: stabilityRadius, width: stabilityWidth * 2.2, color: NSColor.black.withAlphaComponent(0.92))
        switch phase {
        case .failed:
            strokeCircle(context, center: center, radius: stabilityRadius, width: stabilityWidth, color: Palette.red)
        case .unknown:
            drawArc(context, center: center, radius: stabilityRadius, startDegrees: 0, endDegrees: 360, width: stabilityWidth, color: Palette.gray, dash: [3, 3.4])
        case .online:
            if presentation?.hasRecentInterruption == true {
                drawArc(context, center: center, radius: stabilityRadius, startDegrees: 0, endDegrees: 360, width: stabilityWidth, color: color, dash: [5, 4])
            } else {
                strokeCircle(context, center: center, radius: stabilityRadius, width: stabilityWidth, color: color)
                drawArc(context, center: center, radius: stabilityRadius, startDegrees: 35, endDegrees: 135, width: 0.45, color: NSColor(calibratedRed: 1, green: 0.91, blue: 0.70, alpha: 0.46))
            }
        }
    }

    private func drawNeedle(_ context: CGContext, center: CGPoint, radius: CGFloat, degrees: CGFloat) {
        let inner = point(center: center, radius: radius - 5.7, degrees: degrees)
        let outer = point(center: center, radius: radius + 5.4, degrees: degrees)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -0.6), blur: 1.2, color: NSColor.black.withAlphaComponent(0.9).cgColor)
        context.setStrokeColor(NSColor(calibratedRed: 0.95, green: 0.79, blue: 0.53, alpha: 1).cgColor)
        context.setLineWidth(1.55)
        context.setLineCap(.round)
        context.move(to: inner)
        context.addLine(to: outer)
        context.strokePath()
        context.setFillColor(NSColor(calibratedRed: 0.95, green: 0.75, blue: 0.39, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: outer.x - 1.35, y: outer.y - 1.35, width: 2.7, height: 2.7))
        context.restoreGState()
    }

    private func latencySpeedProgress(_ milliseconds: Int) -> CGFloat {
        let seconds = max(CGFloat(milliseconds), 0) / 1_000
        guard seconds > 1 else { return 1 }
        return max(1 - (seconds - 1) * 0.1, 0.1)
    }

    private func point(center: CGPoint, radius: CGFloat, degrees: CGFloat) -> CGPoint {
        let angle = radians(degrees)
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    private func drawArc(
        _ context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        startDegrees: CGFloat,
        endDegrees: CGFloat,
        width: CGFloat,
        color: NSColor,
        clockwise: Bool = false,
        dash: [CGFloat] = []
    ) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: dash)
        context.addArc(center: center, radius: radius, startAngle: radians(startDegrees), endAngle: radians(endDegrees), clockwise: clockwise)
        context.strokePath()
        context.restoreGState()
    }

    private func drawCenterGauge(_ context: CGContext, center: CGPoint) {
        let radius: CGFloat = 31
        strokeCircle(
            context,
            center: center,
            radius: radius + 1.1,
            width: 1.1,
            color: NSColor(calibratedRed: 0.58, green: 0.42, blue: 0.24, alpha: 0.9)
        )

        context.saveGState()
        context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.clip()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let background = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                NSColor(calibratedWhite: 0.20, alpha: 1).cgColor,
                NSColor(calibratedWhite: 0.025, alpha: 1).cgColor
            ] as CFArray,
            locations: [0, 1]
        ) {
            context.drawRadialGradient(
                background,
                startCenter: CGPoint(x: 39, y: 70),
                startRadius: 1,
                endCenter: center,
                endRadius: radius,
                options: [.drawsAfterEndLocation]
            )
        }

        if let quota {
            let fraction = CGFloat(quota.remainingFraction)
            let bottom = center.y - radius
            let liquidY = bottom + radius * 2 * fraction
            let leftX = center.x - radius - 2
            let rightX = center.x + radius + 2
            let waveHeight = min(2.8, max(1.3, radius * 0.09))
            let wavePath = CGMutablePath()
            wavePath.move(to: CGPoint(x: leftX, y: liquidY + sin(wavePhase) * waveHeight * 0.35))
            wavePath.addCurve(
                to: CGPoint(x: center.x, y: liquidY + sin(wavePhase + .pi) * waveHeight * 0.35),
                control1: CGPoint(x: center.x - radius * 0.62, y: liquidY + sin(wavePhase + 0.7) * waveHeight),
                control2: CGPoint(x: center.x - radius * 0.28, y: liquidY + sin(wavePhase + 1.5) * waveHeight)
            )
            wavePath.addCurve(
                to: CGPoint(x: rightX, y: liquidY + sin(wavePhase + .pi * 2) * waveHeight * 0.35),
                control1: CGPoint(x: center.x + radius * 0.28, y: liquidY + sin(wavePhase + 3.0) * waveHeight),
                control2: CGPoint(x: center.x + radius * 0.62, y: liquidY + sin(wavePhase + 3.8) * waveHeight)
            )
            let liquidPath = CGMutablePath()
            liquidPath.addPath(wavePath)
            liquidPath.addLine(to: CGPoint(x: rightX, y: bottom - 2))
            liquidPath.addLine(to: CGPoint(x: leftX, y: bottom - 2))
            liquidPath.closeSubpath()
            context.addPath(liquidPath)
            context.clip()
            if let liquid = CGGradient(
                colorsSpace: colorSpace,
                colors: [
                    NSColor(calibratedRed: 0.95, green: 0.03, blue: 0.05, alpha: 1).cgColor,
                    NSColor(calibratedRed: 0.32, green: 0.005, blue: 0.015, alpha: 1).cgColor
                ] as CFArray,
                locations: [0, 1]
            ) {
                context.drawLinearGradient(
                    liquid,
                    start: CGPoint(x: center.x, y: liquidY + 6),
                    end: CGPoint(x: center.x, y: bottom),
                    options: [.drawsAfterEndLocation]
                )
            }
            context.addPath(wavePath)
            context.setStrokeColor(NSColor(calibratedRed: 1, green: 0.44, blue: 0.32, alpha: 0.52).cgColor)
            context.setLineWidth(0.7)
            context.setLineCap(.round)
            context.strokePath()
        }
        context.restoreGState()

        strokeCircle(context, center: center, radius: radius, width: 1.35, color: NSColor.black.withAlphaComponent(0.92))
        drawArc(context, center: center, radius: radius * 0.79, startDegrees: 56, endDegrees: 130, width: 2.2, color: NSColor.white.withAlphaComponent(0.14))
        let percentText = quota.map { "\(Int(($0.remainingFraction * 100).rounded()))%" } ?? "--%"
        drawText(
            percentText,
            in: CGRect(x: center.x - 28, y: center.y - 4, width: 56, height: 18),
            font: .monospacedDigitSystemFont(ofSize: 16.5, weight: .semibold),
            color: quota == nil ? NSColor(calibratedWhite: 0.74, alpha: 1) : .white,
            alignment: .center
        )
    }

    private func strokeCircle(_ context: CGContext, center: CGPoint, radius: CGFloat, width: CGFloat, color: NSColor) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}

private final class OrbInfoView: NSView {
    private var presentations: [String: ProbePresentation] = [:]
    private var quota: QuotaSnapshot?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    func setBackgroundAlpha(_ alpha: CGFloat) {
        alphaValue = min(max(alpha, 0.2), 1)
    }

    func update(presentations: [String: ProbePresentation], quota: QuotaSnapshot?) {
        self.presentations = presentations
        self.quota = quota
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bubbleRect = NSRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 15)
        let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 12, yRadius: 12)
        bubble.move(to: NSPoint(x: bounds.midX - 11, y: bubbleRect.maxY))
        bubble.line(to: NSPoint(x: bounds.midX, y: bounds.maxY - 1))
        bubble.line(to: NSPoint(x: bounds.midX + 11, y: bubbleRect.maxY))
        bubble.close()
        NSColor(calibratedWhite: 0.045, alpha: 0.96).setFill()
        bubble.fill()
        NSColor(calibratedWhite: 0.34, alpha: 0.75).setStroke()
        bubble.lineWidth = 1
        bubble.stroke()

        let presentation = presentations[ModelDefinition.orbModel.id]
        let statusColor = orbStatusColor(presentation)
        drawText(
            ModelDefinition.orbModel.name,
            in: NSRect(x: 20, y: 115, width: 91, height: 20),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .white,
            alignment: .left
        )
        drawText(
            orbStatusText(presentation),
            in: NSRect(x: 113, y: 113, width: 57, height: 24),
            font: .monospacedDigitSystemFont(ofSize: 16, weight: .semibold),
            color: statusColor,
            alignment: .left
        )
        drawText(
            orbHistoryText(presentation),
            in: NSRect(x: 172, y: 116, width: 78, height: 18),
            font: .systemFont(ofSize: 11, weight: .regular),
            color: NSColor(calibratedWhite: 0.76, alpha: 1),
            alignment: .right
        )

        NSColor(calibratedRed: 0.55, green: 0.40, blue: 0.23, alpha: 0.78).setFill()
        NSBezierPath(rect: NSRect(x: 20, y: 95, width: bounds.width - 40, height: 1)).fill()

        let amount = quota.map { "\(money($0.remaining)) / \(money($0.total))" } ?? "-- / --"
        let updated = quota.map { formatTime($0.updatedAt) } ?? "--"
        drawInfoRow(label: "剩余额度", value: amount, y: 63)
        drawInfoRow(label: "更新", value: updated, y: 35)
    }

    private func drawInfoRow(label: String, value: String, y: CGFloat) {
        drawText(label, in: NSRect(x: 20, y: y, width: 72, height: 20), font: .systemFont(ofSize: 13), color: NSColor(calibratedWhite: 0.76, alpha: 1), alignment: .left)
        drawText(value, in: NSRect(x: 94, y: y, width: 156, height: 20), font: .monospacedDigitSystemFont(ofSize: 13, weight: .medium), color: .white, alignment: .left)
    }

    private func money(_ value: Double) -> String { String(format: "$%.2f", value) }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func orbHistoryText(_ presentation: ProbePresentation?) -> String {
        guard let presentation else { return "暂无数据" }
        switch presentation.phase {
        case .unknown:
            return "暂无数据"
        case .failed:
            return "当前请求失败"
        case .online:
            return presentation.hasRecentInterruption ? "近1小时有异常" : "近1小时稳定"
        }
    }
}

private func orbStatusColor(_ presentation: ProbePresentation?) -> NSColor {
    guard let presentation else { return Palette.gray }
    switch presentation.phase {
    case .unknown: return Palette.gray
    case .failed: return Palette.red
    case .online:
        let latency = presentation.latencyMilliseconds ?? 0
        if latency >= AppConfig.slowLatencyMilliseconds { return Palette.amber }
        return Palette.green
    }
}

private func orbStatusText(_ presentation: ProbePresentation?) -> String {
    guard let presentation else { return "--" }
    switch presentation.phase {
    case .unknown: return "--"
    case .failed: return "失败"
    case .online: return formatLatency(presentation.latencyMilliseconds ?? 0)
    }
}

private func radians(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }

private func drawText(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byTruncatingTail
    (text as NSString).draw(
        in: rect,
        withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    )
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: DesktopPanel!
    private var widgetView: StatusWidgetView!
    private var orbView: OrbWidgetView!
    private var orbInfoPanel: DesktopPanel!
    private var orbInfoView: OrbInfoView!
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var visibilityMenuItem: NSMenuItem!
    private var alphaSliderView: AlphaSliderMenuView!
    private var refreshIntervalMenuView: RefreshIntervalMenuView!
    private var refreshTimer: Timer?
    private var quotaTask: URLSessionDataTask?
    private var probeTasks: [String: URLSessionDataTask] = [:]
    private var probeGenerations: [String: UUID] = [:]
    private var histories: [String: ProbeHistoryEntry] = [:]
    private var probeBackoffs: [String: ProbeBackoffState] = [:]
    private var quotaSnapshot: QuotaSnapshot?
    private var apiKey: String?
    private var currentMode: WidgetMode = .orb
    private var isApplyingFrame = false
    private var pauseReasons: Set<PauseReason> = []
    private var wakeGeneration = UUID()
    private var isCheckingForUpdates = false

    private var isPaused: Bool { !pauseReasons.isEmpty }

    private let arguments = ProcessInfo.processInfo.arguments
    private var isMinimumQAPreview: Bool { arguments.contains("--qa-preview-minimum") }
    private var isOrbQAPreview: Bool {
        arguments.contains("--qa-orb")
            || arguments.contains("--qa-orb-hover")
            || arguments.contains("--qa-orb-low")
            || arguments.contains("--qa-orb-empty")
            || arguments.contains("--qa-orb-interrupted")
            || arguments.contains("--qa-orb-failed")
    }
    private var isQAPreview: Bool {
        arguments.contains("--qa-preview") || isMinimumQAPreview || isOrbQAPreview
    }

    private var backgroundAlpha: CGFloat {
        let value = UserDefaults.standard.object(forKey: AppConfig.backgroundAlphaKey) as? NSNumber
        return min(max(CGFloat(value?.doubleValue ?? AppConfig.defaultBackgroundAlpha), 0.2), 1)
    }

    private var selectedRefreshInterval: TimeInterval {
        let stored = (UserDefaults.standard.object(forKey: AppConfig.refreshIntervalKey) as? NSNumber)?.doubleValue
        guard let stored, AppConfig.allowedRefreshIntervals.contains(stored) else {
            return AppConfig.defaultRefreshInterval
        }
        return stored
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        histories = loadHistories()
        probeBackoffs = loadProbeBackoffs()
        if !isQAPreview { apiKey = KeychainStore.readAPIKey() }
        if isOrbQAPreview {
            currentMode = .orb
        } else if isQAPreview {
            currentMode = .detail
        } else {
            currentMode = .orb
        }

        buildWidget()
        configureStatusItem()
        widgetView.actionMenu = statusItem.menu
        orbView.actionMenu = statusItem.menu
        configureSessionNotifications()

        if isQAPreview {
            panel.level = .floating
            orbInfoPanel.level = .floating
            renderQAPreview()
        } else {
            renderPersistedState()
            refreshAll()
            scheduleRefreshTimer()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.checkForUpdates(manual: false)
            }
        }

        panel.orderFrontRegardless()
        updateVisibilityMenuTitle()
        if isQAPreview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.captureQAPreview()
            }
        }
    }

    private func renderQAPreview() {
        let samples: [ProbePresentation]
        if arguments.contains("--qa-orb-empty") {
            samples = Array(repeating: ProbePresentation(phase: .unknown, latencyMilliseconds: nil, previousOppositeDuration: nil, hasRecentInterruption: false), count: 4)
            quotaSnapshot = nil
        } else {
            let solSample: ProbePresentation
            if arguments.contains("--qa-orb-failed") {
                solSample = ProbePresentation(phase: .failed, latencyMilliseconds: nil, previousOppositeDuration: 21 * 60, hasRecentInterruption: false)
            } else if arguments.contains("--qa-orb-interrupted") {
                solSample = ProbePresentation(phase: .online, latencyMilliseconds: 4_200, previousOppositeDuration: 7.9 * 60, hasRecentInterruption: true)
            } else if arguments.contains("--qa-orb-low") {
                solSample = ProbePresentation(phase: .online, latencyMilliseconds: 2_600, previousOppositeDuration: nil, hasRecentInterruption: false)
            } else if arguments.contains("--qa-orb-hover") {
                solSample = ProbePresentation(phase: .online, latencyMilliseconds: 4_200, previousOppositeDuration: nil, hasRecentInterruption: false)
            } else {
                solSample = ProbePresentation(phase: .online, latencyMilliseconds: 428, previousOppositeDuration: nil, hasRecentInterruption: false)
            }
            samples = [
                solSample,
                ProbePresentation(phase: .online, latencyMilliseconds: 2_600, previousOppositeDuration: nil, hasRecentInterruption: false),
                ProbePresentation(phase: .failed, latencyMilliseconds: nil, previousOppositeDuration: 21 * 60, hasRecentInterruption: false),
                ProbePresentation(phase: .online, latencyMilliseconds: 740, previousOppositeDuration: nil, hasRecentInterruption: false)
            ]
            if arguments.contains("--qa-orb-low") {
                quotaSnapshot = QuotaSnapshot(
                    current: 250,
                    other: 14,
                    remaining: 36,
                    total: 300,
                    updatedAt: Date()
                )
            } else if isOrbQAPreview {
                quotaSnapshot = QuotaSnapshot(
                    current: 87.57,
                    other: 22.09,
                    remaining: 190.34,
                    total: 300,
                    updatedAt: Date()
                )
            } else {
                quotaSnapshot = QuotaSnapshot(
                    current: 87.57,
                    other: 3.24,
                    remaining: 209.19,
                    total: 300,
                    updatedAt: Date()
                )
            }
        }

        for (model, sample) in zip(ModelDefinition.monitored, samples) {
            widgetView.updateModel(id: model.id, presentation: sample)
        }
        let available = samples.filter { $0.phase == .online }.count
        widgetView.updateAggregate(available: available, total: 4, hasResults: samples.contains { $0.phase != .unknown })
        widgetView.updateFooter(date: Date(), maskedKey: "••••A8F2")
        if let quotaSnapshot {
            widgetView.showQuota(quotaSnapshot)
        } else {
            widgetView.showQuotaEmpty()
        }
        let presentations = Dictionary(uniqueKeysWithValues: zip(ModelDefinition.monitored.map(\.id), samples))
        orbView.update(presentations: presentations, quota: quotaSnapshot)
        orbInfoView.update(presentations: presentations, quota: quotaSnapshot)
        let orbAvailable = samples[0].phase == .online ? 1 : 0
        statusMenuItem.title = currentMode == .orb ? "\(orbAvailable) / 1 可用" : "3 / 4 可用"
        statusItem.button?.title = " \(orbStatusText(samples[0]))"

        if arguments.contains("--qa-orb-hover") {
            showOrbInfo()
        }
    }

    private func captureQAPreview() {
        let view = currentMode == .orb ? orbView as NSView : widgetView as NSView
        view.layoutSubtreeIfNeeded()
        let filename: String
        if isMinimumQAPreview {
            filename = "model-status-view-minimum.png"
        } else if arguments.contains("--qa-orb-hover") {
            filename = "model-status-orb-hover.png"
        } else if arguments.contains("--qa-orb-low") {
            filename = "model-status-orb-low.png"
        } else if arguments.contains("--qa-orb-empty") {
            filename = "model-status-orb-empty.png"
        } else if arguments.contains("--qa-orb-interrupted") {
            filename = "model-status-orb-interrupted.png"
        } else if arguments.contains("--qa-orb-failed") {
            filename = "model-status-orb-failed.png"
        } else if isOrbQAPreview {
            filename = "model-status-orb.png"
        } else {
            filename = "model-status-view.png"
        }
        capture(view: view, filename: filename)
        if arguments.contains("--qa-orb-hover") {
            capture(view: orbInfoView, filename: "model-status-orb-hover-info.png")
        }
        NSApp.terminate(nil)
    }

    private func capture(view: NSView, filename: String) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("ModelStatus QA capture failed: bitmap allocation")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            NSLog("ModelStatus QA capture failed: PNG encoding")
            return
        }
        let output = URL(fileURLWithPath: "/private/tmp/\(filename)")
        do {
            try data.write(to: output, options: .atomic)
            NSLog("ModelStatus QA capture: %@", output.path)
        } catch {
            NSLog("ModelStatus QA capture failed: %@", error.localizedDescription)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        quotaTask?.cancel()
        probeTasks.values.forEach { $0.cancel() }
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingFrame, notification.object as? NSWindow === panel else { return }
        saveCurrentFrame()
        if currentMode == .orb, orbInfoPanel.isVisible { positionOrbInfo() }
    }

    func windowDidResize(_ notification: Notification) {
        guard !isApplyingFrame, currentMode == .detail, notification.object as? NSWindow === panel else { return }
        saveCurrentFrame()
    }

    private func buildWidget() {
        panel = DesktopPanel(
            contentRect: NSRect(origin: .zero, size: currentMode == .orb ? AppConfig.orbSize : AppConfig.defaultSize),
            styleMask: currentMode == .orb ? [.borderless] : [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = AppConfig.appName
        panel.appearance = NSAppearance(named: .aqua)
        panel.isFloatingPanel = false
        panel.level = AppConfig.desktopLevel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.delegate = self

        widgetView = StatusWidgetView(frame: NSRect(origin: .zero, size: AppConfig.defaultSize))
        widgetView.setBackgroundAlpha(backgroundAlpha)
        widgetView.onRefresh = { [weak self] in self?.refreshNow() }
        widgetView.onCollapse = { [weak self] in self?.switchMode(to: .orb) }
        widgetView.onMenu = { [weak self] source in self?.showActionMenu(from: source) }
        widgetView.onDragEnded = { [weak self] in self?.saveCurrentFrame() }

        orbView = OrbWidgetView(frame: NSRect(origin: .zero, size: AppConfig.orbSize))
        orbView.setBackgroundAlpha(backgroundAlpha)
        orbView.onOpenDetail = { [weak self] in self?.switchMode(to: .detail) }
        orbView.onHoverChanged = { [weak self] hovering in
            hovering ? self?.showOrbInfo() : self?.hideOrbInfo()
        }
        orbView.onDragEnded = { [weak self] in self?.saveCurrentFrame() }

        orbInfoView = OrbInfoView(frame: NSRect(origin: .zero, size: AppConfig.orbInfoSize))
        orbInfoView.setBackgroundAlpha(backgroundAlpha)
        orbInfoPanel = DesktopPanel(
            contentRect: NSRect(origin: .zero, size: AppConfig.orbInfoSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        orbInfoPanel.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        orbInfoPanel.isOpaque = false
        orbInfoPanel.backgroundColor = .clear
        orbInfoPanel.hasShadow = true
        orbInfoPanel.ignoresMouseEvents = true
        orbInfoPanel.hidesOnDeactivate = false
        orbInfoPanel.isReleasedWhenClosed = false
        orbInfoPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        orbInfoPanel.contentView = orbInfoView

        applyModeFrame(currentMode, preserveCenter: false)
    }

    private func applyModeFrame(_ mode: WidgetMode, preserveCenter: Bool) {
        hideOrbInfo()
        let oldCenter = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let storedFrame = loadFrame(for: mode)
        let size: NSSize
        if mode == .orb {
            panel.level = .floating
            panel.isFloatingPanel = true
            orbInfoPanel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            size = AppConfig.orbSize
            panel.styleMask = [.borderless]
            panel.minSize = AppConfig.orbSize
            panel.contentMinSize = AppConfig.orbSize
            panel.contentMaxSize = AppConfig.orbSize
            panel.showsResizeIndicator = false
            panel.contentView = orbView
        } else {
            panel.level = AppConfig.desktopLevel
            panel.isFloatingPanel = false
            orbInfoPanel.level = NSWindow.Level(rawValue: AppConfig.desktopLevel.rawValue + 1)
            size = storedFrame.map { NSSize(width: max($0.width, AppConfig.minimumSize.width), height: max($0.height, AppConfig.minimumSize.height)) } ?? AppConfig.defaultSize
            panel.styleMask = [.borderless, .resizable]
            panel.minSize = AppConfig.minimumSize
            panel.contentMinSize = AppConfig.minimumSize
            panel.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            panel.showsResizeIndicator = true
            panel.contentView = widgetView
        }

        var frame: NSRect
        if preserveCenter {
            frame = NSRect(x: oldCenter.x - size.width / 2, y: oldCenter.y - size.height / 2, width: size.width, height: size.height)
        } else if let storedFrame {
            frame = NSRect(origin: storedFrame.origin, size: size)
        } else {
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            frame = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        }
        frame = constrainedFrame(frame)
        isApplyingFrame = true
        panel.setFrame(frame, display: true)
        isApplyingFrame = false
        updateVisibilityMenuTitle()
    }

    private func switchMode(to mode: WidgetMode) {
        guard mode != currentMode else { return }
        saveCurrentFrame()
        let previous = currentMode
        currentMode = mode
        applyModeFrame(mode, preserveCenter: true)
        saveCurrentFrame()
        updateAggregateAndMenu()

        if mode == .detail, !isPaused, panel.isVisible {
            refreshProbes(models: ModelDefinition.monitored)
        } else if previous == .detail {
            ModelDefinition.detailOnlyModels.forEach { cancelProbe(for: $0.id) }
        }
        updateStatusDisplay()
    }

    private func configureStatusItem() {
        let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let sampleWidth = (" 9.9s" as NSString).size(withAttributes: [.font: statusFont]).width
        let compactLength = ceil(16 + 4 + sampleWidth + 8)
        statusItem = NSStatusBar.system.statusItem(withLength: compactLength)
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: AppConfig.appName)
            button.image?.isTemplate = true
            button.title = " --"
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.font = statusFont
            button.alignment = .left
            button.toolTip = AppConfig.appName
        }

        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "等待检测", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        visibilityMenuItem = menu.addItem(withTitle: "", action: #selector(toggleWidget), keyEquivalent: "")
        visibilityMenuItem.target = self
        updateVisibilityMenuTitle()
        let configureKey = menu.addItem(withTitle: "配置 API Key...", action: #selector(configureAPIKey), keyEquivalent: "k")
        configureKey.target = self
        menu.addItem(.separator())

        alphaSliderView = AlphaSliderMenuView(alpha: backgroundAlpha)
        alphaSliderView.onChange = { [weak self] alpha in self?.setBackgroundAlpha(alpha) }
        let alphaItem = NSMenuItem()
        alphaItem.view = alphaSliderView
        menu.addItem(alphaItem)

        refreshIntervalMenuView = RefreshIntervalMenuView(interval: selectedRefreshInterval)
        refreshIntervalMenuView.onChange = { [weak self] interval in self?.setRefreshInterval(interval) }
        let refreshIntervalItem = NSMenuItem()
        refreshIntervalItem.view = refreshIntervalMenuView
        menu.addItem(refreshIntervalItem)
        menu.addItem(.separator())

        let about = menu.addItem(withTitle: "关于", action: #selector(showAbout), keyEquivalent: "")
        about.target = self

        let checkUpdate = menu.addItem(withTitle: "检查更新...", action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
        checkUpdate.target = self

        let quit = menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        statusItem.menu = menu
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.2.4"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "12"
        let sourceURL = URL(string: "https://github.com/\(AppConfig.githubRepository)")!
        let credits = NSMutableAttributedString(string: "源码：")
        credits.append(NSAttributedString(
            string: sourceURL.absoluteString,
            attributes: [
                .link: sourceURL,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        ))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppConfig.appName,
            .applicationVersion: version,
            .version: "构建号 \(build)",
            .credits: credits
        ])
    }

    @objc private func checkForUpdatesFromMenu() {
        checkForUpdates(manual: true)
    }

    private func checkForUpdates(manual: Bool) {
        guard !isCheckingForUpdates else { return }
        guard let url = URL(string: "https://api.github.com/repos/\(AppConfig.githubRepository)/releases/latest") else { return }
        isCheckingForUpdates = true
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("model-status-updater", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCheckingForUpdates = false
                guard error == nil,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let data,
                      let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                    if manual { self.showAlert(title: "检查更新失败", message: "暂时无法读取 GitHub Release。") }
                    return
                }
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
                let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                guard self.isVersion(latest, newerThan: current) else {
                    if manual { self.showAlert(title: "已是最新版本", message: "当前版本为 \(current)。") }
                    return
                }
                self.presentUpdate(release: release, version: latest)
            }
        }.resume()
    }

    private func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let right = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private func presentUpdate(release: GitHubRelease, version: String) {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "intel"
        #endif
        guard let package = release.assets.first(where: { $0.name.hasSuffix("-\(architecture).zip") && !$0.name.contains("-adhoc") }),
              let checksums = release.assets.first(where: { $0.name == "SHA256SUMS" }) else {
            showAlert(title: "更新包不完整", message: "Release 中缺少当前架构安装包或 SHA256SUMS。")
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(version)"
        let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        alert.informativeText = notes.isEmpty ? "是否下载、校验并安装更新？" : String(notes.prefix(1_200))
        alert.addButton(withTitle: "安装更新")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "查看发布页")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            downloadUpdate(package: package, checksums: checksums, version: version)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.htmlURL)
        default:
            break
        }
    }

    private func downloadUpdate(package: GitHubRelease.Asset, checksums: GitHubRelease.Asset, version: String) {
        var checksumRequest = URLRequest(url: checksums.browserDownloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        checksumRequest.setValue("model-status-updater", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: checksumRequest) { [weak self] checksumData, checksumResponse, checksumError in
            guard let self,
                  checksumError == nil,
                  let checksumHTTP = checksumResponse as? HTTPURLResponse,
                  (200..<300).contains(checksumHTTP.statusCode),
                  let checksumData,
                  let checksumText = String(data: checksumData, encoding: .utf8),
                  let expectedHash = self.expectedHash(for: package.name, in: checksumText) else {
                DispatchQueue.main.async { self?.showAlert(title: "更新校验失败", message: "无法读取 Release 校验文件。") }
                return
            }
            var packageRequest = URLRequest(url: package.browserDownloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
            packageRequest.setValue("model-status-updater", forHTTPHeaderField: "User-Agent")
            URLSession.shared.downloadTask(with: packageRequest) { [weak self] location, response, error in
                guard let self,
                      error == nil,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let location,
                      let data = try? Data(contentsOf: location),
                      self.sha256(data) == expectedHash else {
                    DispatchQueue.main.async { self?.showAlert(title: "更新校验失败", message: "下载文件与 GitHub Release 的 SHA-256 不一致。") }
                    return
                }
                self.prepareUpdate(packageData: data, expectedVersion: version, downloadURL: package.browserDownloadURL)
            }.resume()
        }.resume()
    }

    private func expectedHash(for filename: String, in checksumText: String) -> String? {
        for line in checksumText.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { continue }
            let path = String(parts.last!)
            if URL(fileURLWithPath: path).lastPathComponent == filename {
                return String(parts[0]).lowercased()
            }
        }
        return nil
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func prepareUpdate(packageData: Data, expectedVersion: String, downloadURL: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-status-update-\(UUID().uuidString)", isDirectory: true)
            let archive = root.appendingPathComponent("update.zip")
            let extracted = root.appendingPathComponent("extracted", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
                try packageData.write(to: archive, options: .atomic)
                guard self.runTool("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extracted.path]),
                      let appURL = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
                        .first(where: { $0.pathExtension == "app" }),
                      let bundle = Bundle(url: appURL),
                      bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion,
                      self.runTool("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", appURL.path]) else {
                    throw NSError(domain: "ModelStatusUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "更新包结构或代码签名无效。"])
                }
                DispatchQueue.main.async {
                    self.installPreparedUpdate(appURL, fallbackDownloadURL: downloadURL)
                }
            } catch {
                try? FileManager.default.removeItem(at: root)
                DispatchQueue.main.async {
                    self.showAlert(title: "安装更新失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func runTool(_ executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func installPreparedUpdate(_ updateAppURL: URL, fallbackDownloadURL: URL) {
        let currentAppURL = Bundle.main.bundleURL
        let parent = currentAppURL.deletingLastPathComponent()
        let targetAppURL = parent.appendingPathComponent("\(AppConfig.appName).app", isDirectory: true)
        guard currentAppURL.pathExtension == "app",
              !currentAppURL.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: parent.path),
              currentAppURL == targetAppURL || !FileManager.default.fileExists(atPath: targetAppURL.path) else {
            NSWorkspace.shared.open(fallbackDownloadURL)
            showAlert(title: "需要手动安装", message: "当前应用位置无法直接替换，已打开下载地址。请退出应用后手动覆盖旧版本。")
            return
        }

        let installerScript = """
        set -eu
        current="$1"
        target="$2"
        source="$3"
        pid="$4"
        while /bin/kill -0 "$pid" 2>/dev/null; do /bin/sleep 0.2; done
        backup="${current}.update-backup"
        /bin/rm -rf "$backup"
        /bin/mv "$current" "$backup"
        if /bin/mv "$source" "$target"; then
          /bin/rm -rf "$backup"
          /usr/bin/open "$target"
        else
          /bin/mv "$backup" "$current"
          exit 1
        fi
        """
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/zsh")
        installer.arguments = [
            "-c", installerScript, "model-status-updater",
            currentAppURL.path, targetAppURL.path, updateAppURL.path,
            String(ProcessInfo.processInfo.processIdentifier)
        ]
        installer.standardOutput = FileHandle.nullDevice
        installer.standardError = FileHandle.nullDevice
        do {
            try installer.run()
            NSApp.terminate(nil)
        } catch {
            showAlert(title: "安装更新失败", message: "无法启动更新替换程序。")
        }
    }

    @objc private func refreshAll() {
        performRefresh(forceProbes: false)
    }

    private func refreshNow() {
        performRefresh(forceProbes: true)
    }

    private func performRefresh(forceProbes: Bool) {
        guard !isPaused else { return }
        refreshQuota()
        let models = currentMode == .detail && panel.isVisible
            ? ModelDefinition.monitored
            : ModelDefinition.orbModels
        refreshProbes(models: models, force: forceProbes)
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard !isPaused else { return }
        refreshTimer = Timer.scheduledTimer(
            timeInterval: selectedRefreshInterval,
            target: self,
            selector: #selector(refreshAll),
            userInfo: nil,
            repeats: true
        )
    }

    private func setRefreshInterval(_ interval: TimeInterval) {
        guard AppConfig.allowedRefreshIntervals.contains(interval) else { return }
        UserDefaults.standard.set(interval, forKey: AppConfig.refreshIntervalKey)
        if !isQAPreview { scheduleRefreshTimer() }
    }

    private func configureSessionNotifications() {
        guard !isQAPreview else { return }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(sessionDidLock(_:)),
            name: AppConfig.screenLockedNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(sessionDidUnlock(_:)),
            name: AppConfig.screenUnlockedNotification,
            object: nil
        )
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionDidLock(_:)),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionDidUnlock(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    @objc private func sessionDidLock(_ notification: Notification) {
        pause(for: .session)
    }

    @objc private func sessionDidUnlock(_ notification: Notification) {
        resume(from: .session, wakeDelay: 0)
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        pause(for: .systemSleep)
    }

    @objc private func systemDidWake(_ notification: Notification) {
        resume(from: .systemSleep, wakeDelay: 2)
    }

    private func pause(for reason: PauseReason) {
        wakeGeneration = UUID()
        let wasPaused = isPaused
        pauseReasons.insert(reason)
        guard !wasPaused else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
        quotaTask?.cancel()
        quotaTask = nil
        probeTasks.values.forEach { $0.cancel() }
        probeTasks.removeAll()
        probeGenerations.removeAll()
        widgetView.setRefreshing(false)
    }

    private func resume(from reason: PauseReason, wakeDelay: TimeInterval) {
        guard pauseReasons.remove(reason) != nil, !isPaused else { return }
        let generation = UUID()
        wakeGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + wakeDelay) { [weak self] in
            guard let self, self.wakeGeneration == generation, !self.isPaused else { return }
            self.refreshAll()
            self.scheduleRefreshTimer()
        }
    }

    private func refreshProbes(models: [ModelDefinition], force: Bool = false) {
        guard !isPaused else { return }
        guard let apiKey, !apiKey.isEmpty else {
            probeTasks.values.forEach { $0.cancel() }
            probeTasks.removeAll()
            probeGenerations.removeAll()
            widgetView.setRefreshing(false)
            updateAggregateAndMenu()
            return
        }

        for model in models {
            if !force, let backoff = probeBackoffs[model.id], backoff.nextAllowedAt > Date() {
                continue
            }
            cancelProbe(for: model.id)
            let generation = UUID()
            probeGenerations[model.id] = generation
            var request = URLRequest(
                url: AppConfig.probeURL,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: AppConfig.probeTimeout
            )
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            request.setValue("model-status/\(appVersion)", forHTTPHeaderField: "User-Agent")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model.id,
                "input": "仅回复 OK",
                "reasoning": ["effort": "low"],
                "max_output_tokens": 32,
                "store": false
            ])

            let started = DispatchTime.now().uptimeNanoseconds
            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                let statusCode = (response as? HTTPURLResponse)?.statusCode
                let success = error == nil && data != nil && statusCode.map { (200..<300).contains($0) } == true
                DispatchQueue.main.async {
                    guard let self, self.probeGenerations[model.id] == generation else { return }
                    self.probeTasks.removeValue(forKey: model.id)
                    self.probeGenerations.removeValue(forKey: model.id)
                    self.updateProbeBackoff(modelID: model.id, succeeded: success)
                    self.recordProbeResult(model: model, isOnline: success, latencyMilliseconds: success ? elapsed : nil)
                    self.widgetView.setRefreshing(!self.probeTasks.isEmpty)
                    self.updateAggregateAndMenu()
                }
            }
            probeTasks[model.id] = task
            task.resume()
        }
        widgetView.setRefreshing(!probeTasks.isEmpty)
    }

    private func cancelProbe(for modelID: String) {
        probeTasks.removeValue(forKey: modelID)?.cancel()
        probeGenerations.removeValue(forKey: modelID)
        widgetView?.setRefreshing(!probeTasks.isEmpty)
    }

    private func updateProbeBackoff(modelID: String, succeeded: Bool) {
        if succeeded {
            if probeBackoffs.removeValue(forKey: modelID) != nil {
                saveProbeBackoffs()
            }
            return
        }
        let failures = (probeBackoffs[modelID]?.consecutiveFailures ?? 0) + 1
        let delayIndex = min(failures - 1, AppConfig.probeBackoffDelays.count - 1)
        probeBackoffs[modelID] = ProbeBackoffState(
            consecutiveFailures: failures,
            nextAllowedAt: Date().addingTimeInterval(AppConfig.probeBackoffDelays[delayIndex])
        )
        saveProbeBackoffs()
    }

    private func recordProbeResult(model: ModelDefinition, isOnline: Bool, latencyMilliseconds: Int?) {
        let now = Date()
        if var entry = histories[model.id] {
            if entry.isOnline != isOnline {
                entry.previousOppositeDuration = max(now.timeIntervalSince(entry.statusStartedAt), 0)
                entry.statusStartedAt = now
                entry.isOnline = isOnline
            }
            entry.lastLatencyMilliseconds = latencyMilliseconds
            entry.lastCheckedAt = now
            histories[model.id] = entry
        } else {
            histories[model.id] = ProbeHistoryEntry(
                isOnline: isOnline,
                statusStartedAt: now,
                previousOppositeDuration: nil,
                lastLatencyMilliseconds: latencyMilliseconds,
                lastCheckedAt: now
            )
        }
        saveHistories()
        renderModel(model)
        widgetView.updateFooter(date: latestCheckedAt(), maskedKey: maskedAPIKey(apiKey))
        updateOrbAndInfo()
    }

    private func renderPersistedState() {
        for model in ModelDefinition.monitored { renderModel(model) }
        widgetView.updateFooter(date: latestCheckedAt(), maskedKey: maskedAPIKey(apiKey))
        updateOrbAndInfo()
        updateAggregateAndMenu()
    }

    private func presentation(for model: ModelDefinition) -> ProbePresentation {
        guard let entry = histories[model.id] else {
            return ProbePresentation(phase: .unknown, latencyMilliseconds: nil, previousOppositeDuration: nil, hasRecentInterruption: false)
        }
        let statusAge = Date().timeIntervalSince(entry.statusStartedAt)
        let hasRecentInterruption = entry.isOnline
            && entry.previousOppositeDuration != nil
            && statusAge >= 0
            && statusAge <= AppConfig.stabilityWindow
        return ProbePresentation(
            phase: entry.isOnline ? .online : .failed,
            latencyMilliseconds: entry.lastLatencyMilliseconds,
            previousOppositeDuration: entry.previousOppositeDuration,
            hasRecentInterruption: hasRecentInterruption
        )
    }

    private func renderModel(_ model: ModelDefinition) {
        widgetView.updateModel(id: model.id, presentation: presentation(for: model))
    }

    private func updateOrbAndInfo() {
        let values = Dictionary(uniqueKeysWithValues: ModelDefinition.orbModels.map { ($0.id, presentation(for: $0)) })
        orbView.update(presentations: values, quota: quotaSnapshot)
        orbInfoView.update(presentations: values, quota: quotaSnapshot)
    }

    private func updateAggregateAndMenu() {
        let allEntries = ModelDefinition.monitored.compactMap { histories[$0.id] }
        let allAvailable = allEntries.filter(\.isOnline).count
        widgetView.updateAggregate(
            available: allAvailable,
            total: ModelDefinition.monitored.count,
            hasResults: !allEntries.isEmpty
        )

        let scope = currentMode == .orb ? ModelDefinition.orbModels : ModelDefinition.monitored
        let scopedEntries = scope.compactMap { histories[$0.id] }
        let scopedAvailable = scopedEntries.filter(\.isOnline).count
        statusMenuItem?.title = scopedEntries.isEmpty ? "等待检测" : "\(scopedAvailable) / \(scope.count) 可用"
        updateStatusDisplay()
    }

    private func updateStatusDisplay() {
        let model = ModelDefinition.orbModel
        let summary: String
        if let entry = histories[model.id] {
            summary = entry.isOnline ? formatStatusLatency(entry.lastLatencyMilliseconds ?? 0) : "失败"
        } else {
            summary = "--"
        }
        statusItem?.button?.title = " \(summary)"
        let detail = histories[model.id].map {
            $0.isOnline ? formatLatency($0.lastLatencyMilliseconds ?? 0) : "失败"
        } ?? "--"
        statusItem?.button?.toolTip = "\(model.name)：\(detail)"
    }

    private func refreshQuota() {
        guard let apiKey, !apiKey.isEmpty else {
            quotaSnapshot = nil
            widgetView.showQuotaEmpty()
            widgetView.updateFooter(date: latestCheckedAt(), maskedKey: nil)
            updateOrbAndInfo()
            return
        }
        if quotaSnapshot == nil {
            widgetView.showQuotaLoading()
        }
        quotaTask?.cancel()

        var components = URLComponents(url: AppConfig.usageURL, resolvingAgainstBaseURL: false)!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let today = Date()
        components.queryItems = [
            URLQueryItem(name: "start_date", value: formatter.string(from: today)),
            URLQueryItem(name: "end_date", value: formatter.string(from: today)),
            URLQueryItem(name: "days", value: "1"),
            URLQueryItem(name: "timezone", value: TimeZone.current.identifier)
        ]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let masked = maskedAPIKey(apiKey)
        quotaTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.widgetView.updateFooter(date: self.latestCheckedAt(), maskedKey: masked)
                if let error = error as NSError?, error.code == NSURLErrorCancelled { return }
                if error != nil {
                    if self.quotaSnapshot == nil {
                        self.widgetView.showQuotaError("额度查询失败")
                    }
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let data,
                      let decoded = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
                    let status = (response as? HTTPURLResponse)?.statusCode
                    if self.quotaSnapshot == nil {
                        self.widgetView.showQuotaError(status == 401 || status == 403 ? "Key 无效或无权限" : "额度响应异常")
                    }
                    return
                }
                let snapshot = QuotaSnapshot(response: decoded)
                self.quotaSnapshot = snapshot
                self.widgetView.showQuota(snapshot)
                self.updateOrbAndInfo()
            }
        }
        quotaTask?.resume()
    }

    @objc private func configureAPIKey() {
        NSApp.activate(ignoringOtherApps: true)
        let existingKey = apiKey
        let alert = NSAlert()
        alert.messageText = "配置 API Key"
        if let masked = maskedAPIKey(existingKey) {
            alert.informativeText = "已配置 \(masked)。输入新 Key 可替换，留空则保留现有 Key。"
        } else {
            alert.informativeText = "Key 仅保存在 macOS 钥匙串中，用于额度查询与模型检测。"
        }
        alert.addButton(withTitle: "保存并检测")
        alert.addButton(withTitle: "删除 Key")
        alert.addButton(withTitle: "取消")
        alert.buttons[1].isEnabled = existingKey != nil

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 56))
        let keyLabel = NSTextField(labelWithString: "API Key")
        keyLabel.frame = NSRect(x: 0, y: 38, width: 420, height: 18)
        keyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        accessory.addSubview(keyLabel)

        let field = NSSecureTextField(string: "")
        field.placeholderString = existingKey == nil ? "输入完整 API Key" : "输入新 Key（留空保留）"
        field.frame = NSRect(x: 0, y: 8, width: 420, height: 24)
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        accessory.addSubview(field)

        alert.accessoryView = accessory

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            removeAPIKey()
            return
        case .alertFirstButtonReturn:
            break
        default:
            return
        }

        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty, existingKey != nil {
            refreshAll()
            return
        }
        guard value.count >= 8 else {
            showAlert(title: "Key 无效", message: "请输入完整的 API Key。")
            return
        }
        guard KeychainStore.saveAPIKey(value) else {
            showAlert(title: "保存失败", message: "无法写入 macOS 钥匙串。")
            return
        }
        apiKey = value
        widgetView.updateFooter(date: latestCheckedAt(), maskedKey: maskedAPIKey(value))
        refreshAll()
    }

    private func removeAPIKey() {
        KeychainStore.deleteAPIKey()
        apiKey = nil
        quotaSnapshot = nil
        quotaTask?.cancel()
        probeTasks.values.forEach { $0.cancel() }
        probeTasks.removeAll()
        probeGenerations.removeAll()
        widgetView.setRefreshing(false)
        widgetView.showQuotaEmpty()
        widgetView.updateFooter(date: latestCheckedAt(), maskedKey: nil)
        updateOrbAndInfo()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func showActionMenu(from source: NSView) {
        statusItem.menu?.popUp(positioning: nil, at: NSPoint(x: source.bounds.maxX, y: source.bounds.minY), in: source)
    }

    @objc private func toggleWidget() {
        if panel.isVisible {
            hideOrbInfo()
            panel.orderOut(nil)
            if currentMode == .detail {
                ModelDefinition.detailOnlyModels.forEach { cancelProbe(for: $0.id) }
            }
        } else {
            panel.orderFrontRegardless()
            if currentMode == .detail, !isPaused {
                refreshProbes(models: ModelDefinition.monitored)
            }
        }
        updateVisibilityMenuTitle()
    }

    private func updateVisibilityMenuTitle() {
        guard let visibilityMenuItem else { return }
        let surface = currentMode == .orb ? "悬浮球" : "状态面板"
        visibilityMenuItem.title = panel?.isVisible == false ? "显示\(surface)" : "隐藏\(surface)"
    }

    private func showOrbInfo() {
        guard currentMode == .orb, panel.isVisible else { return }
        updateOrbAndInfo()
        positionOrbInfo()
        orbInfoPanel.orderFrontRegardless()
    }

    private func hideOrbInfo() {
        orbInfoPanel?.orderOut(nil)
    }

    private func positionOrbInfo() {
        let orbFrame = panel.frame
        let screen = NSScreen.screens.first { $0.frame.intersects(orbFrame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(
            x: orbFrame.midX - AppConfig.orbInfoSize.width / 2,
            y: orbFrame.minY - AppConfig.orbInfoSize.height - 5
        )
        if origin.y < visible.minY + 6 {
            origin.y = orbFrame.maxY + 5
        }
        origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - AppConfig.orbInfoSize.width - 6)
        origin.y = min(max(origin.y, visible.minY + 6), visible.maxY - AppConfig.orbInfoSize.height - 6)
        orbInfoPanel.setFrameOrigin(origin)
    }

    private func setBackgroundAlpha(_ alpha: CGFloat) {
        UserDefaults.standard.set(Double(alpha), forKey: AppConfig.backgroundAlphaKey)
        widgetView.setBackgroundAlpha(alpha)
        orbView.setBackgroundAlpha(alpha)
        orbInfoView.setBackgroundAlpha(alpha)
    }

    private func saveCurrentFrame() {
        guard panel != nil else { return }
        let key = currentMode == .orb ? AppConfig.orbFrameKey : AppConfig.detailFrameKey
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: key)
    }

    private func loadFrame(for mode: WidgetMode) -> NSRect? {
        let key = mode == .orb ? AppConfig.orbFrameKey : AppConfig.detailFrameKey
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        let frame = NSRectFromString(raw)
        return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    private func constrainedFrame(_ frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return frame }
        var adjusted = frame
        adjusted.origin.x = min(max(adjusted.origin.x, visible.minX + 6), visible.maxX - adjusted.width - 6)
        adjusted.origin.y = min(max(adjusted.origin.y, visible.minY + 6), visible.maxY - adjusted.height - 6)
        return adjusted
    }

    private func loadHistories() -> [String: ProbeHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: AppConfig.probeHistoryKey),
              let value = try? JSONDecoder().decode([String: ProbeHistoryEntry].self, from: data) else {
            return [:]
        }
        return value
    }

    private func saveHistories() {
        guard let data = try? JSONEncoder().encode(histories) else { return }
        UserDefaults.standard.set(data, forKey: AppConfig.probeHistoryKey)
    }

    private func loadProbeBackoffs() -> [String: ProbeBackoffState] {
        guard let data = UserDefaults.standard.data(forKey: AppConfig.probeBackoffKey),
              let value = try? JSONDecoder().decode([String: ProbeBackoffState].self, from: data) else {
            return [:]
        }
        return value.filter { $0.value.nextAllowedAt > Date() }
    }

    private func saveProbeBackoffs() {
        guard let data = try? JSONEncoder().encode(probeBackoffs) else { return }
        UserDefaults.standard.set(data, forKey: AppConfig.probeBackoffKey)
    }

    private func latestCheckedAt() -> Date? {
        histories.values.map(\.lastCheckedAt).max()
    }

    private func maskedAPIKey(_ key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        guard key.count > 8 else { return "••••" }
        return "••••\(key.suffix(4))"
    }
}

private func formatLatency(_ milliseconds: Int) -> String {
    if milliseconds >= 1_000 {
        return String(format: "%.1f s", Double(milliseconds) / 1_000)
    }
    return "\(milliseconds) ms"
}

private func formatStatusLatency(_ milliseconds: Int) -> String {
    if milliseconds >= 10_000 { return ">9s" }
    return String(format: "%.1fs", Double(milliseconds) / 1_000)
}

private func formatDuration(_ interval: TimeInterval) -> String {
    let totalMinutes = max(Int(interval / 60), 0)
    if totalMinutes < 1 { return "<1m" }
    if totalMinutes < 60 { return "\(totalMinutes)m" }
    if totalMinutes < 1_440 {
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h\(minutes)m"
    }
    let days = totalMinutes / 1_440
    let hours = (totalMinutes % 1_440) / 60
    return hours == 0 ? "\(days)d" : "\(days)d\(hours)h"
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

@main
enum ModelStatusMain {
    private static let appDelegate = AppDelegate()

    static func main() {
        terminateOtherInstances()
        let application = NSApplication.shared
        application.delegate = appDelegate
        application.run()
    }

    private static func terminateOtherInstances() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: "im.input.model-status"
        ).filter { $0.processIdentifier != currentPID }

        for application in others { application.terminate() }
        if !others.isEmpty {
            Thread.sleep(forTimeInterval: 0.15)
            for application in others where !application.isTerminated { application.forceTerminate() }
        }
    }
}
