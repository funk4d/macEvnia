import AppKit

@main
enum ProfileSettingsTests {
    static func main() {
        _ = NSApplication.shared
        let profile = AmbilightProfile.defaultProfile()
        let store = ProfileStore(previewProfiles: [profile])
        var finishes: [Bool] = []
        var previews: [AmbilightProfile] = []
        store.onProfileEdited = { profile, previous in
            if profile.changesLighting(comparedTo: previous) { previews.append(profile) }
        }
        let controller = PreferencesWindowController(store: store, engine: AmbilightEngine(),
                                                      onBeginEditing: {},
                                                      onFinishEditing: { saved, _ in finishes.append(saved) },
                                                      onStop: {}, onDeviceChange: {})
        guard let window = controller.window, let content = window.contentView else { fatalError("Settings window missing") }
        controller.beginEditing()
        window.setContentSize(NSSize(width: 780, height: 540))
        content.layoutSubtreeIfNeeded()
        let mode = control(NSPopUpButton.self, "Mode", in: content)
        let capture = control(NSSlider.self, "Capture rate", in: content)
        let quality = control(NSSlider.self, "Screenshot quality", in: content)
        let temperature = control(NSSlider.self, "Color temperature", in: content)
        for slider in [capture, quality, temperature] {
            precondition(slider.isContinuous)
            let original = slider.convert(slider.bounds, to: nil)
            precondition(original.width == 200)
            for value in [slider.minValue, (slider.minValue + slider.maxValue) / 2, slider.maxValue] {
                slider.doubleValue = value
                slider.sendAction(slider.action, to: slider.target)
                content.layoutSubtreeIfNeeded()
                precondition(slider.convert(slider.bounds, to: nil) == original, "Numeric readout moved the slider")
            }
        }
        for (index, expected) in ProfileMode.allCases.enumerated() {
            mode.selectItem(at: index)
            mode.sendAction(mode.action, to: mode.target)
            content.layoutSubtreeIfNeeded()
            precondition(store.selectedProfile.mode == expected)
            let icon = control(NSPopUpButton.self, "Profile icon", in: content)
            let iconTitles = icon.itemArray.filter { !$0.isSeparatorItem }.map(\.title)
            precondition(!iconTitles.contains("Symbol") && iconTitles.contains("Display"))
            precondition(!views(in: content).compactMap { $0 as? NSPopUpButton }.contains {
                $0.accessibilityLabel() == "Profile artwork"
            })
            let sliders = views(in: content).filter { $0 is NSSlider && !$0.isHiddenOrHasHiddenAncestor }
            switch expected {
            case .followVideo:
                precondition(sliders.count == 8 && !iconTitles.contains("Color") && !iconTitles.contains("Profile Gradient"))
            case .followMusic:
                precondition(sliders.count == 3 && iconTitles.first == "Color")
                precondition(control(NSColorWell.self, "Music color", in: content).isContinuous)
                let toggle = control(NSSwitch.self, "Dynamic", in: content)
                toggle.state = .on
                toggle.sendAction(toggle.action, to: toggle.target)
                content.layoutSubtreeIfNeeded()
                precondition(store.selectedProfile.music.dynamicColors)
                _ = control(NSColorWell.self, "Bass color", in: content)
                _ = control(NSColorWell.self, "Mid color", in: content)
                let treble = control(NSColorWell.self, "Treble color", in: content)
                treble.color = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
                treble.sendAction(treble.action, to: treble.target)
                precondition(store.selectedProfile.music.trebleColor == RGBColor(r: 0, g: 0, b: 1))
                let sensitivity = control(NSSlider.self, "Sensitivity", in: content)
                sensitivity.doubleValue = 1.75
                sensitivity.sendAction(sensitivity.action, to: sensitivity.target)
                precondition(store.selectedProfile.music.sensitivity == 1.75)
                let smoothing = control(NSSlider.self, "Smoothing", in: content)
                smoothing.doubleValue = 0.7
                smoothing.sendAction(smoothing.action, to: smoothing.target)
                let brightness = control(NSSlider.self, "Brightness", in: content)
                brightness.doubleValue = 0.42
                brightness.sendAction(brightness.action, to: brightness.target)
                precondition(previews.last?.music.smoothing == 0.7 && previews.last?.music.brightness == 0.42)
            case .solidColor:
                precondition(sliders.isEmpty)
                _ = control(NSColorWell.self, "Color", in: content)
                precondition(iconTitles.first == "Color" && !iconTitles.contains("Profile Gradient"))
                icon.selectItem(withTitle: "Color")
                icon.sendAction(icon.action, to: icon.target)
                let iconColor = control(NSColorWell.self, "Icon color", in: content)
                iconColor.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
                iconColor.sendAction(iconColor.action, to: iconColor.target)
                precondition(store.selectedProfile.artwork == .color(RGBColor(r: 1, g: 0, b: 0)))
                icon.selectItem(withTitle: "Display")
                icon.sendAction(icon.action, to: icon.target)
                precondition(iconColor.isHiddenOrHasHiddenAncestor || iconColor.window == nil)
                precondition(store.selectedProfile.artwork == .symbol("display"))
            case .gradientColor:
                precondition(sliders.isEmpty)
                precondition(Array(iconTitles.prefix(2)) == ["Color", "Profile Gradient"])
                icon.selectItem(withTitle: "Profile Gradient")
                icon.sendAction(icon.action, to: icon.target)
                precondition(store.selectedProfile.artwork == .gradient(store.selectedProfile.gradient))
                guard let editor = views(in: content).first(where: { $0 is GradientEditorView && !$0.isHiddenOrHasHiddenAncestor }) as? GradientEditorView else {
                    fatalError("Gradient editor not visible")
                }
                precondition(editor.bounds.size == NSSize(width: 244, height: 244))
                let before = store.selectedProfile.gradient
                if let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124) {
                    editor.keyDown(with: key)
                    precondition(store.selectedProfile.gradient.start.x > before.start.x)
                }
            case .rainbow:
                precondition(mode.titleOfSelectedItem == "Animation" && sliders.count == 1)
                precondition(iconTitles.first == "Color" && !iconTitles.contains("Profile Gradient"))
                precondition(icon.titleOfSelectedItem == "Display")
                let speed = control(NSSlider.self, "Cycle duration", in: content)
                speed.doubleValue = 20
                speed.sendAction(speed.action, to: speed.target)
                precondition(store.selectedProfile.rainbow.cycleSeconds == 20)
                let add = control(NSButton.self, "Add Color", in: content)
                let count = store.selectedProfile.rainbow.palette.count
                add.performClick(nil)
                precondition(store.selectedProfile.rainbow.palette.count == count + 1)
                let remove = control(NSButton.self, "Remove Color 2", in: content)
                remove.performClick(nil)
                precondition(store.selectedProfile.rainbow.palette.count == count)
            }
        }
        let buttons = views(in: content).compactMap { $0 as? NSButton }
        guard let apply = buttons.first(where: { $0.title == "Apply" }),
              let cancel = buttons.first(where: { $0.title == "Cancel" }) else { fatalError("Settings actions missing") }
        precondition(!buttons.contains(where: { $0.title == "Apply & Start" }))
        precondition(store.isEditing && store.hasUnsavedChanges && !previews.isEmpty)
        let applied = store.selectedProfile
        let previewCount = previews.count
        apply.performClick(nil)
        precondition(finishes == [true] && !store.isEditing && !store.hasUnsavedChanges && !window.isVisible)
        precondition(previews.count == previewCount, "Apply must not start a new preview")
        controller.beginEditing()
        mode.selectItem(withTitle: "Solid Color")
        mode.sendAction(mode.action, to: mode.target)
        precondition(previews.last?.mode == .solidColor && store.hasUnsavedChanges)
        cancel.performClick(nil)
        precondition(finishes == [true, false] && !store.isEditing && store.selectedProfile == applied)
        print("PASS: stationary sliders, mode-specific controls, live changes, Apply and Cancel rollback")
    }

    private static func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    private static func control<T: NSControl>(_ type: T.Type, _ label: String, in content: NSView) -> T {
        guard let result = views(in: content).compactMap({ $0 as? T }).first(where: {
            !$0.isHiddenOrHasHiddenAncestor && $0.accessibilityLabel() == label
        }) else {
            fatalError("Missing control: \(label)")
        }
        return result
    }
}
