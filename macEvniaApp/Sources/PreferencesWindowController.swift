import AppKit
import Foundation

final class PreferencesWindowController: NSWindowController,
                                         NSTableViewDataSource,
                                         NSTableViewDelegate,
                                         NSTextFieldDelegate,
                                         NSMenuItemValidation {
    private let store: ProfileStore
    private let engine: AmbilightEngine

    // Sidebar
    private let profileTable = NSTableView()
    private let newProfileButton = NSButton(title: "New profile", target: nil, action: nil)

    // Right area controls
    private let nameField = NSTextField()
    private let displayPopup = NSPopUpButton()
    private let devicePopup = NSPopUpButton()
    private let fpsSlider = NSSlider(value: 30, minValue: 1, maxValue: 50, target: nil, action: nil)
    private let ledFPSSlider = NSSlider(value: 50, minValue: 1, maxValue: 50, target: nil, action: nil)
    private let screenshotQualitySlider = NSSlider(value: 50, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let brightnessSlider = NSSlider(value: 0.6, minValue: 0, maxValue: 1, target: nil, action: nil)
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
    private let smoothingValue = secondaryLabel()
    private let radiusValue = secondaryLabel()
    private let ledValue = secondaryLabel()

    private let statusLabel = NSTextField(labelWithString: "Stopped")
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let applyButton = NSButton(title: "Apply & Start", target: nil, action: nil)

    private weak var rightScrollView: NSScrollView?

    private var isLEDTestOn = false
    private var updatingControls = false

    init(store: ProfileStore, engine: AmbilightEngine) {
        self.store = store
        self.engine = engine
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "macEvnia"
        window.minSize = NSSize(width: 780, height: 540)
        window.center()
        super.init(window: window)
        buildUI()
        reloadAll()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        reloadAll()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        // Reset the settings scroll back to the top every time the window opens.
        DispatchQueue.main.async { [weak self] in
            self?.scrollSettingsToTop()
        }
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

        ledTestButton.bezelStyle = .rounded
        resetLedButton.bezelStyle = .rounded

        addRow(label: "Name", trailing: nameField, valueWidth: 220, to: stack)
        addSeparator(to: stack)
        addRow(label: "Capture display", trailing: displayPopup, valueWidth: 260, to: stack)
        addSeparator(to: stack)
        addRow(label: "Device", trailing: devicePopup, valueWidth: 260, to: stack)
        addSeparator(to: stack)
        addSliderRow(label: "Capture rate", slider: fpsSlider, value: fpsValue, to: stack)
        addSeparator(to: stack)
        addSliderRow(label: "LED rate", slider: ledFPSSlider, value: ledFPSValue, to: stack)
        addSeparator(to: stack)
        addSliderRow(label: "Screenshot quality", slider: screenshotQualitySlider, value: screenshotQualityValue, to: stack)
        addSeparator(to: stack)
        addSliderRow(label: "Ambiglow brightness", slider: brightnessSlider, value: brightnessValue, to: stack)
        addSeparator(to: stack)
        addSliderRow(label: "Smoothing", slider: smoothingSlider, value: smoothingValue, to: stack)
        addSeparator(to: stack)
        addSliderRow(label: "Sample radius", slider: radiusSlider, value: radiusValue, to: stack)
        addSeparator(to: stack)
        addRow(label: "Auto-start with app", trailing: autoStartSwitch, valueWidth: nil, to: stack)
        addSeparator(to: stack)
        addRow(label: "Auto-resume after wake", trailing: autoResumeSwitch, valueWidth: nil, to: stack)

        addSectionSpace(to: stack)
        addSectionTitle("Wall Color", to: stack)
        addRow(label: "Compensate wall color", trailing: wallEnabledSwitch, valueWidth: nil, to: stack)
        addSeparator(to: stack)
        addRow(label: "Wall color", trailing: wallColorWell, valueWidth: 60, to: stack)

        addSectionSpace(to: stack)
        addSectionTitle("LED Calibration", to: stack)
        addRow(label: "Selected LED", trailing: ledPopup, valueWidth: 160, to: stack)
        addSeparator(to: stack)
        addSliderRow(label: "LED brightness", slider: ledSlider, value: ledValue, to: stack)
        addSeparator(to: stack)
        let ledButtons = NSStackView(views: [resetLedButton, ledTestButton])
        ledButtons.orientation = .horizontal
        ledButtons.spacing = 8
        addRow(label: "Test single LED", trailing: ledButtons, valueWidth: nil, to: stack)

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
        applyButton.action = #selector(startProfile)
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"

        let bottomBar = NSStackView()
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 10
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addArrangedSubview(statusLabel)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addArrangedSubview(spacer)
        bottomBar.addArrangedSubview(stopButton)
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

    private func addRow(label: String, trailing: NSView, valueWidth: CGFloat?, to stack: NSStackView) {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 13)
        labelView.translatesAutoresizingMaskIntoConstraints = false

        trailing.translatesAutoresizingMaskIntoConstraints = false

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
    }

    private func addSliderRow(label: String, slider: NSSlider, value: NSTextField, to stack: NSStackView) {
        let trail = NSStackView(views: [slider, value])
        trail.orientation = .horizontal
        trail.spacing = 8
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        value.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        addRow(label: label, trailing: trail, valueWidth: nil, to: stack)
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
        fpsSlider.doubleValue = Double(profile.clampedCaptureFPS)
        ledFPSSlider.doubleValue = Double(profile.clampedLEDFPS)
        screenshotQualitySlider.doubleValue = Double(profile.clampedScreenshotQuality)
        brightnessSlider.doubleValue = profile.brightness
        smoothingSlider.doubleValue = profile.smoothing
        radiusSlider.doubleValue = Double(profile.sampleRadius)
        wallEnabledSwitch.state = profile.wallCompensationEnabled ? .on : .off
        wallColorWell.color = profile.wallColor.nsColor
        autoStartSwitch.state = profile.autoStart ? .on : .off
        autoResumeSwitch.state = profile.autoResumeAfterWake ? .on : .off

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
        fpsValue.stringValue = "\(Int(fpsSlider.doubleValue.rounded())) FPS"
        ledFPSValue.stringValue = "\(Int(ledFPSSlider.doubleValue.rounded())) Hz"
        let quality = Int(screenshotQualitySlider.doubleValue.rounded())
        let longestSide = max(90, Int((720.0 * Double(max(10, quality)) / 100.0).rounded()))
        screenshotQualityValue.stringValue = "\(quality)% / \(longestSide) px"
        brightnessValue.stringValue = "\(Int((brightnessSlider.doubleValue * 100).rounded()))%"
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
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = profileTable.selectedRow
        guard row >= 0, row < store.profiles.count else { return }
        let id = store.profiles[row].id
        guard id != store.selectedProfileID else { return }
        store.select(id)
        reloadControls()
        engine.update(profile: store.selectedProfile)
    }

    // MARK: - Actions

    @objc private func newProfile() {
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
        store.deleteProfile(id: store.profiles[row].id)
        reloadAll()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(deleteProfileFromContext(_:)) {
            return store.profiles.count > 1
        }
        return true
    }

    @objc private func startProfile() {
        engine.start(profile: store.selectedProfile)
    }

    @objc private func stopProfile() {
        engine.stop(returnToAutonomous: false)
    }

    @objc private func displayChanged() {
        guard !updatingControls else { return }
        let displayID = displayPopup.selectedItem?.representedObject as? UInt32
        store.updateSelected { $0.displayID = displayID }
        engine.update(profile: store.selectedProfile)
    }

    @objc private func deviceChanged() {
        guard !updatingControls else { return }
        let selection = devicePopup.selectedItem?.representedObject as? LampArrayDeviceSelection
        LampArrayDeviceStore.save(selection)
        DebugLog.write("LampArray device selection changed to \(selection?.idString ?? "Auto (first match)")")
        // If the engine is currently doing anything, restart it on the new
        // device. Capture mode restarts via engine.start(); the other modes
        // (rainbow / solid / lights off) reopen the LampArray themselves on
        // their next entry call, so we route through AppDelegate's restart.
        if engine.isRunning {
            engine.start(profile: store.selectedProfile)
        }
    }

    @objc private func fpsChanged() {
        guard !updatingControls else { return }
        let fps = min(50, max(1, Int(fpsSlider.doubleValue.rounded())))
        fpsSlider.doubleValue = Double(fps)
        store.updateSelected { $0.fps = fps }
        updateValueLabels()
        engine.update(profile: store.selectedProfile)
    }

    @objc private func ledFPSChanged() {
        guard !updatingControls else { return }
        let fps = min(50, max(1, Int(ledFPSSlider.doubleValue.rounded())))
        ledFPSSlider.doubleValue = Double(fps)
        store.updateSelected { $0.ledFPS = fps }
        updateValueLabels()
        engine.update(profile: store.selectedProfile)
    }

    @objc private func screenshotQualityChanged() {
        guard !updatingControls else { return }
        let quality = min(100, max(10, Int(screenshotQualitySlider.doubleValue.rounded())))
        screenshotQualitySlider.doubleValue = Double(quality)
        store.updateSelected { $0.screenshotQuality = quality }
        updateValueLabels()
        engine.update(profile: store.selectedProfile)
    }

    @objc private func brightnessChanged() {
        guard !updatingControls else { return }
        store.updateSelected { $0.brightness = brightnessSlider.doubleValue }
        updateValueLabels()
        engine.update(profile: store.selectedProfile)
    }

    @objc private func smoothingChanged() {
        guard !updatingControls else { return }
        let rounded = (smoothingSlider.doubleValue * 10).rounded() / 10
        smoothingSlider.doubleValue = rounded
        store.updateSelected { $0.smoothing = rounded }
        updateValueLabels()
        engine.update(profile: store.selectedProfile)
    }

    @objc private func radiusChanged() {
        guard !updatingControls else { return }
        let radius = Int(radiusSlider.doubleValue.rounded())
        radiusSlider.doubleValue = Double(radius)
        store.updateSelected { $0.sampleRadius = radius }
        updateValueLabels()
        engine.update(profile: store.selectedProfile)
    }

    @objc private func toggleChanged() {
        guard !updatingControls else { return }
        store.updateSelected {
            $0.wallCompensationEnabled = wallEnabledSwitch.state == .on
            $0.captureFullScreen = true
            $0.autoStart = autoStartSwitch.state == .on
        }
        engine.update(profile: store.selectedProfile)
    }

    @objc private func experimentalChanged() {
        guard !updatingControls else { return }
        store.updateSelected {
            $0.autoResumeAfterWake = autoResumeSwitch.state == .on
            $0.useSCScreenshotManagerBackend = true
            $0.useRegionCaptureBackend = false
        }
        engine.update(profile: store.selectedProfile)
    }

    @objc private func wallColorChanged() {
        guard !updatingControls else { return }
        store.updateSelected { $0.wallColor = RGBColor(nsColor: wallColorWell.color) }
        engine.update(profile: store.selectedProfile)
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
        engine.update(profile: profile)
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
        engine.update(profile: profile)
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
