import AppKit
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
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ProfileStore()
    private let engine = AmbilightEngine()
    private var statusItem: NSStatusItem!
    private var preferencesWindow: PreferencesWindowController!
    private var solidColor = NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1)
    private var resumeWorkItems: [DispatchWorkItem] = []
    private let lampWatcher = LampArrayWatcher()
    private var pendingWakeResume = false
    private let brightnessQueue = DispatchQueue(label: "macevnia.brightness", qos: .userInitiated)
    private let brightnessLock = NSLock()
    private var pendingBrightness: (value: Int, profile: AmbilightProfile)?
    private var brightnessWriting = false

    private static let resumeRetryDelays: [TimeInterval] = [0.5, 1.5, 3.0, 6.0, 12.0, 24.0, 45.0]

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.write("App launched. Log file: \(DebugLog.fileURL.path)")
        DebugLog.write("Displays at launch: \(DisplayCatalog.summary())")
        preferencesWindow = PreferencesWindowController(store: store, engine: engine)
        setupStatusItem()
        observeSystemResumeEvents()
        observeDisplayConfigurationChanges()

        store.onChange = { [weak self] in
            self?.rebuildMenu()
            if let profile = self?.store.selectedProfile {
                self?.engine.update(profile: profile)
            }
        }

        engine.onStateChange = { [weak self] state in
            self?.updateStatusIcon()
            self?.rebuildMenu()
            self?.preferencesWindow.updateState(state)
            if case .running = state {
                self?.pendingWakeResume = false
                self?.cancelResumeAttempts()
            }
        }

        lampWatcher.onAttach = { [weak self] in
            self?.handleLampArrayAttach()
        }
        lampWatcher.onDetach = { [weak self] in
            self?.handleLampArrayDetach()
        }

        if store.selectedProfile.autoStart {
            DebugLog.write("Auto-starting selected profile '\(store.selectedProfile.name)'")
            engine.start(profile: store.selectedProfile)
        }
    }

    private func handleLampArrayAttach() {
        ScreenBrightness.invalidate(reason: "LampArray attached")
        rebuildMenu()
        guard pendingWakeResume || engine.wantsScreenCaptureResume else { return }
        pendingWakeResume = true
        DebugLog.write("LampArray (re)attached — scheduling resume. displays=\(DisplayCatalog.summary())")
        scheduleResumeAttempts(forceRestart: true)
    }

    private func handleLampArrayDetach() {
        ScreenBrightness.invalidate(reason: "LampArray detached")
        // Mark a resume as pending so the *next* attach (e.g. monitor powering
        // back on after a screen-off / cable bounce that didn't go through a
        // full system sleep) drives us back to .running.
        if engine.isRunning || engine.wantsScreenCaptureResume {
            DebugLog.write("LampArray detached — arming attach-driven resume")
            pendingWakeResume = true
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.write("App terminating")
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
        if let button = statusItem.button {
            let bundledImage = Bundle.main.url(forResource: "menubar_light", withExtension: "png")
                .flatMap { NSImage(contentsOf: $0) }
            let image = bundledImage ?? NSImage(systemSymbolName: "lightbulb.led.fill", accessibilityDescription: "macEvnia")
            image?.isTemplate = false
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
            button.imagePosition = .imageLeading
            button.title = ""
            button.contentTintColor = nil
        }
        rebuildMenu()
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        DispatchQueue.main.async {
            guard let button = self.statusItem.button else { return }
            button.contentTintColor = nil
        }
    }

    private func rebuildMenu() {
        DispatchQueue.main.async {
            let menu = NSMenu()

            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
            let versionItem = NSMenuItem(title: "macEvnia \(version)", action: nil, keyEquivalent: "")
            versionItem.isEnabled = false
            menu.addItem(versionItem)

            let stateItem = NSMenuItem(title: self.engine.state.title, action: nil, keyEquivalent: "")
            stateItem.isEnabled = false
            menu.addItem(stateItem)
            menu.addItem(.separator())

            menu.addItem(NSMenuItem(title: "Start \(self.store.selectedProfile.name)", action: #selector(self.startSelectedProfile), keyEquivalent: "s", target: self))
            menu.addItem(NSMenuItem(title: "Rainbow", action: #selector(self.startRainbow), keyEquivalent: "r", target: self))
            menu.addItem(NSMenuItem(title: "Solid Color...", action: #selector(self.openSolidColorPanel), keyEquivalent: "c", target: self))
            menu.addItem(NSMenuItem(title: "Lights Off", action: #selector(self.turnLightsOff), keyEquivalent: "", target: self))
            menu.addItem(.separator())
            menu.addItem(self.makeScreenBrightnessMenuItem())
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Stop Host Ambilight", action: #selector(self.stopHostAmbilight), keyEquivalent: "", target: self))
            menu.addItem(NSMenuItem(title: "Return Monitor Defaults", action: #selector(self.returnMonitorDefaults), keyEquivalent: "d", target: self))
            menu.addItem(.separator())

            let profilesItem = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
            let profilesMenu = NSMenu()
            for profile in self.store.profiles {
                let item = NSMenuItem(title: profile.name, action: #selector(self.selectProfile(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = profile.id
                item.state = profile.id == self.store.selectedProfileID ? .on : .off
                profilesMenu.addItem(item)
            }
            profilesItem.submenu = profilesMenu
            menu.addItem(profilesItem)

            menu.addItem(NSMenuItem(title: "Settings...", action: #selector(self.openSettings), keyEquivalent: ",", target: self))
            menu.addItem(NSMenuItem(title: "Open Log File", action: #selector(self.openLogFile), keyEquivalent: "l", target: self))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Quit", action: #selector(self.quit), keyEquivalent: "q", target: self))

            self.statusItem.menu = menu
        }
    }

    @objc private func startSelectedProfile() {
        engine.start(profile: store.selectedProfile)
    }

    @objc private func systemWillPause(_ notification: Notification) {
        ScreenBrightness.invalidate(reason: "system pause \(notification.name.rawValue)")
        cancelResumeAttempts()
        pendingWakeResume = true
        engine.prepareForSystemPause(profile: store.selectedProfile)
    }

    @objc private func systemDidResume(_ notification: Notification) {
        DebugLog.write("System resume signal: \(notification.name.rawValue)")
        ScreenBrightness.invalidate(reason: "system resume \(notification.name.rawValue)")
        pendingWakeResume = true
        scheduleResumeAttempts(forceRestart: true)
    }

    @objc private func displayConfigurationChanged(_ notification: Notification) {
        DebugLog.write("Display configuration changed: \(DisplayCatalog.summary())")
        ScreenBrightness.invalidate(reason: "display configuration changed")
        preferencesWindow.reloadDisplayList()
        rebuildMenu()
        guard pendingWakeResume || engine.isRunning || engine.wantsScreenCaptureResume else { return }
        pendingWakeResume = true
        scheduleResumeAttempts(forceRestart: true)
    }

    private func scheduleResumeAttempts(forceRestart: Bool) {
        cancelResumeAttempts()
        for delay in Self.resumeRetryDelays {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.pendingWakeResume else {
                    return
                }
                DebugLog.write("Resume attempt at +\(delay)s (state=\(self.engine.state.title), forceRestart=\(forceRestart), displays=\(DisplayCatalog.summary()))")
                self.engine.resumeAfterSystemWake(profile: self.store.selectedProfile, forceRestart: forceRestart)
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
        engine.startRainbow(profile: store.selectedProfile)
    }

    @objc private func openSolidColorPanel() {
        let panel = NSColorPanel.shared
        panel.color = solidColor
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(solidColorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        engine.setSolidColor(RGBColor(nsColor: solidColor), profile: store.selectedProfile)
    }

    @objc private func solidColorChanged(_ sender: NSColorPanel) {
        solidColor = sender.color
        engine.setSolidColor(RGBColor(nsColor: solidColor), profile: store.selectedProfile)
    }

    @objc private func turnLightsOff() {
        engine.turnLightsOff(profile: store.selectedProfile)
    }

    @objc private func stopHostAmbilight() {
        engine.stop(returnToAutonomous: false)
    }

    @objc private func returnMonitorDefaults() {
        engine.returnToMonitorDefaults()
    }

    @objc private func selectProfile(_ item: NSMenuItem) {
        if let id = item.representedObject as? UUID {
            store.select(id)
        }
    }

    @objc private func openSettings() {
        preferencesWindow.showWindow(nil)
    }

    @objc private func openLogFile() {
        DebugLog.write("Opening log file from menu")
        NSWorkspace.shared.open(DebugLog.fileURL)
    }

    @objc private func quit() {
        engine.stop(returnToAutonomous: true)
        NSApp.terminate(nil)
    }

    private func makeScreenBrightnessMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let width: CGFloat = 240
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 44))

        let profile = store.selectedProfile
        let available = ScreenBrightness.isAvailable(for: profile)
        let label = NSTextField(labelWithString: available ? "Screen Brightness" : "Screen Brightness (not available)")
        label.frame = NSRect(x: 14, y: 24, width: width - 28, height: 16)
        label.font = .menuFont(ofSize: 13)
        label.textColor = available ? .labelColor : .secondaryLabelColor
        container.addSubview(label)

        let slider = NSSlider(
            value: Double(ScreenBrightness.lastKnown(for: profile)),
            minValue: 0,
            maxValue: 100,
            target: self,
            action: #selector(screenBrightnessSliderChanged(_:))
        )
        slider.isContinuous = true
        slider.isEnabled = available
        slider.frame = NSRect(x: 14, y: 4, width: width - 28, height: 18)
        container.addSubview(slider)

        item.view = container
        return item
    }

    @objc private func screenBrightnessSliderChanged(_ sender: NSSlider) {
        let value = Int(sender.doubleValue.rounded())
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

private extension NSMenuItem {
    convenience init(title: String, action: Selector?, keyEquivalent: String, target: AnyObject?) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        self.target = target
    }
}
