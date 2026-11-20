import AppKit
import Foundation

final class PreferencesWindowController: NSWindowController,
                                         NSTableViewDataSource,
                                         NSTableViewDelegate,
                                         NSTextFieldDelegate,
                                         NSWindowDelegate,
                                         NSMenuItemValidation {
    private enum IconChoice: Equatable {
        case color, gradient, symbol(String)
    }

    private let store: ProfileStore
    private let engine: AmbilightEngine
    private let onBeginEditing: () -> Void
    private let onFinishEditing: (Bool, Bool) -> Void
    private let onStop: () -> Void
    private let onDeviceChange: () -> Void

    // Sidebar
    private let profileTable = NSTableView()
    private let newProfileButton = NSButton(title: "New profile", target: nil, action: nil)

    // Right area controls
    private let nameField = NSTextField()
    private let modePopup = NSPopUpButton()
    private let iconPopup = NSPopUpButton()
    private let iconColorWell = NSColorWell()
    private let solidColorWell = NSColorWell()
    private let musicDynamicSwitch = NSSwitch()
    private let musicColorWell = NSColorWell()
    private let bassColorWell = NSColorWell()
    private let midColorWell = NSColorWell()
    private let trebleColorWell = NSColorWell()
    private let musicSensitivitySlider = NSSlider(value: 1, minValue: 0.25, maxValue: 3, target: nil, action: nil)
    private let musicSensitivityValue = secondaryLabel()
    private let musicSmoothingSlider = NSSlider(value: 0.3, minValue: 0, maxValue: 0.9, target: nil, action: nil)
    private let musicSmoothingValue = secondaryLabel()
    private let musicBrightnessSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let musicBrightnessValue = secondaryLabel()
    private let gradientEditor = GradientEditorView(frame: .zero)
    private let gradientStartWell = NSColorWell()
    private let gradientEndWell = NSColorWell()
    private let animationPopup = NSPopUpButton()
    private let animationSpeedSlider = NSSlider(value: 5, minValue: 1, maxValue: 30, target: nil, action: nil)
    private let animationSpeedValue = secondaryLabel()
    private let addPaletteColorButton = NSButton()
    private var paletteColorWells: [NSColorWell] = []
    private var iconColorRow: NSView!
    private let followVideoSection = NSStackView()
    private let musicSection = NSStackView()
    private let musicBandColors = NSStackView()
    private var musicColorRow: NSView!
    private let solidSection = NSStackView()
    private let gradientSection = NSStackView()
    private let animationSection = NSStackView()
    private let paletteSection = NSStackView()
    private let displayPopup = NSPopUpButton()
    private let devicePopup = NSPopUpButton()
    private let fpsSlider = NSSlider(value: 30, minValue: 1, maxValue: 50, target: nil, action: nil)
    private let ledFPSSlider = NSSlider(value: 50, minValue: 1, maxValue: 50, target: nil, action: nil)
    private let screenshotQualitySlider = NSSlider(value: 50, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let brightnessSlider = NSSlider(value: 0.6, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let colorTemperatureSlider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let smoothingSlider = NSSlider(value: 0.3, minValue: 0, maxValue: 0.9, target: nil, action: nil)
    private let radiusSlider = NSSlider(value: 80, minValue: 1, maxValue: 500, target: nil, action: nil)
    private let autoStartSwitch = NSSwitch()
    private let autoResumeSwitch = NSSwitch()
    private let wallEnabledSwitch = NSSwitch()
    private let wallColorWell = NSColorWell()
    private let ledPopup = NSPopUpButton()
    private let ledSlider = NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil)
    private let ledTestButton = NSButton(title: "Test On", target: nil, action: nil)
    private let resetLedButton = NSButton(title: "Reset", target: nil, action: nil)

    private let fpsValue = secondaryLabel()
    private let ledFPSValue = secondaryLabel()
    private let screenshotQualityValue = secondaryLabel()
    private let brightnessValue = secondaryLabel()
    private let colorTemperatureValue = secondaryLabel()
    private let smoothingValue = secondaryLabel()
    private let radiusValue = secondaryLabel()
    private let ledValue = secondaryLabel()

    private let statusLabel = NSTextField(labelWithString: "Stopped")
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)

    private weak var rightScrollView: NSScrollView?

    private var isLEDTestOn = false
    private var updatingControls = false

    init(store: ProfileStore, engine: AmbilightEngine, onBeginEditing: @escaping () -> Void,
         onFinishEditing: @escaping (Bool, Bool) -> Void,
         onStop: @escaping () -> Void, onDeviceChange: @escaping () -> Void) {
        self.store = store
        self.engine = engine
        self.onBeginEditing = onBeginEditing
        self.onFinishEditing = onFinishEditing
        self.onStop = onStop
        self.onDeviceChange = onDeviceChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        if Bundle.main.bundleIdentifier == "local.macevnia.test",
           let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            window.title = "macEvnia \(version) Test"
        } else {
            window.title = "macEvnia"
        }
        window.minSize = NSSize(width: 780, height: 540)
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        reloadAll()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        beginEditing()
        reloadAll()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        // Reset the settings scroll back to the top every time the window opens.
        DispatchQueue.main.async { [weak self] in
            self?.scrollSettingsToTop()
        }
    }

    func beginEditing() {
        guard !store.isEditing else { return }
        store.beginEditing()
        LampArrayDeviceStore.beginEditing()
        onBeginEditing()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.endEditing(for: nil)
        commitNameEdit()
        guard store.isEditing else { return true }
        guard store.hasUnsavedChanges || LampArrayDeviceStore.hasUnsavedChanges else {
            return finishEditing(save: false)
        }
        let alert = NSAlert()
        alert.messageText = "Save changes?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        return finishEditing(save: alert.runModal() == .alertFirstButtonReturn)
    }

    private func finishEditing(save: Bool) -> Bool {
        let deviceChanged = LampArrayDeviceStore.hasUnsavedChanges
        if save {
            do {
                try store.commitEditing()
            } catch {
                NSAlert(error: error).runModal()
                return false
            }
        }
        endEditingModeControls()
        if !save { store.cancelEditing() }
        LampArrayDeviceStore.finishEditing(save: save)
        onFinishEditing(save, deviceChanged)
        return true
    }

    private func scrollSettingsToTop() {
        guard let scroll = rightScrollView, let documentView = scroll.documentView else { return }
        documentView.scroll(.zero)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func updateState(_ state: AmbilightEngine.State) {
        statusLabel.stringValue = state.title
        if case .testingLED = state {
            isLEDTestOn = true
        } else {
            isLEDTestOn = false
        }
        updateLEDTestButton()
    }

    func reloadDisplayList() {
        reloadDisplays()
        reloadDevices()
    }

    func selectProfileFromMenu(_ id: UUID) {
        guard id != store.selectedProfileID else { return }
        window?.endEditing(for: nil)
        endEditingModeControls()
        store.select(id)
        reloadAll()
        scrollSettingsToTop()
    }

    // MARK: - Layout

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        let sidebar = buildSidebar()
        let divider = NSBox()
        divider.boxType = .separator
        let rightArea = buildRightArea()

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        rightArea.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(sidebar)
        contentView.addSubview(divider)
        contentView.addSubview(rightArea)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 240),

            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: contentView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            rightArea.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            rightArea.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rightArea.topAnchor.constraint(equalTo: contentView.topAnchor),
            rightArea.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func buildSidebar() -> NSView {
        let container = NSView()
        let bg = NSVisualEffectView()
        bg.material = .sidebar
        bg.blendingMode = .behindWindow
        bg.state = .followsWindowActiveState
        bg.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bg)
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bg.topAnchor.constraint(equalTo: container.topAnchor),
            bg.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let header = NSTextField(labelWithString: "Profiles")
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)

        profileTable.style = .sourceList
        profileTable.allowsMultipleSelection = false
        profileTable.headerView = nil
        profileTable.backgroundColor = .clear
        profileTable.rowHeight = 30
        profileTable.intercellSpacing = NSSize(width: 0, height: 2)
        profileTable.dataSource = self
        profileTable.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        column.resizingMask = .autoresizingMask
        profileTable.addTableColumn(column)

        let contextMenu = NSMenu()
        let deleteItem = NSMenuItem(title: "Delete Profile", action: #selector(deleteProfileFromContext(_:)), keyEquivalent: "")
        deleteItem.target = self
        contextMenu.addItem(deleteItem)
        profileTable.menu = contextMenu

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.documentView = profileTable
        container.addSubview(scroll)

        newProfileButton.target = self
        newProfileButton.action = #selector(newProfile)
        newProfileButton.bezelStyle = .rounded
        newProfileButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(newProfileButton)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: newProfileButton.topAnchor, constant: -10),

            newProfileButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            newProfileButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])

        return container
    }

    private func buildRightArea() -> NSView {
        let container = NSView()

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        rightScrollView = scroll

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Flipped so the document's (0,0) is the top-left. Without this
        // NSStackView lays out from the bottom and NSScrollView opens scrolled
        // all the way down.
        let stackContainer = FlippedView()
        stackContainer.translatesAutoresizingMaskIntoConstraints = false
        stackContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: stackContainer.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: stackContainer.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: stackContainer.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: stackContainer.bottomAnchor, constant: -22),
        ])
        scroll.documentView = stackContainer
        NSLayoutConstraint.activate([
            stackContainer.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        wireActions()

        nameField.placeholderString = "Profile name"
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.alignment = .right
        nameField.delegate = self
        nameField.font = .systemFont(ofSize: 13)

        smoothingSlider.numberOfTickMarks = 10
        smoothingSlider.allowsTickMarkValuesOnly = true
        musicSmoothingSlider.numberOfTickMarks = 10
        musicSmoothingSlider.allowsTickMarkValuesOnly = true
        colorTemperatureSlider.numberOfTickMarks = 3
        colorTemperatureSlider.allowsTickMarkValuesOnly = false

        ledTestButton.bezelStyle = .rounded
        resetLedButton.bezelStyle = .rounded

        addRow(label: "Name", trailing: nameField, valueWidth: 220, to: stack)
        addSeparator(to: stack)
        fillPopup(modePopup, choices: ProfileMode.allCases.map { ($0.rawValue, $0.title) })
        addRow(label: "Mode", trailing: modePopup, valueWidth: 220, to: stack)
        addSeparator(to: stack)
        addRow(label: "Profile icon", trailing: iconPopup, valueWidth: 220, to: stack)
        iconColorRow = addRow(label: "Icon color", trailing: iconColorWell, valueWidth: 60, to: stack)
        addSeparator(to: stack)
        for section in [musicSection, solidSection, gradientSection, animationSection] {
            addSection(section, to: stack)
            addSectionSpace(to: section)
        }
        addRow(label: "Device", trailing: devicePopup, valueWidth: 260, to: stack)
        addSeparator(to: stack)
        addRow(label: "Auto-start with app", trailing: autoStartSwitch, valueWidth: nil, to: stack)
        addSeparator(to: stack)
        addRow(label: "Auto-resume after wake", trailing: autoResumeSwitch, valueWidth: nil, to: stack)
        addSection(followVideoSection, to: stack)
        addSectionSpace(to: followVideoSection)

        let follow = followVideoSection
        addRow(label: "Capture display", trailing: displayPopup, valueWidth: 260, to: follow)
        for (label, slider, value) in [
            ("Capture rate", fpsSlider, fpsValue), ("LED rate", ledFPSSlider, ledFPSValue),
            ("Screenshot quality", screenshotQualitySlider, screenshotQualityValue),
            ("Ambiglow brightness", brightnessSlider, brightnessValue),
            ("Color temperature", colorTemperatureSlider, colorTemperatureValue),
            ("Smoothing", smoothingSlider, smoothingValue), ("Sample radius", radiusSlider, radiusValue)
        ] {
            addSeparator(to: follow)
            addSliderRow(label: label, slider: slider, value: value, to: follow)
        }
        addSectionSpace(to: follow)
        addSectionTitle("Wall Color", to: follow)
        addRow(label: "Compensate wall color", trailing: wallEnabledSwitch, valueWidth: nil, to: follow)
        addSeparator(to: follow)
        addRow(label: "Wall color", trailing: wallColorWell, valueWidth: 60, to: follow)
        addSectionSpace(to: follow)
        addSectionTitle("LED Calibration", to: follow)
        addRow(label: "Selected LED", trailing: ledPopup, valueWidth: 160, to: follow)
        addSeparator(to: follow)
        addSliderRow(label: "LED brightness", slider: ledSlider, value: ledValue, to: follow)
        addSeparator(to: follow)
        let ledButtons = NSStackView(views: [resetLedButton, ledTestButton])
        ledButtons.orientation = .horizontal
        ledButtons.spacing = 8
        addRow(label: "Test single LED", trailing: ledButtons, valueWidth: nil, to: follow)

        addRow(label: "Color", trailing: solidColorWell, valueWidth: 60, to: solidSection)
        addSliderRow(label: "Sensitivity", slider: musicSensitivitySlider, value: musicSensitivityValue, to: musicSection)
        addSeparator(to: musicSection)
        addSliderRow(label: "Smoothing", slider: musicSmoothingSlider, value: musicSmoothingValue, to: musicSection)
        addSeparator(to: musicSection)
        addSliderRow(label: "Brightness", slider: musicBrightnessSlider, value: musicBrightnessValue, to: musicSection)
        addSeparator(to: musicSection)
        addRow(label: "Dynamic", trailing: musicDynamicSwitch, valueWidth: nil, to: musicSection)
        addSeparator(to: musicSection)
        musicColorRow = addRow(label: "Music color", trailing: musicColorWell, valueWidth: 60, to: musicSection)
        addSection(musicBandColors, to: musicSection)
        addRow(label: "Bass color", trailing: bassColorWell, valueWidth: 60, to: musicBandColors)
        addSeparator(to: musicBandColors)
        addRow(label: "Mid color", trailing: midColorWell, valueWidth: 60, to: musicBandColors)
        addSeparator(to: musicBandColors)
        addRow(label: "Treble color", trailing: trebleColorWell, valueWidth: 60, to: musicBandColors)
        let editorRow = NSView()
        editorRow.translatesAutoresizingMaskIntoConstraints = false
        gradientEditor.translatesAutoresizingMaskIntoConstraints = false
        editorRow.addSubview(gradientEditor)
        let gradientColors = NSStackView()
        gradientColors.orientation = .vertical
        gradientColors.alignment = .leading
        gradientColors.spacing = 0
        gradientColors.translatesAutoresizingMaskIntoConstraints = false
        editorRow.addSubview(gradientColors)
        addRow(label: "Start color", trailing: gradientStartWell, valueWidth: 60, to: gradientColors)
        addSeparator(to: gradientColors)
        addRow(label: "End color", trailing: gradientEndWell, valueWidth: 60, to: gradientColors)
        gradientSection.addArrangedSubview(editorRow)
        NSLayoutConstraint.activate([
            editorRow.widthAnchor.constraint(equalTo: gradientSection.widthAnchor),
            gradientEditor.topAnchor.constraint(equalTo: editorRow.topAnchor),
            gradientEditor.bottomAnchor.constraint(equalTo: editorRow.bottomAnchor),
            gradientEditor.leadingAnchor.constraint(equalTo: editorRow.leadingAnchor),
            gradientEditor.widthAnchor.constraint(equalToConstant: 244),
            gradientEditor.heightAnchor.constraint(equalTo: gradientEditor.widthAnchor),
            gradientColors.leadingAnchor.constraint(equalTo: gradientEditor.trailingAnchor, constant: 16),
            gradientColors.trailingAnchor.constraint(equalTo: editorRow.trailingAnchor),
            gradientColors.centerYAnchor.constraint(equalTo: editorRow.centerYAnchor),
        ])

        fillPopup(animationPopup, choices: RainbowAnimation.allCases.map { ($0.rawValue, $0.title) })
        addRow(label: "Animation type", trailing: animationPopup, valueWidth: 220, to: animationSection)
        addSeparator(to: animationSection)
        addSliderRow(label: "Cycle duration", slider: animationSpeedSlider, value: animationSpeedValue, to: animationSection)
        addSectionSpace(to: animationSection)
        configurePaletteButton(addPaletteColorButton, symbol: "plus", label: "Add Color", action: #selector(addPaletteColor))
        addRow(label: "Palette", trailing: addPaletteColorButton, valueWidth: nil, to: animationSection)
        addSection(paletteSection, to: animationSection)
        for section in [musicSection, solidSection, gradientSection, animationSection] { addSectionSpace(to: section) }

        // Bottom bar
        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        topSeparator.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)

        stopButton.target = self
        stopButton.action = #selector(stopProfile)
        stopButton.bezelStyle = .rounded

        applyButton.target = self
        applyButton.action = #selector(applySettings)
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelSettings)
        cancelButton.bezelStyle = .rounded

        let bottomBar = NSStackView()
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 10
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addArrangedSubview(statusLabel)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addArrangedSubview(spacer)
        bottomBar.addArrangedSubview(stopButton)
        bottomBar.addArrangedSubview(cancelButton)
        bottomBar.addArrangedSubview(applyButton)

        container.addSubview(scroll)
        container.addSubview(topSeparator)
        container.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: topSeparator.topAnchor, constant: -12),

            topSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topSeparator.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -12),

            bottomBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            bottomBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            bottomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

            spacer.heightAnchor.constraint(equalToConstant: 1),
        ])

        return container
    }

    private func wireActions() {
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        for well in [iconColorWell, solidColorWell, gradientStartWell, gradientEndWell] {
            well.target = self
            well.action = #selector(effectColorChanged(_:))
        }
        for well in [musicColorWell, bassColorWell, midColorWell, trebleColorWell] {
            well.target = self
            well.action = #selector(musicColorChanged(_:))
        }
        musicDynamicSwitch.target = self
        musicDynamicSwitch.action = #selector(musicDynamicChanged)
        musicSensitivitySlider.target = self
        musicSensitivitySlider.action = #selector(musicSensitivityChanged)
        musicSmoothingSlider.target = self
        musicSmoothingSlider.action = #selector(musicSmoothingChanged)
        musicBrightnessSlider.target = self
        musicBrightnessSlider.action = #selector(musicBrightnessChanged)
        gradientEditor.onChange = { [weak self] effect in
            guard let self, self.store.selectedProfile.mode == .gradientColor else { return }
            self.store.updateSelected { $0.gradient = effect }
            self.refreshIconSwatches(self.store.selectedProfile)
            if self.store.selectedProfile.iconStyle == .gradient { self.reloadProfileList() }
        }
        animationPopup.target = self
        animationPopup.action = #selector(animationChanged)
        animationSpeedSlider.target = self
        animationSpeedSlider.action = #selector(animationSpeedChanged)
        iconPopup.target = self
        iconPopup.action = #selector(iconChanged)
        displayPopup.target = self
        displayPopup.action = #selector(displayChanged)
        devicePopup.target = self
        devicePopup.action = #selector(deviceChanged)
        fpsSlider.target = self
        fpsSlider.action = #selector(fpsChanged)
        ledFPSSlider.target = self
        ledFPSSlider.action = #selector(ledFPSChanged)
        screenshotQualitySlider.target = self
        screenshotQualitySlider.action = #selector(screenshotQualityChanged)
        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessChanged)
        colorTemperatureSlider.target = self
        colorTemperatureSlider.action = #selector(colorTemperatureChanged)
        smoothingSlider.target = self
        smoothingSlider.action = #selector(smoothingChanged)
        radiusSlider.target = self
        radiusSlider.action = #selector(radiusChanged)
        autoStartSwitch.target = self
        autoStartSwitch.action = #selector(toggleChanged)
        autoResumeSwitch.target = self
        autoResumeSwitch.action = #selector(experimentalChanged)
        wallEnabledSwitch.target = self
        wallEnabledSwitch.action = #selector(toggleChanged)
        wallColorWell.target = self
        wallColorWell.action = #selector(wallColorChanged)
        ledPopup.target = self
        ledPopup.action = #selector(ledSelectionChanged)
        ledSlider.target = self
        ledSlider.action = #selector(ledMultiplierChanged)
        ledTestButton.target = self
        ledTestButton.action = #selector(toggleLEDTest)
        resetLedButton.target = self
        resetLedButton.action = #selector(resetLedBrightness)
    }

    // MARK: - Row helpers

    @discardableResult
    private func addRow(label: String, trailing: NSView, valueWidth: CGFloat?, to stack: NSStackView) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 13)
        labelView.translatesAutoresizingMaskIntoConstraints = false

        trailing.translatesAutoresizingMaskIntoConstraints = false
        if let control = trailing as? NSControl { control.setAccessibilityLabel(label) }
        if let well = trailing as? NSColorWell { well.isContinuous = true }

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labelView)
        row.addSubview(trailing)

        var constraints: [NSLayoutConstraint] = [
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            labelView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            labelView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
            trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: labelView.trailingAnchor, constant: 12),
        ]
        if let valueWidth {
            constraints.append(trailing.widthAnchor.constraint(equalToConstant: valueWidth))
        }
        NSLayoutConstraint.activate(constraints)

        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return row
    }

    private func addSliderRow(label: String, slider: NSSlider, value: NSTextField, to stack: NSStackView) {
        let trail = NSStackView(views: [slider, value])
        trail.orientation = .horizontal
        trail.spacing = 8
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        slider.setAccessibilityLabel(label)
        slider.isContinuous = true
        value.widthAnchor.constraint(equalToConstant: 112).isActive = true
        addRow(label: label, trailing: trail, valueWidth: 320, to: stack)
    }

    private func addSection(_ section: NSStackView, to stack: NSStackView) {
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 0
        section.detachesHiddenViews = true
        section.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func fillPopup(_ popup: NSPopUpButton, choices: [(String, String)]) {
        popup.removeAllItems()
        for (value, title) in choices {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
    }

    private func select(_ value: String, in popup: NSPopUpButton) {
        popup.select(popup.itemArray.first { $0.representedObject as? String == value })
    }

    private func addSeparator(to stack: NSStackView) {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addSectionSpace(to stack: NSStackView) {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        stack.addArrangedSubview(v)
    }

    private func addSectionTitle(_ text: String, to stack: NSStackView) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(label)

        let pad = NSView()
        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.heightAnchor.constraint(equalToConstant: 6).isActive = true
        stack.addArrangedSubview(pad)
    }

    private static func secondaryLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    // MARK: - Reload

    private func reloadAll() {
        reloadProfileList()
        reloadDisplays()
        reloadDevices()
        reloadControls()
    }

    private func reloadProfileList() {
        profileTable.reloadData()
        if let id = store.selectedProfileID,
           let row = store.profiles.firstIndex(where: { $0.id == id }) {
            profileTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func reloadDisplays() {
        let selected = DisplayCatalog.displayID(for: store.selectedProfile).map { UInt32($0) }
        displayPopup.removeAllItems()
        for display in DisplayCatalog.displays() {
            displayPopup.addItem(withTitle: "\(display.name) (\(display.pixelWidth)x\(display.pixelHeight))")
            displayPopup.lastItem?.representedObject = UInt32(display.id)
        }
        if let selected,
           let item = displayPopup.itemArray.first(where: { ($0.representedObject as? UInt32) == selected }) {
            displayPopup.select(item)
        } else if displayPopup.numberOfItems > 0 {
            displayPopup.selectItem(at: 0)
        }
    }

    private func reloadDevices() {
        let updating = updatingControls
        updatingControls = true
        defer { updatingControls = updating }

        devicePopup.removeAllItems()
        devicePopup.addItem(withTitle: "Auto (first match)")
        devicePopup.lastItem?.representedObject = nil as Any?

        let candidates = LampArrayDevice.listCandidates()
        for info in candidates {
            let title = "\(info.displayName)  [\(info.idString)]"
            devicePopup.addItem(withTitle: title)
            devicePopup.lastItem?.representedObject = LampArrayDeviceSelection(vendorID: info.vendorID, productID: info.productID)
        }
        devicePopup.isEnabled = true

        let stored = LampArrayDeviceStore.load()
        if let stored,
           let item = devicePopup.itemArray.first(where: { ($0.representedObject as? LampArrayDeviceSelection) == stored }) {
            devicePopup.select(item)
        } else {
            devicePopup.selectItem(at: 0)
        }
    }

    private func reloadControls() {
        updatingControls = true
        defer { updatingControls = false }

        var profile = store.selectedProfile
        profile.normalizeLEDCount(16)

        nameField.stringValue = profile.name
        select(profile.mode.rawValue, in: modePopup)
        reloadIconPicker(profile)
        fpsSlider.doubleValue = Double(profile.clampedCaptureFPS)
        ledFPSSlider.doubleValue = Double(profile.clampedLEDFPS)
        screenshotQualitySlider.doubleValue = Double(profile.clampedScreenshotQuality)
        brightnessSlider.doubleValue = profile.brightness
        colorTemperatureSlider.doubleValue = profile.colorTemperature
        smoothingSlider.doubleValue = profile.smoothing
        radiusSlider.doubleValue = Double(profile.sampleRadius)
        wallEnabledSwitch.state = profile.wallCompensationEnabled ? .on : .off
        wallColorWell.color = profile.wallColor.nsColor
        autoStartSwitch.state = profile.autoStart ? .on : .off
        autoResumeSwitch.state = profile.autoResumeAfterWake ? .on : .off
        reloadMusicControls(profile.music)
        solidColorWell.color = profile.solidColor.nsColor
        gradientStartWell.color = profile.gradient.startColor.nsColor
        gradientEndWell.color = profile.gradient.endColor.nsColor
        gradientEditor.effect = profile.gradient
        select(profile.rainbow.animation.rawValue, in: animationPopup)
        animationSpeedSlider.doubleValue = profile.rainbow.effectiveCycleSeconds
        followVideoSection.isHidden = profile.mode != .followVideo
        musicSection.isHidden = profile.mode != .followMusic
        solidSection.isHidden = profile.mode != .solidColor
        gradientSection.isHidden = profile.mode != .gradientColor
        animationSection.isHidden = profile.mode != .rainbow
        if profile.mode == .rainbow { reloadPalette(profile.rainbow.effectivePalette) }

        let previousLED = ledPopup.indexOfSelectedItem
        ledPopup.removeAllItems()
        for index in 0..<profile.ledMultipliers.count {
            ledPopup.addItem(withTitle: "LED \(index)")
        }
        let clampedLED = min(max(0, previousLED), max(0, profile.ledMultipliers.count - 1))
        ledPopup.selectItem(at: clampedLED)
        ledSlider.doubleValue = profile.ledMultipliers[safe: clampedLED] ?? 1.0

        updateValueLabels()
        updateLEDTestButton()
    }

    private func updateValueLabels() {
        musicSensitivityValue.stringValue = String(format: "%.2fx", musicSensitivitySlider.doubleValue)
        musicSmoothingValue.stringValue = String(format: "%.1f", musicSmoothingSlider.doubleValue)
        musicBrightnessValue.stringValue = "\(Int((musicBrightnessSlider.doubleValue * 100).rounded()))%"
        animationSpeedValue.stringValue = String(format: "%.1f s", animationSpeedSlider.doubleValue)
        fpsValue.stringValue = "\(Int(fpsSlider.doubleValue.rounded())) FPS"
        ledFPSValue.stringValue = "\(Int(ledFPSSlider.doubleValue.rounded())) Hz"
        let quality = Int(screenshotQualitySlider.doubleValue.rounded())
        let longestSide = max(90, Int((720.0 * Double(max(10, quality)) / 100.0).rounded()))
        screenshotQualityValue.stringValue = "\(quality)% / \(longestSide) px"
        brightnessValue.stringValue = "\(Int((brightnessSlider.doubleValue * 100).rounded()))%"
        let temperature = colorTemperatureSlider.doubleValue
        if temperature <= -0.98 {
            colorTemperatureValue.stringValue = "Cold"
        } else if temperature >= 0.98 {
            colorTemperatureValue.stringValue = "Warm"
        } else if temperature < -0.03 {
            colorTemperatureValue.stringValue = "Cooler \(Int((-temperature * 100).rounded()))%"
        } else if temperature > 0.03 {
            colorTemperatureValue.stringValue = "Warmer \(Int((temperature * 100).rounded()))%"
        } else {
            colorTemperatureValue.stringValue = "Neutral"
        }
        smoothingValue.stringValue = String(format: "%.1f", smoothingSlider.doubleValue)
        radiusValue.stringValue = "\(Int(radiusSlider.doubleValue.rounded())) px"
        ledValue.stringValue = String(format: "%.2fx", ledSlider.doubleValue)
    }

    private func updateLEDTestButton() {
        ledTestButton.title = isLEDTestOn ? "Test Off" : "Test On"
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.profiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ProfileRow")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            icon.translatesAutoresizingMaskIntoConstraints = false
            let text = NSTextField(labelWithString: "")
            text.font = .systemFont(ofSize: 13)
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.addSubview(text)
            cell.imageView = icon
            cell.textField = text
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let profile = store.profiles[row]
        cell.textField?.stringValue = profile.name
        cell.imageView?.image = profile.artwork.image(size: 14)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = profileTable.selectedRow
        guard row >= 0, row < store.profiles.count else { return }
        let id = store.profiles[row].id
        guard id != store.selectedProfileID else { return }
        endEditingModeControls()
        store.select(id)
        reloadControls()
        scrollSettingsToTop()
    }

    // MARK: - Actions

    private func endEditingModeControls() {
        if isLEDTestOn {
            isLEDTestOn = false
            engine.setLEDTest(enabled: false, index: 0, profile: store.selectedProfile)
        }
        let wells = [wallColorWell, iconColorWell, solidColorWell, gradientStartWell, gradientEndWell,
                     musicColorWell, bassColorWell, midColorWell, trebleColorWell]
        for well in wells + paletteColorWells {
            if well.isActive { well.deactivate() }
        }
    }

    @objc private func modeChanged() {
        guard !updatingControls, let raw = modePopup.selectedItem?.representedObject as? String,
              let mode = ProfileMode(rawValue: raw) else { return }
        endEditingModeControls()
        store.updateSelected { $0.mode = mode }
        reloadControls()
        reloadProfileList()
    }

    private func reloadIconPicker(_ profile: AmbilightProfile) {
        iconPopup.removeAllItems()
        func add(_ title: String, _ choice: IconChoice, image: NSImage? = nil) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = choice
            item.image = image
            iconPopup.menu?.addItem(item)
        }
        if profile.mode != .followVideo {
            add("Color", .color)
            if profile.mode == .gradientColor { add("Profile Gradient", .gradient) }
            iconPopup.menu?.addItem(.separator())
        }
        for choice in ProfileSymbols.choices where NSImage(systemSymbolName: choice.name, accessibilityDescription: nil) != nil {
            add(choice.title, .symbol(choice.name), image: ProfileSymbols.image(named: choice.name, size: 14))
        }
        if !iconPopup.itemArray.contains(where: { $0.representedObject as? IconChoice == .symbol(profile.iconName) }) {
            add(profile.iconName, .symbol(profile.iconName), image: ProfileSymbols.image(named: profile.iconName, size: 14))
        }
        let selected: IconChoice
        switch profile.artwork {
        case .color: selected = .color
        case .gradient: selected = .gradient
        case .symbol(let name): selected = .symbol(name)
        }
        refreshIconSwatches(profile)
        iconPopup.select(iconPopup.itemArray.first { $0.representedObject as? IconChoice == selected })
        iconColorRow.isHidden = selected != .color
        iconColorWell.color = profile.iconColor.nsColor
    }

    private func refreshIconSwatches(_ profile: AmbilightProfile) {
        for item in iconPopup.itemArray {
            switch item.representedObject as? IconChoice {
            case .color: item.image = ProfileArtwork.color(profile.iconColor).image(size: 14)
            case .gradient: item.image = ProfileArtwork.gradient(profile.gradient).image(size: 14)
            default: break
            }
        }
    }

    private func reloadMusicControls(_ effect: MusicEffect) {
        musicDynamicSwitch.state = effect.dynamicColors ? .on : .off
        musicColorRow.isHidden = effect.dynamicColors
        musicBandColors.isHidden = !effect.dynamicColors
        musicColorWell.color = effect.color.nsColor
        bassColorWell.color = effect.bassColor.nsColor
        midColorWell.color = effect.midColor.nsColor
        trebleColorWell.color = effect.trebleColor.nsColor
        musicSensitivitySlider.doubleValue = effect.sensitivity
        musicSmoothingSlider.doubleValue = effect.smoothing
        musicBrightnessSlider.doubleValue = effect.brightness
    }

    @objc private func musicDynamicChanged() {
        guard !updatingControls else { return }
        let dynamic = musicDynamicSwitch.state == .on
        let wells = dynamic ? [musicColorWell] : [bassColorWell, midColorWell, trebleColorWell]
        for well in wells where well.isActive { well.deactivate() }
        store.updateSelected { $0.music.dynamicColors = dynamic }
        musicColorRow.isHidden = dynamic
        musicBandColors.isHidden = !dynamic
    }

    @objc private func musicColorChanged(_ well: NSColorWell) {
        guard !updatingControls else { return }
        let color = RGBColor(nsColor: well.color)
        store.updateSelected { profile in
            switch well {
            case musicColorWell: profile.music.color = color
            case bassColorWell: profile.music.bassColor = color
            case midColorWell: profile.music.midColor = color
            case trebleColorWell: profile.music.trebleColor = color
            default: break
            }
        }
    }

    @objc private func musicSensitivityChanged() {
        guard !updatingControls else { return }
        let sensitivity = (musicSensitivitySlider.doubleValue * 20).rounded() / 20
        musicSensitivitySlider.doubleValue = sensitivity
        store.updateSelected { $0.music.sensitivity = sensitivity }
        updateValueLabels()
    }

    @objc private func musicSmoothingChanged() {
        guard !updatingControls else { return }
        let smoothing = (musicSmoothingSlider.doubleValue * 10).rounded() / 10
        musicSmoothingSlider.doubleValue = smoothing
        store.updateSelected { $0.music.smoothing = smoothing }
        updateValueLabels()
    }

    @objc private func musicBrightnessChanged() {
        guard !updatingControls else { return }
        let brightness = (musicBrightnessSlider.doubleValue * 100).rounded() / 100
        musicBrightnessSlider.doubleValue = brightness
        store.updateSelected { $0.music.brightness = brightness }
        updateValueLabels()
    }

    @objc private func effectColorChanged(_ well: NSColorWell) {
        guard !updatingControls else { return }
        let color = RGBColor(nsColor: well.color)
        store.updateSelected { profile in
            switch well {
            case iconColorWell: profile.iconColor = color
            case solidColorWell: profile.solidColor = color
            case gradientStartWell: profile.gradient.startColor = color
            case gradientEndWell: profile.gradient.endColor = color
            default: break
            }
        }
        let profile = store.selectedProfile
        if well === gradientStartWell || well === gradientEndWell { gradientEditor.effect = profile.gradient }
        refreshIconSwatches(profile)
        reloadProfileList()
    }

    @objc private func animationChanged() {
        guard !updatingControls, let raw = animationPopup.selectedItem?.representedObject as? String,
              let animation = RainbowAnimation(rawValue: raw) else { return }
        store.updateSelected { $0.rainbow.animation = animation }
    }

    @objc private func animationSpeedChanged() {
        guard !updatingControls else { return }
        let seconds = (animationSpeedSlider.doubleValue * 2).rounded() / 2
        animationSpeedSlider.doubleValue = seconds
        store.updateSelected { $0.rainbow.cycleSeconds = seconds }
        updateValueLabels()
    }

    private func configurePaletteButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func reloadPalette(_ colors: [RGBColor]) {
        for well in paletteColorWells where well.isActive { well.deactivate() }
        for row in paletteSection.arrangedSubviews {
            paletteSection.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        paletteColorWells = []
        for (index, color) in colors.enumerated() {
            addSeparator(to: paletteSection)
            let well = NSColorWell()
            well.isContinuous = true
            well.color = color.nsColor
            well.target = self
            well.action = #selector(paletteColorChanged(_:))
            well.tag = index
            well.setAccessibilityLabel("Palette color \(index + 1)")
            paletteColorWells.append(well)
            let remove = NSButton()
            configurePaletteButton(remove, symbol: "minus", label: "Remove Color \(index + 1)", action: #selector(removePaletteColor(_:)))
            remove.tag = index
            remove.isEnabled = colors.count > RainbowEffect.minimumColors
            let controls = NSStackView(views: [well, remove])
            controls.orientation = .horizontal
            controls.spacing = 8
            well.widthAnchor.constraint(equalToConstant: 60).isActive = true
            remove.widthAnchor.constraint(equalToConstant: 28).isActive = true
            addRow(label: "Color \(index + 1)", trailing: controls, valueWidth: 96, to: paletteSection)
        }
        addPaletteColorButton.isEnabled = colors.count < RainbowEffect.maximumColors
        addPaletteColorButton.setAccessibilityLabel("Add Color")
    }

    @objc private func paletteColorChanged(_ well: NSColorWell) {
        guard !updatingControls, store.selectedProfile.mode == .rainbow, paletteColorWells.contains(where: { $0 === well }) else { return }
        var palette = store.selectedProfile.rainbow.effectivePalette
        guard palette.indices.contains(well.tag) else { return }
        palette[well.tag] = RGBColor(nsColor: well.color)
        store.updateSelected { $0.rainbow.palette = palette }
    }

    @objc private func addPaletteColor() {
        var palette = store.selectedProfile.rainbow.effectivePalette
        guard palette.count < RainbowEffect.maximumColors else { return }
        palette.append(.white)
        store.updateSelected { $0.rainbow.palette = palette }
        reloadPalette(palette)
    }

    @objc private func removePaletteColor(_ sender: NSButton) {
        var palette = store.selectedProfile.rainbow.effectivePalette
        guard palette.count > RainbowEffect.minimumColors, palette.indices.contains(sender.tag) else { return }
        palette.remove(at: sender.tag)
        store.updateSelected { $0.rainbow.palette = palette }
        reloadPalette(palette)
    }

    @objc private func iconChanged() {
        guard !updatingControls, let choice = iconPopup.selectedItem?.representedObject as? IconChoice else { return }
        if choice != .color && iconColorWell.isActive { iconColorWell.deactivate() }
        store.updateSelected { profile in
            switch choice {
            case .color: profile.iconStyle = .color
            case .gradient: profile.iconStyle = .gradient
            case .symbol(let name):
                profile.iconStyle = .symbol
                profile.iconName = name
            }
        }
        iconColorRow.isHidden = choice != .color
        reloadProfileList()
    }

    @objc private func newProfile() {
        endEditingModeControls()
        _ = store.addProfile(named: "New Profile")
        reloadAll()
        nameField.window?.makeFirstResponder(nameField)
        nameField.selectText(nil)
    }

    @objc private func deleteProfileFromContext(_ sender: NSMenuItem) {
        let row = profileTable.clickedRow
        guard row >= 0, row < store.profiles.count else { return }
        guard store.profiles.count > 1 else {
            NSSound.beep()
            return
        }
        endEditingModeControls()
        store.deleteProfile(id: store.profiles[row].id)
        reloadAll()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(deleteProfileFromContext(_:)) {
            return store.profiles.count > 1
        }
        return true
    }

    @objc private func applySettings() {
        window?.endEditing(for: nil)
        commitNameEdit()
        if finishEditing(save: true) { window?.close() }
    }

    @objc private func cancelSettings() {
        window?.endEditing(for: nil)
        if finishEditing(save: false) {
            reloadAll()
            window?.close()
        }
    }

    @objc private func stopProfile() {
        onStop()
    }

    @objc private func displayChanged() {
        guard !updatingControls else { return }
        let displayID = displayPopup.selectedItem?.representedObject as? UInt32
        store.updateSelected { $0.displayID = displayID }
    }

    @objc private func deviceChanged() {
        guard !updatingControls else { return }
        let selection = devicePopup.selectedItem?.representedObject as? LampArrayDeviceSelection
        LampArrayDeviceStore.save(selection)
        DebugLog.write("LampArray device selection changed to \(selection?.idString ?? "Auto (first match)")")
        onDeviceChange()
    }

    @objc private func fpsChanged() {
        guard !updatingControls else { return }
        let fps = min(50, max(1, Int(fpsSlider.doubleValue.rounded())))
        fpsSlider.doubleValue = Double(fps)
        store.updateSelected { $0.fps = fps }
        updateValueLabels()
    }

    @objc private func ledFPSChanged() {
        guard !updatingControls else { return }
        let fps = min(50, max(1, Int(ledFPSSlider.doubleValue.rounded())))
        ledFPSSlider.doubleValue = Double(fps)
        store.updateSelected { $0.ledFPS = fps }
        updateValueLabels()
    }

    @objc private func screenshotQualityChanged() {
        guard !updatingControls else { return }
        let quality = min(100, max(10, Int(screenshotQualitySlider.doubleValue.rounded())))
        screenshotQualitySlider.doubleValue = Double(quality)
        store.updateSelected { $0.screenshotQuality = quality }
        updateValueLabels()
    }

    @objc private func brightnessChanged() {
        guard !updatingControls else { return }
        store.updateSelected { $0.brightness = brightnessSlider.doubleValue }
        updateValueLabels()
    }

    @objc private func colorTemperatureChanged() {
        guard !updatingControls else { return }
        let temperature = min(1, max(-1, colorTemperatureSlider.doubleValue))
        colorTemperatureSlider.doubleValue = temperature
        store.updateSelected { $0.colorTemperature = temperature }
        updateValueLabels()
    }

    @objc private func smoothingChanged() {
        guard !updatingControls else { return }
        let rounded = (smoothingSlider.doubleValue * 10).rounded() / 10
        smoothingSlider.doubleValue = rounded
        store.updateSelected { $0.smoothing = rounded }
        updateValueLabels()
    }

    @objc private func radiusChanged() {
        guard !updatingControls else { return }
        let radius = Int(radiusSlider.doubleValue.rounded())
        radiusSlider.doubleValue = Double(radius)
        store.updateSelected { $0.sampleRadius = radius }
        updateValueLabels()
    }

    @objc private func toggleChanged() {
        guard !updatingControls else { return }
        store.updateSelected {
            $0.wallCompensationEnabled = wallEnabledSwitch.state == .on
            $0.captureFullScreen = true
            $0.autoStart = autoStartSwitch.state == .on
        }
    }

    @objc private func experimentalChanged() {
        guard !updatingControls else { return }
        store.updateSelected {
            $0.autoResumeAfterWake = autoResumeSwitch.state == .on
            $0.useSCScreenshotManagerBackend = true
            $0.useRegionCaptureBackend = false
        }
    }

    @objc private func wallColorChanged() {
        guard !updatingControls else { return }
        wallEnabledSwitch.state = .on
        store.updateSelected {
            $0.wallColor = RGBColor(nsColor: wallColorWell.color)
            $0.wallCompensationEnabled = true
        }
    }

    @objc private func ledSelectionChanged() {
        guard !updatingControls else { return }
        let index = max(0, ledPopup.indexOfSelectedItem)
        let profile = store.selectedProfile
        ledSlider.doubleValue = profile.ledMultipliers[safe: index] ?? 1.0
        updateValueLabels()
        if isLEDTestOn {
            engine.setLEDTest(enabled: true, index: index, profile: profile)
        }
    }

    @objc private func ledMultiplierChanged() {
        guard !updatingControls else { return }
        let index = max(0, ledPopup.indexOfSelectedItem)
        store.updateSelected { profile in
            profile.normalizeLEDCount(max(16, index + 1))
            profile.ledMultipliers[index] = ledSlider.doubleValue
        }
        updateValueLabels()
        let profile = store.selectedProfile
        if isLEDTestOn {
            engine.setLEDTest(enabled: true, index: index, profile: profile)
        }
    }

    @objc private func resetLedBrightness() {
        let index = max(0, ledPopup.indexOfSelectedItem)
        ledSlider.doubleValue = 1.0
        store.updateSelected { profile in
            profile.normalizeLEDCount(max(16, index + 1))
            profile.ledMultipliers[index] = 1.0
        }
        updateValueLabels()
        let profile = store.selectedProfile
        if isLEDTestOn {
            engine.setLEDTest(enabled: true, index: index, profile: profile)
        }
    }

    @objc private func toggleLEDTest() {
        isLEDTestOn.toggle()
        updateLEDTestButton()
        engine.setLEDTest(
            enabled: isLEDTestOn,
            index: max(0, ledPopup.indexOfSelectedItem),
            profile: store.selectedProfile
        )
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !updatingControls, obj.object as AnyObject === nameField else { return }
        commitNameEdit()
    }

    @objc private func nameFieldSubmitted() {
        commitNameEdit()
    }

    private func commitNameEdit() {
        let raw = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = raw.isEmpty ? "Untitled" : raw
        if new != store.selectedProfile.name {
            store.updateSelected { $0.name = new }
            profileTable.reloadData()
            if let id = store.selectedProfileID,
               let row = store.profiles.firstIndex(where: { $0.id == id }) {
                profileTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        nameField.stringValue = new
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
