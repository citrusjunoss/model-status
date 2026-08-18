import AppKit
import CoreGraphics

final class OrbWidgetView: NSView {
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

        let presentation = presentations[ModelDefinition.orbModel.id]
        let latencyText: String
        switch presentation?.phase {
        case .online:
            latencyText = formatGaugeLatency(presentation?.latencyMilliseconds ?? 0)
        case .failed:
            latencyText = "失败"
        case .unknown, nil:
            latencyText = "--"
        }
        drawCurvedLatencyText(
            latencyText,
            context: context,
            center: center,
            radius: 38.5,
            color: orbStatusColor(presentation)
        )
    }

    private func drawCurvedLatencyText(
        _ text: String,
        context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        color: NSColor
    ) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.3, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let glyphs = text.map { String($0) }
        let widths = glyphs.map { ($0 as NSString).size(withAttributes: attributes).width }
        let spacing: CGFloat = 0.35
        let totalWidth = widths.reduce(0, +) + spacing * CGFloat(max(glyphs.count - 1, 0))
        var offset = -totalWidth / 2

        for (glyph, width) in zip(glyphs, widths) {
            let arcOffset = offset + width / 2
            let degrees = 270 + arcOffset / radius * 180 / .pi
            let position = point(center: center, radius: radius, degrees: degrees)
            let size = (glyph as NSString).size(withAttributes: attributes)
            context.saveGState()
            context.translateBy(x: position.x, y: position.y)
            context.rotate(by: radians(degrees + 90))
            (glyph as NSString).draw(
                at: CGPoint(x: -size.width / 2, y: -size.height / 2),
                withAttributes: attributes
            )
            context.restoreGState()
            offset += width + spacing
        }
    }

    private func strokeCircle(_ context: CGContext, center: CGPoint, radius: CGFloat, width: CGFloat, color: NSColor) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}

final class OrbInfoView: NSView {
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

func orbStatusText(_ presentation: ProbePresentation?) -> String {
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
