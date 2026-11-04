import AppKit
import CoreGraphics
import QuartzCore

private final class MenuCanvas: NSView {
    override var isFlipped: Bool { true }
}

private final class MenuActionButton: NSButton {
    override var isFlipped: Bool { true }

    init(frame: NSRect, label: String, target: AnyObject, action: Selector) {
        super.init(frame: frame)
        title = ""
        alternateTitle = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        self.target = target
        self.action = action
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}

private final class MenuIconBadge: NSView {
    private let glyph = NSImageView()
    var isActive = false {
        didSet { updateAppearance() }
    }

    init(symbolName: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        glyph.frame = bounds
        glyph.image = ProfileSymbols.centeredImage(named: symbolName)
        glyph.imageAlignment = .alignCenter
        glyph.imageScaling = .scaleNone
        addSubview(glyph)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        glyph.contentTintColor = isActive ? .white : .labelColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        (isActive ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.15)).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

final class MenuBarPanelViewController: NSViewController {
    private struct ProfileRow: Equatable {
        var id: UUID
        var name: String
        var iconName: String
    }

    private enum LightingOption: CaseIterable {
        case solid, rainbow, off
    }

    private let store: ProfileStore
    private let engine: AmbilightEngine
    private let updater: UpdateChecker
    private let onSelectProfile: (UUID) -> Void
    private let onBrightnessChanged: (Int) -> Void
    private let onStart: () -> Void
    private let onStopHost: () -> Void
    private let onRainbow: () -> Void
    private let onSolidColor: () -> Void
    private let onLightsOff: () -> Void
    private let onReturnDefaults: () -> Void
    private let onPermissionHelp: () -> Void
    private let onSettings: () -> Void
    private let onOpenLog: () -> Void
    private let onQuit: () -> Void
    private let onDownloadUpdate: () -> Void
    private let onCheckForUpdates: () -> Void

    private let brightnessSlider = NSSlider(frame: NSRect(x: 45, y: 35, width: 204, height: 16))
    private var canvas: MenuCanvas!
    private var renderedProfiles: [ProfileRow] = []
    private var profileButtons: [UUID: MenuActionButton] = [:]
    private var profileBadges: [UUID: MenuIconBadge] = [:]
    private var optionBadges: [LightingOption: MenuIconBadge] = [:]
    private var optionButtons: [LightingOption: MenuActionButton] = [:]
    private var previewState: AmbilightEngine.State = .running("Profile")
    private var settingsButton: MenuActionButton!
    private var renderedUpdate: AvailableUpdate?

    private var isPreview: Bool { CommandLine.arguments.contains("--menu-preview") }
    private var usesGlass: Bool { !CommandLine.arguments.contains("--classic-menu") }

    init(
        store: ProfileStore,
        engine: AmbilightEngine,
        updater: UpdateChecker,
        onSelectProfile: @escaping (UUID) -> Void,
        onBrightnessChanged: @escaping (Int) -> Void,
        onStart: @escaping () -> Void,
        onStopHost: @escaping () -> Void,
        onRainbow: @escaping () -> Void,
        onSolidColor: @escaping () -> Void,
        onLightsOff: @escaping () -> Void,
        onReturnDefaults: @escaping () -> Void,
        onPermissionHelp: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onOpenLog: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onDownloadUpdate: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void
    ) {
        self.store = store
        self.engine = engine
        self.updater = updater
        self.onSelectProfile = onSelectProfile
        self.onBrightnessChanged = onBrightnessChanged
        self.onStart = onStart
        self.onStopHost = onStopHost
        self.onRainbow = onRainbow
        self.onSolidColor = onSolidColor
        self.onLightsOff = onLightsOff
        self.onReturnDefaults = onReturnDefaults
        self.onPermissionHelp = onPermissionHelp
        self.onSettings = onSettings
        self.onOpenLog = onOpenLog
        self.onQuit = onQuit
        self.onDownloadUpdate = onDownloadUpdate
        self.onCheckForUpdates = onCheckForUpdates
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = menuSize()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported")
    }

    override func loadView() {
        let bounds = NSRect(origin: .zero, size: menuSize())
        canvas = MenuCanvas(frame: bounds)
        if #available(macOS 26.0, *), usesGlass {
            let container = NSGlassEffectContainerView(frame: bounds)
            container.spacing = 0
            container.contentView = canvas
            view = container
        } else {
            view = canvas
        }

        rebuildLayout()
        refresh()
    }

    private var profileListHeight: CGFloat {
        CGFloat(min(5, max(1, store.profiles.count))) * 72 - 8
    }

    private var updateOffset: CGFloat { updater.availableUpdate == nil ? 0 : 78 }

    private var optionsY: CGFloat { 84 + profileListHeight + 8 + updateOffset }

    private func menuSize() -> NSSize {
        NSSize(width: 318, height: optionsY + 153)
    }

    private func rebuildLayout() {
        renderedProfiles = store.profiles.map { ProfileRow(id: $0.id, name: $0.name, iconName: $0.iconName) }
        renderedUpdate = updater.availableUpdate
        canvas.subviews.forEach { $0.removeFromSuperview() }
        profileButtons.removeAll()
        profileBadges.removeAll()
        optionBadges.removeAll()
        optionButtons.removeAll()
        let size = menuSize()
        preferredContentSize = size
        view.setFrameSize(size)
        canvas.setFrameSize(size)

        if let update = updater.availableUpdate {
            let content = MenuCanvas(frame: NSRect(x: 0, y: 0, width: 294, height: 70))
            let title = label("New update available!", frame: NSRect(x: 16, y: 12, width: 262, height: 14))
            title.textColor = .white
            content.addSubview(title)
            let download = NSButton(title: "Download", target: self, action: #selector(downloadUpdatePressed))
            download.frame = NSRect(x: 16, y: 34, width: 76, height: 25)
            download.bezelStyle = .rounded
            download.controlSize = .small
            download.font = .systemFont(ofSize: 12, weight: .bold)
            download.bezelColor = .controlAccentColor
            download.contentTintColor = .white
            download.attributedTitle = NSAttributedString(string: "Download", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white
            ])
            if #available(macOS 26.0, *) { download.borderShape = .capsule }
            download.toolTip = "Open macEvnia \(update.version) on GitHub"
            content.addSubview(download)
            let skip = MenuActionButton(frame: NSRect(x: 238, y: 34, width: 40, height: 25), label: "Skip", target: self, action: #selector(skipUpdatePressed))
            let skipTitle = label("Skip", frame: NSRect(x: 0, y: 5.5, width: 40, height: 14))
            skipTitle.textColor = .white
            skipTitle.alignment = .center
            skip.addSubview(skipTitle)
            skip.toolTip = "Skip Version \(update.version)"
            content.addSubview(skip)
            canvas.addSubview(glass(frame: NSRect(x: 12, y: 12, width: 294, height: 70), radius: 24, content: content, tint: .controlAccentColor))
        }

        let brightness = MenuCanvas(frame: NSRect(x: 0, y: 0, width: 294, height: 64))
        brightness.addSubview(label("Screen Brightness", frame: NSRect(x: 16, y: 12, width: 200, height: 14)))
        brightness.addSubview(symbol("sun.min.fill", frame: NSRect(x: 16, y: 33, width: 19, height: 19), size: 15))
        brightness.addSubview(symbol("sun.max.fill", frame: NSRect(x: 258, y: 33, width: 20, height: 19), size: 16))
        brightnessSlider.minValue = 0
        brightnessSlider.maxValue = 100
        brightnessSlider.controlSize = .mini
        if #available(macOS 26.0, *) { brightnessSlider.tintProminence = .none }
        brightnessSlider.isContinuous = true
        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessChanged(_:))
        brightnessSlider.setAccessibilityLabel("Screen Brightness")
        brightness.addSubview(brightnessSlider)
        canvas.addSubview(glass(frame: NSRect(x: 12, y: 12 + updateOffset, width: 294, height: 64), radius: 24, content: brightness))

        let profilesCanvas = MenuCanvas(frame: NSRect(x: 0, y: 0, width: 294, height: max(64, CGFloat(store.profiles.count) * 72 - 8)))
        for (index, profile) in store.profiles.enumerated() {
            let button = MenuActionButton(frame: NSRect(x: 0, y: 0, width: 294, height: 64), label: profile.name, target: self, action: #selector(activateProfile(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(profile.id.uuidString)
            let badge = MenuIconBadge(symbolName: profile.iconName)
            badge.setFrameOrigin(NSPoint(x: 14, y: 14))
            button.addSubview(badge)
            let name = label(profile.name, frame: NSRect(x: 64, y: 25, width: 210, height: 14))
            name.lineBreakMode = .byTruncatingTail
            button.addSubview(name)
            profileButtons[profile.id] = button
            profileBadges[profile.id] = badge
            profilesCanvas.addSubview(glass(frame: NSRect(x: 0, y: CGFloat(index) * 72, width: 294, height: 64), radius: 32, content: button))
        }
        let profilesScroll = NSScrollView(frame: NSRect(x: 12, y: 84 + updateOffset, width: 294, height: profileListHeight))
        profilesScroll.drawsBackground = false
        profilesScroll.borderType = .noBorder
        profilesScroll.hasVerticalScroller = store.profiles.count > 5
        profilesScroll.scrollerStyle = .overlay
        profilesScroll.autohidesScrollers = true
        profilesScroll.documentView = profilesCanvas
        canvas.addSubview(profilesScroll)

        let options = MenuCanvas(frame: NSRect(x: 0, y: 0, width: 294, height: 108))
        options.addSubview(label("Ambiglow Options", frame: NSRect(x: 16, y: 12, width: 200, height: 14)))
        options.addSubview(actionButton("Solid Color", symbolName: "record.circle", option: .solid, x: 17, action: #selector(solidColorPressed)))
        options.addSubview(actionButton("Rainbow", symbolName: "rainbow", option: .rainbow, x: 106, action: #selector(rainbowPressed)))
        options.addSubview(actionButton("Lights off", symbolName: "circle.slash", option: .off, x: 195, action: #selector(lightsOffPressed)))
        canvas.addSubview(glass(frame: NSRect(x: 12, y: optionsY, width: 294, height: 108), radius: 24, content: options))

        settingsButton = MenuActionButton(frame: NSRect(x: 0, y: 0, width: 67, height: 25), label: "Settings", target: self, action: #selector(settingsPressed))
        let settingsTitle = label("Settings", frame: NSRect(x: 0, y: 5.5, width: 67, height: 14))
        settingsTitle.alignment = .center
        settingsButton.addSubview(settingsTitle)
        canvas.addSubview(glass(frame: NSRect(x: 125.5, y: optionsY + 116, width: 67, height: 25), radius: 12.5, content: settingsButton))
    }

    func refresh() {
        guard isViewLoaded else { return }
        let rows = store.profiles.map { ProfileRow(id: $0.id, name: $0.name, iconName: $0.iconName) }
        if rows != renderedProfiles || renderedUpdate != updater.availableUpdate { rebuildLayout() }
        let profile = store.selectedProfile
        let preview = isPreview
        let state = preview ? previewState : engine.state
        brightnessSlider.doubleValue = preview ? 30 : Double(ScreenBrightness.lastKnown(for: profile))
        brightnessSlider.isEnabled = preview || ScreenBrightness.isAvailable(for: profile)
        brightnessSlider.alphaValue = brightnessSlider.isEnabled ? 1 : 0.45
        brightnessSlider.needsDisplay = true
        for entry in store.profiles {
            let running: Bool
            if case .running = state { running = entry.id == store.selectedProfileID } else { running = false }
            profileBadges[entry.id]?.isActive = running
            profileButtons[entry.id]?.toolTip = running ? "Running: \(entry.name)" : "Apply & Start: \(entry.name)"
            profileButtons[entry.id]?.setAccessibilityValue(running ? "Active" : "Inactive")
        }
        let activeOption: LightingOption?
        switch state {
        case .solidColor: activeOption = .solid
        case .rainbow: activeOption = .rainbow
        case .lightsOff: activeOption = .off
        default: activeOption = nil
        }
        for option in LightingOption.allCases {
            optionBadges[option]?.isActive = option == activeOption
            optionButtons[option]?.setAccessibilityValue(option == activeOption ? "Active" : "Inactive")
        }
        settingsButton.menu = commandMenu()
    }

    func commandMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let versionItem = NSMenuItem(title: "macEvnia \(version)", action: nil, keyEquivalent: "")
        let stateItem = NSMenuItem(title: engine.state.title, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        stateItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(stateItem)
        menu.addItem(.separator())
        let check = menuItem(updater.isChecking ? "Checking for Updates..." : "Check for Updates...", action: #selector(checkForUpdatesPressed))
        check.isEnabled = !updater.isChecking
        menu.addItem(check)
        if let update = updater.availableUpdate {
            menu.addItem(menuItem("Download macEvnia \(update.version)...", action: #selector(downloadUpdatePressed)))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Apply & Start", action: #selector(startPressed)))
        menu.addItem(menuItem("Stop Host Ambilight", action: #selector(stopHostPressed)))
        menu.addItem(menuItem("Return Monitor Defaults", action: #selector(returnDefaultsPressed)))
        menu.addItem(.separator())
        if !CGPreflightScreenCaptureAccess() {
            menu.addItem(menuItem("Screen Recording Permission...", action: #selector(permissionPressed)))
        }
        menu.addItem(menuItem("Settings...", action: #selector(settingsPressed)))
        menu.addItem(menuItem("Open Log File", action: #selector(openLogPressed)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit macEvnia", action: #selector(quitPressed)))
        return menu
    }

    private func glass(frame: NSRect, radius: CGFloat, content: NSView, tint: NSColor? = nil) -> NSView {
        content.frame = NSRect(origin: .zero, size: frame.size)
        content.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *), usesGlass {
            let effect = NSGlassEffectView(frame: frame)
            effect.style = .regular
            effect.cornerRadius = radius
            effect.tintColor = tint
            effect.contentView = content
            return effect
        }
        let effect = NSVisualEffectView(frame: frame)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius
        effect.layer?.masksToBounds = true
        if let tint {
            content.wantsLayer = true
            content.layer?.backgroundColor = tint.withAlphaComponent(0.75).cgColor
        }
        effect.addSubview(content)
        return effect
    }

    private func label(_ text: String, frame: NSRect) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = frame
        field.font = .systemFont(ofSize: 12, weight: .bold)
        field.textColor = .labelColor
        field.lineBreakMode = .byClipping
        return field
    }

    private func symbol(_ name: String, frame: NSRect, size: CGFloat) -> NSImageView {
        let imageView = NSImageView(frame: frame)
        imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
        imageView.contentTintColor = .labelColor
        imageView.imageScaling = .scaleProportionallyDown
        return imageView
    }

    private func actionButton(_ title: String, symbolName: String, option: LightingOption, x: CGFloat, action: Selector) -> NSButton {
        let button = MenuActionButton(frame: NSRect(x: x, y: 38, width: 82, height: 56), label: title, target: self, action: action)
        let badge = MenuIconBadge(symbolName: symbolName)
        badge.setFrameOrigin(NSPoint(x: 23, y: 0))
        button.addSubview(badge)
        let titleField = label(title, frame: NSRect(x: 0, y: 40, width: 82, height: 14))
        titleField.alignment = .center
        button.addSubview(titleField)
        button.toolTip = title
        optionBadges[option] = badge
        optionButtons[option] = button
        return button
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        onBrightnessChanged(Int(sender.doubleValue.rounded()))
    }

    @objc private func activateProfile(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let id = UUID(uuidString: value) else { return }
        onSelectProfile(id)
        startPressed()
    }

    @objc private func startPressed() {
        if isPreview { previewState = .running(store.selectedProfile.name) }
        onStart()
        refresh()
    }
    @objc private func solidColorPressed() {
        if isPreview { previewState = .solidColor; refresh() } else { onSolidColor() }
    }
    @objc private func rainbowPressed() {
        if isPreview { previewState = .rainbow; refresh() } else { onRainbow() }
    }
    @objc private func lightsOffPressed() {
        if isPreview { previewState = .lightsOff; refresh() } else { onLightsOff() }
    }
    @objc private func settingsPressed() { onSettings() }
    @objc private func permissionPressed() { onPermissionHelp() }
    @objc private func stopHostPressed() {
        if isPreview { previewState = .stopped; refresh() } else { onStopHost() }
    }
    @objc private func returnDefaultsPressed() {
        if isPreview { previewState = .stopped; refresh() } else { onReturnDefaults() }
    }
    @objc private func openLogPressed() { onOpenLog() }
    @objc private func quitPressed() { onQuit() }
    @objc private func downloadUpdatePressed() { onDownloadUpdate() }
    @objc private func skipUpdatePressed() { updater.skipAvailableUpdate() }
    @objc private func checkForUpdatesPressed() { onCheckForUpdates() }
}

final class GlassMenuPanel: NSPanel {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private weak var statusButton: NSStatusBarButton?
    private(set) var isPresented = false
    private var transitionID = 0
    private let expandedScale: CGFloat = 1.035

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(controller: MenuBarPanelViewController) {
        super.init(contentRect: NSRect(origin: .zero, size: controller.preferredContentSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentViewController = controller
        controller.view.wantsLayer = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    func present(relativeTo button: NSStatusBarButton) {
        guard position(relativeTo: button) else { return }
        statusButton = button
        let wasVisible = isVisible
        isPresented = true
        if !wasVisible {
            alphaValue = 0
            contentView?.layer?.sublayerTransform = scaleTransform(expandedScale)
        }
        makeKeyAndOrderFront(nil)
        startDismissMonitors()
        animatePresentation(showing: true)
        DebugLog.write("Menu opening: frame=\(frame), gap=16pt")
    }

    func resizeToFitContent() {
        guard isPresented, let statusButton else { return }
        _ = position(relativeTo: statusButton)
    }

    private func position(relativeTo button: NSStatusBarButton) -> Bool {
        guard let buttonWindow = button.window else {
            DebugLog.write("Menu could not open: status item has no window")
            return false
        }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor
        let size = contentViewController?.preferredContentSize ?? NSSize(width: 318, height: 309)
        let x = min(max(anchor.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = max(visible.minY, anchor.minY - 16 + 12 - size.height)
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        return true
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        stopDismissMonitors()
        animatePresentation(showing: false)
        DebugLog.write("Menu closing")
    }

    private func scaleTransform(_ scale: CGFloat) -> CATransform3D {
        let size = contentView?.bounds.size ?? frame.size
        var transform = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -size.width / 2, -size.height / 2, 0)
    }

    private func animatePresentation(showing: Bool) {
        transitionID += 1
        let id = transitionID
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration: TimeInterval = reduceMotion ? 0.1 : (showing ? 0.22 : 0.18)
        let target = scaleTransform(showing || reduceMotion ? 1 : expandedScale)
        if let layer = contentView?.layer {
            let previous = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayerTransform = target
            CATransaction.commit()
            let animation = CABasicAnimation(keyPath: "sublayerTransform")
            animation.fromValue = NSValue(caTransform3D: reduceMotion ? target : previous)
            animation.toValue = NSValue(caTransform3D: target)
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.75, 0.25, 1)
            layer.add(animation, forKey: "menuScale")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = showing ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self, self.transitionID == id else { return }
            if !showing { self.orderOut(nil) }
        }
    }

    private func isOverStatusButton() -> Bool {
        guard let button = statusButton, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation)
    }

    private func startDismissMonitors() {
        stopDismissMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isOverStatusButton() else { return }
            self.dismiss()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.dismiss()
                return nil
            }
            if event.type != .keyDown, event.window !== self, !self.isOverStatusButton() {
                self.dismiss()
            }
            return event
        }
    }

    private func stopDismissMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    deinit {
        stopDismissMonitors()
    }
}

final class MenuBarPreviewWindowController: NSWindowController {
    init(controller: MenuBarPanelViewController, backgroundURL: URL?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 837, height: 810), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "macEvnia Menu Preview"
        let canvas = MenuCanvas(frame: NSRect(x: 0, y: 0, width: 837, height: 810))
        if let backgroundURL, let background = NSImage(contentsOf: backgroundURL) {
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 836, height: 810))
            imageView.image = background
            imageView.imageScaling = .scaleAxesIndependently
            canvas.addSubview(imageView)
        }
        controller.view.frame = NSRect(origin: NSPoint(x: 249, y: 30), size: controller.preferredContentSize)
        canvas.addSubview(controller.view)
        window.contentView = canvas
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported")
    }
}
