import AppKit

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
    private let migrationService = AppMigrationService()
    private let updateService = UpdateService()
    private let probeClient = ProbeClient()
    private let usageClient = UsageClient()

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
            || arguments.contains("--qa-orb-countdown")
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
        migrationService.offerIfNeeded(arguments: arguments, isQAPreview: isQAPreview)
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
                self?.updateService.check(manual: false)
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
        if arguments.contains("--qa-orb-countdown") {
            orbView.startRefreshCountdown(duration: 3_600, initialProgress: 0.5)
        }
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
        } else if arguments.contains("--qa-orb-countdown") {
            filename = "model-status-orb-countdown.png"
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
        updateService.check(manual: true)
    }

    @objc private func refreshAll() {
        performRefresh(forceProbes: false)
    }

    private func refreshNow() {
        performRefresh(forceProbes: true)
    }

    private func performRefresh(forceProbes: Bool) {
        guard !isPaused else { return }
        orbView.startRefreshCountdown(duration: selectedRefreshInterval)
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
        orbView.startRefreshCountdown(duration: selectedRefreshInterval)
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
        orbView.stopRefreshCountdown()
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
            let task = probeClient.makeTask(model: model, apiKey: apiKey) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.probeGenerations[model.id] == generation else { return }
                    self.probeTasks.removeValue(forKey: model.id)
                    self.probeGenerations.removeValue(forKey: model.id)
                    self.updateProbeBackoff(modelID: model.id, succeeded: result.succeeded)
                    self.recordProbeResult(
                        model: model,
                        isOnline: result.succeeded,
                        latencyMilliseconds: result.latencyMilliseconds
                    )
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

        let masked = maskedAPIKey(apiKey)
        quotaTask = usageClient.makeTask(apiKey: apiKey) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                self.widgetView.updateFooter(date: self.latestCheckedAt(), maskedKey: masked)
                switch result {
                case .success(let decoded):
                    let snapshot = QuotaSnapshot(response: decoded)
                    self.quotaSnapshot = snapshot
                    self.widgetView.showQuota(snapshot)
                    self.updateOrbAndInfo()
                case .failure(.cancelled):
                    return
                case .failure(let error):
                    if self.quotaSnapshot == nil {
                        let message = error == .unauthorized ? "Key 无效或无权限"
                            : error == .invalidResponse ? "额度响应异常"
                            : "额度查询失败"
                        self.widgetView.showQuotaError(message)
                    }
                }
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
