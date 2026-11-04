import AppKit
import CoreGraphics
import Foundation

@main
struct macEvniaMain {
    static func main() {
        if CommandLine.arguments.contains("--probe") {
            do {
                let device = try LampArrayDevice()
                let attributes = try device.arrayAttributes()
                print("LampArray OK: lamps=\(attributes.lampCount), maxHz=\(String(format: "%.1f", attributes.maxUpdateHz))")
                exit(0)
            } catch {
                fputs("LampArray probe failed: \(error.localizedDescription)\n", stderr)
                exit(2)
            }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(CommandLine.arguments.contains("--menu-preview") ? .regular : .accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: ProfileStore = {
        if CommandLine.arguments.contains("--menu-preview") {
            var eco = AmbilightProfile.defaultProfile(name: "Eco Mode")
            eco.iconName = "battery.100"
            return ProfileStore(previewProfiles: [
                .defaultProfile(name: "Profile"),
                eco
            ])
        }
        return ProfileStore()
    }()
    private let engine = AmbilightEngine()
    private let updater: UpdateChecker = {
        if CommandLine.arguments.contains("--menu-preview") {
            let release = CommandLine.arguments.contains("--preview-update")
                ? GitHubRelease(tagName: "0.3.2", pageURL: URL(string: "https://github.com/funk4d/macEvnia/releases/tag/0.3.2")!, draft: false, prerelease: false)
                : nil
            return UpdateChecker(installedVersion: "0.3.1", defaults: nil, previewRelease: release)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return UpdateChecker(installedVersion: version)
    }()
    private var statusItem: NSStatusItem!
    private var updateBadgeView: MenuBarUpdateBadgeView?
    private var statusPanel: GlassMenuPanel?
    private var menuController: MenuBarPanelViewController!
    private var menuPreviewWindow: MenuBarPreviewWindowController?
    private var preferencesWindow: PreferencesWindowController!
    private var solidColor = NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1)
    private var resumeWorkItems: [DispatchWorkItem] = []
    private let lampWatcher = LampArrayWatcher()
    private var pendingWakeResume = false
    private var currentMode: PlaybackMode = PlaybackModeStore.load() {
        didSet {
            guard currentMode != oldValue else { return }
            PlaybackModeStore.save(currentMode)
            DebugLog.write("Playback mode → \(currentMode.debugDescription)")
        }
    }
    private let brightnessQueue = DispatchQueue(label: "macevnia.brightness", qos: .userInitiated)
    private let brightnessLock = NSLock()
    private var pendingBrightness: (value: Int, profile: AmbilightProfile)?
    private var brightnessWriting = false
    private var screenCapturePermissionResetAfterUpdate = false

    private static let resumeRetryDelays: [TimeInterval] = [0.5, 1.5, 3.0, 6.0, 12.0, 24.0, 45.0]
    private static let lastScreenCaptureBuildKey = "macevnia.screenCapture.lastBuild"
    private static let lastScreenCapturePermissionKey = "macevnia.screenCapture.lastGranted"

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.write("App launched. Log file: \(DebugLog.fileURL.path)")
        DebugLog.write("Displays at launch: \(DisplayCatalog.summary())")
        recordScreenCapturePermissionStatus()
        preferencesWindow = PreferencesWindowController(store: store, engine: engine)
        setupStatusItem()
        updater.onChange = { [weak self] in
            self?.updateStatusIcon()
            self?.refreshMenuPanel()
        }
        observeSystemResumeEvents()
        observeDisplayConfigurationChanges()

        store.onChange = { [weak self] in
            self?.refreshMenuPanel()
            if let profile = self?.store.selectedProfile {
                self?.engine.update(profile: profile)
            }
        }

        engine.onStateChange = { [weak self] state in
            self?.updateStatusIcon()
            self?.refreshMenuPanel()
            self?.preferencesWindow.updateState(state)
            switch state {
            case .running, .rainbow, .solidColor, .lightsOff:
                self?.pendingWakeResume = false
                self?.cancelResumeAttempts()
            default:
                break
            }
        }

        lampWatcher.onAttach = { [weak self] in
            self?.handleLampArrayAttach()
        }
        lampWatcher.onDetach = { [weak self] in
            self?.handleLampArrayDetach()
        }

        if !CommandLine.arguments.contains("--menu-preview") { updater.start() }

        if let menuPreviewWindow {
            menuPreviewWindow.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if CommandLine.arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, let button = self.statusItem.button else { return }
                self.menuController.refresh()
                self.statusPanel?.present(relativeTo: button)
            }
        } else {
            applyColdStartMode()
        }
    }

    private func applyColdStartMode() {
        let profile = store.selectedProfile
        let mode = currentMode
        DebugLog.write("Cold start: saved mode=\(mode.debugDescription), autoStart=\(profile.autoStart)")
        guard mode != .stopped, profile.autoStart else { return }
        DebugLog.write("Cold start: restoring saved mode \(mode.debugDescription)")
        if case .solid(let color) = mode {
            solidColor = color.nsColor
        }
        restoreCurrentMode(reason: "cold start")
    }

    private func restoreCurrentMode(reason: String) {
        let profile = store.selectedProfile
        DebugLog.write("Restore mode \(currentMode.debugDescription) — reason: \(reason)")
        switch currentMode {
        case .capture:
            engine.resumeAfterSystemWake(profile: profile, forceRestart: true)
        case .rainbow:
            engine.startRainbow(profile: profile)
        case .solid(let color):
            engine.setSolidColor(color, profile: profile)
        case .lightsOff:
            engine.turnLightsOff(profile: profile)
        case .stopped:
            break
        }
    }

    private func handleLampArrayAttach() {
        ScreenBrightness.invalidate(reason: "LampArray attached")
        refreshMenuPanel()
        // Only restore for modes the user actually chose; .stopped means they
        // explicitly turned host control off, so don't bring it back.
        guard currentMode != .stopped, pendingWakeResume || engine.wantsScreenCaptureResume else { return }
        pendingWakeResume = true
        DebugLog.write("LampArray (re)attached — scheduling resume. mode=\(currentMode.debugDescription) displays=\(DisplayCatalog.summary())")
        scheduleResumeAttempts(forceRestart: true)
    }

    private func handleLampArrayDetach() {
        ScreenBrightness.invalidate(reason: "LampArray detached")
        // Arm so the next attach (after a screen-off / cable bounce / wake that
        // didn't go through a full system sleep) drives us back to whatever
        // mode the user last chose.
        guard currentMode != .stopped else { return }
        DebugLog.write("LampArray detached — arming attach-driven resume (mode=\(currentMode.debugDescription))")
        pendingWakeResume = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.write("App terminating")
        updater.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        engine.stop(returnToAutonomous: true)
    }

    private func observeSystemResumeEvents() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(
            self,
            selector: #selector(systemWillPause(_:)),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(systemWillPause(_:)),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(systemWillPause(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(systemDidResume(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(systemDidResume(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(systemDidResume(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        let distributedCenter = DistributedNotificationCenter.default()
        distributedCenter.addObserver(
            self,
            selector: #selector(systemWillPause(_:)),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        distributedCenter.addObserver(
            self,
            selector: #selector(systemDidResume(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    private func observeDisplayConfigurationChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigurationChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menuController = MenuBarPanelViewController(
            store: store,
            engine: engine,
            updater: updater,
            onSelectProfile: { [weak self] id in self?.store.select(id) },
            onBrightnessChanged: { [weak self] value in self?.setScreenBrightness(value) },
            onStart: { [weak self] in self?.startSelectedProfile() },
            onStopHost: { [weak self] in self?.stopHostAmbilight() },
            onRainbow: { [weak self] in self?.startRainbow() },
            onSolidColor: { [weak self] in self?.openSolidColorPanel() },
            onLightsOff: { [weak self] in self?.turnLightsOff() },
            onReturnDefaults: { [weak self] in self?.returnMonitorDefaults() },
            onPermissionHelp: { [weak self] in self?.showScreenCapturePermissionHelp() },
            onSettings: { [weak self] in self?.openSettings() },
            onOpenLog: { [weak self] in self?.openLogFile() },
            onQuit: { [weak self] in self?.quit() },
            onDownloadUpdate: { [weak self] in self?.downloadUpdate() },
            onCheckForUpdates: { [weak self] in self?.checkForUpdates() }
        )
        if let previewIndex = CommandLine.arguments.firstIndex(of: "--menu-preview") {
            let backgroundPath = CommandLine.arguments.dropFirst(previewIndex + 1).first
            menuPreviewWindow = MenuBarPreviewWindowController(
                controller: menuController,
                backgroundURL: backgroundPath.map { URL(fileURLWithPath: $0) }
            )
        } else {
            statusPanel = GlassMenuPanel(controller: menuController)
        }

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.title = ""
            button.contentTintColor = nil
            button.setAccessibilityLabel("macEvnia")
            let badge = MenuBarUpdateBadgeView(frame: button.bounds)
            badge.autoresizingMask = [.width, .height]
            badge.setAccessibilityElement(false)
            button.addSubview(badge)
            updateBadgeView = badge
            button.target = self
            button.action = #selector(toggleMenuPanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refreshMenuPanel()
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let update = updater.availableUpdate
        let resource = "menubar-\(update == nil ? "" : "update-")\(dark ? "light" : "dark")"
        if let source = Bundle.main.url(forResource: resource, withExtension: "png").flatMap({ NSImage(contentsOf: $0) }) {
            button.image = MenuBarIcon.image(resource: resource, source: source, hasUpdate: update != nil)
            updateBadgeView?.sourceImage = source
        } else {
            let image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "macEvnia")
            image?.isTemplate = true
            image?.size = MenuBarIcon.size
            button.image = image
            updateBadgeView?.sourceImage = nil
        }
        updateBadgeView?.isHidden = update == nil
        button.toolTip = update.map { "macEvnia \($0.version) is available" } ?? "macEvnia"
        button.contentTintColor = nil
    }

    private func refreshMenuPanel() {
        DispatchQueue.main.async {
            self.menuController?.refresh()
            self.statusPanel?.resizeToFitContent()
        }
    }

    @objc private func toggleMenuPanel(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            closeMenuPanel()
            menuController.commandMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
            return
        }
        guard let statusPanel else {
            menuPreviewWindow?.showWindow(nil)
            return
        }
        if statusPanel.isPresented {
            statusPanel.dismiss()
        } else {
            updater.check()
            menuController.refresh()
            statusPanel.present(relativeTo: button)
        }
    }

    private func closeMenuPanel() {
        statusPanel?.dismiss()
    }

    private func downloadUpdate() {
        guard let update = updater.availableUpdate else { return }
        closeMenuPanel()
        let opened = NSWorkspace.shared.open(update.pageURL)
        DebugLog.write("Open GitHub release: \(update.pageURL), opened=\(opened)")
    }

    private func checkForUpdates() {
        closeMenuPanel()
        updater.check(force: true) { result in
            let alert = NSAlert()
            alert.alertStyle = .informational
            var releaseURL: URL?
            switch result {
            case .success(let update?):
                alert.messageText = "macEvnia \(update.version) Is Available"
                alert.informativeText = "Open the release page on GitHub to download the new version."
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                releaseURL = update.pageURL
            case .success(nil):
                alert.messageText = "You're Up to Date"
                alert.informativeText = "You have the latest stable version of macEvnia."
                alert.addButton(withTitle: "OK")
            case .failure(let error):
                alert.messageText = "Could Not Check for Updates"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
            }
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn, let releaseURL {
                NSWorkspace.shared.open(releaseURL)
            }
        }
    }

    private func recordScreenCapturePermissionStatus() {
        let defaults = UserDefaults.standard
        let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let previousBuild = defaults.string(forKey: Self.lastScreenCaptureBuildKey)
        let wasPreviouslyGranted = defaults.bool(forKey: Self.lastScreenCapturePermissionKey)
        let isGranted = CGPreflightScreenCaptureAccess()

        screenCapturePermissionResetAfterUpdate =
            !isGranted && wasPreviouslyGranted && previousBuild != nil && previousBuild != currentBuild

        if screenCapturePermissionResetAfterUpdate {
            DebugLog.write("Screen Recording permission is unavailable after app update: \(previousBuild ?? "unknown") -> \(currentBuild)")
        }

        defaults.set(currentBuild, forKey: Self.lastScreenCaptureBuildKey)
        defaults.set(isGranted, forKey: Self.lastScreenCapturePermissionKey)
    }

    @objc private func showScreenCapturePermissionHelp() {
        closeMenuPanel()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = screenCapturePermissionResetAfterUpdate
            ? "Screen Recording Permission Was Lost After Update"
            : "Screen Recording Permission Required"
        alert.informativeText = """
        macEvnia needs Screen Recording access for screen-follow Ambiglow.

        In System Settings > Privacy & Security > Screen Recording, remove an older macEvnia entry if one is listed, click +, and add the current app:
        \(Bundle.main.bundleURL.path)

        Quit and reopen macEvnia after changing the permission.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Show App in Finder")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        default:
            break
        }
    }

    @objc private func startSelectedProfile() {
        if CommandLine.arguments.contains("--menu-preview") {
            DebugLog.write("Menu preview applied profile '\(store.selectedProfile.name)' id=\(store.selectedProfile.id)")
            refreshMenuPanel()
            return
        }
        closeMenuPanel()
        currentMode = .capture
        engine.start(profile: store.selectedProfile)
    }

    @objc private func systemWillPause(_ notification: Notification) {
        ScreenBrightness.invalidate(reason: "system pause \(notification.name.rawValue)")
        cancelResumeAttempts()
        if currentMode != .stopped {
            pendingWakeResume = true
        }
        engine.prepareForSystemPause(profile: store.selectedProfile)
    }

    @objc private func systemDidResume(_ notification: Notification) {
        DebugLog.write("System resume signal: \(notification.name.rawValue)")
        ScreenBrightness.invalidate(reason: "system resume \(notification.name.rawValue)")
        guard currentMode != .stopped, store.selectedProfile.autoResumeAfterWake else {
            DebugLog.write("Skip resume: mode=\(currentMode.debugDescription), autoResume=\(store.selectedProfile.autoResumeAfterWake)")
            return
        }
        pendingWakeResume = true
        scheduleResumeAttempts(forceRestart: true)
    }

    @objc private func displayConfigurationChanged(_ notification: Notification) {
        DebugLog.write("Display configuration changed: \(DisplayCatalog.summary())")
        ScreenBrightness.invalidate(reason: "display configuration changed")
        preferencesWindow.reloadDisplayList()
        refreshMenuPanel()
        guard pendingWakeResume || engine.isRunning || engine.wantsScreenCaptureResume else { return }
        if currentMode == .stopped { return }
        pendingWakeResume = true
        scheduleResumeAttempts(forceRestart: true)
    }

    private func scheduleResumeAttempts(forceRestart: Bool) {
        cancelResumeAttempts()
        for delay in Self.resumeRetryDelays {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.pendingWakeResume else { return }
                guard self.currentMode != .stopped else { return }
                DebugLog.write("Resume attempt at +\(delay)s (state=\(self.engine.state.title), mode=\(self.currentMode.debugDescription), forceRestart=\(forceRestart), displays=\(DisplayCatalog.summary()))")
                self.restoreCurrentMode(reason: "retry +\(delay)s")
            }
            resumeWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func cancelResumeAttempts() {
        resumeWorkItems.forEach { $0.cancel() }
        resumeWorkItems = []
    }

    @objc private func startRainbow() {
        closeMenuPanel()
        currentMode = .rainbow
        engine.startRainbow(profile: store.selectedProfile)
    }

    @objc private func openSolidColorPanel() {
        closeMenuPanel()
        let panel = NSColorPanel.shared
        panel.color = solidColor
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(solidColorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let color = RGBColor(nsColor: solidColor)
        currentMode = .solid(color)
        engine.setSolidColor(color, profile: store.selectedProfile)
    }

    @objc private func solidColorChanged(_ sender: NSColorPanel) {
        solidColor = sender.color
        let color = RGBColor(nsColor: solidColor)
        currentMode = .solid(color)
        engine.setSolidColor(color, profile: store.selectedProfile)
    }

    @objc private func turnLightsOff() {
        closeMenuPanel()
        currentMode = .lightsOff
        engine.turnLightsOff(profile: store.selectedProfile)
    }

    @objc private func stopHostAmbilight() {
        closeMenuPanel()
        currentMode = .stopped
        cancelResumeAttempts()
        pendingWakeResume = false
        engine.stop(returnToAutonomous: false)
    }

    @objc private func returnMonitorDefaults() {
        closeMenuPanel()
        currentMode = .stopped
        cancelResumeAttempts()
        pendingWakeResume = false
        engine.returnToMonitorDefaults()
    }

    @objc private func openSettings() {
        closeMenuPanel()
        preferencesWindow.showWindow(nil)
    }

    @objc private func openLogFile() {
        closeMenuPanel()
        DebugLog.write("Opening log file from menu")
        NSWorkspace.shared.open(DebugLog.fileURL)
    }

    @objc private func quit() {
        closeMenuPanel()
        engine.stop(returnToAutonomous: true)
        NSApp.terminate(nil)
    }

    private func setScreenBrightness(_ value: Int) {
        if CommandLine.arguments.contains("--menu-preview") { return }
        let profile = store.selectedProfile
        brightnessLock.lock()
        pendingBrightness = (value, profile)
        let shouldStart = !brightnessWriting
        if shouldStart { brightnessWriting = true }
        brightnessLock.unlock()
        guard shouldStart else { return }
        brightnessQueue.async { [weak self] in
            self?.drainBrightnessWrites()
        }
    }

    private func drainBrightnessWrites() {
        while true {
            brightnessLock.lock()
            guard let next = pendingBrightness else {
                brightnessWriting = false
                brightnessLock.unlock()
                return
            }
            pendingBrightness = nil
            brightnessLock.unlock()

            ScreenBrightness.set(next.value, for: next.profile)
            // DDC/CI requires a settle gap between commands.
            usleep(50_000)
        }
    }
}
