import AppKit

private func makeGradient(_ effect: GradientEffect) -> CGGradient? {
    let transition = OKLCHTransition(from: effect.startColor, to: effect.endColor)
    let colors = (0...48).map { transition.color(at: Double($0) / 48).nsColor.cgColor }
    return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)
}

private func drawGradient(_ gradient: CGGradient, in rect: NSRect, effect: GradientEffect, context: CGContext) {
    func point(_ stop: GradientPoint) -> CGPoint {
        CGPoint(x: rect.minX + stop.x * rect.width, y: rect.maxY - stop.y * rect.height)
    }
    let start = point(effect.start), end = point(effect.end)
    if hypot(end.x - start.x, end.y - start.y) < 0.1 {
        context.setFillColor(OKLCHTransition(from: effect.startColor, to: effect.endColor).color(at: 0.5).nsColor.cgColor)
        context.fill(rect)
    } else {
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}

extension ProfileArtwork {
    func image(size: CGFloat) -> NSImage? {
        if case .symbol(let name) = self {
            return ProfileSymbols.image(named: name, size: size)
        }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addEllipse(in: rect)
            context.clip()
            switch self {
            case .symbol: break
            case .color(let color):
                context.setFillColor(color.nsColor.cgColor)
                context.fill(rect)
            case .gradient(let effect):
                if let gradient = makeGradient(effect) {
                    drawGradient(gradient, in: rect, effect: effect, context: context)
                }
            }
            NSColor.labelColor.withAlphaComponent(0.3).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
    }
}

final class GradientEditorView: NSView {
    var onChange: ((GradientEffect) -> Void)?
    var effect = GradientEffect() {
        didSet {
            if effect.startColor != oldValue.startColor || effect.endColor != oldValue.endColor {
                gradient = makeGradient(effect)
            }
            needsDisplay = true
        }
    }
    private var gradient = makeGradient(GradientEffect())
    private var activeStop = 0
    override var acceptsFirstResponder: Bool { true }
    private var canvas: NSRect { bounds.insetBy(dx: 12, dy: 12) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Gradient direction")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    private func location(of stop: GradientPoint) -> NSPoint {
        NSPoint(x: canvas.minX + stop.x * canvas.width, y: canvas.maxY - stop.y * canvas.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let gradient, let context = NSGraphicsContext.current?.cgContext else { return }
        let background = NSBezierPath(roundedRect: canvas, xRadius: 8, yRadius: 8)
        context.saveGState()
        background.addClip()
        drawGradient(gradient, in: canvas, effect: effect, context: context)
        context.restoreGState()

        let start = location(of: effect.start), end = location(of: effect.end)
        let axis = NSBezierPath()
        axis.move(to: start)
        axis.line(to: end)
        axis.lineWidth = 3
        NSColor.black.withAlphaComponent(0.55).setStroke()
        axis.stroke()
        axis.lineWidth = 1
        NSColor.white.setStroke()
        axis.stroke()

        for (index, point, color) in [(0, start, effect.startColor), (1, end, effect.endColor)] {
            let rect = NSRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
            let handle = NSBezierPath(ovalIn: rect)
            NSColor.black.withAlphaComponent(0.75).setStroke()
            handle.lineWidth = 4
            handle.stroke()
            color.nsColor.setFill()
            handle.fill()
            (index == activeStop && window?.firstResponder === self ? NSColor.controlAccentColor : .white).setStroke()
            handle.lineWidth = 2
            handle.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let start = location(of: effect.start), end = location(of: effect.end)
        let a = hypot(point.x - start.x, point.y - start.y), b = hypot(point.x - end.x, point.y - end.y)
        if a == b { activeStop = 1 - activeStop } else { activeStop = a < b ? 0 : 1 }
        moveStop(to: point)
    }

    override func mouseDragged(with event: NSEvent) {
        moveStop(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        moveStop(to: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        var stop = activeStop == 0 ? effect.start : effect.end
        let step = event.modifierFlags.contains(.shift) ? 0.1 : 0.02
        switch event.keyCode {
        case 49: activeStop = 1 - activeStop; needsDisplay = true; return
        case 123: stop.x -= step
        case 124: stop.x += step
        case 125: stop.y += step
        case 126: stop.y -= step
        default: super.keyDown(with: event); return
        }
        moveStop(to: location(of: stop))
    }

    private func moveStop(to point: NSPoint) {
        let stop = GradientPoint(x: min(1, max(0, (point.x - canvas.minX) / canvas.width)),
                                 y: min(1, max(0, (canvas.maxY - point.y) / canvas.height)))
        if activeStop == 0 {
            guard effect.start != stop else { return }
            effect.start = stop
        } else {
            guard effect.end != stop else { return }
            effect.end = stop
        }
        onChange?(effect)
    }
}
