import AppKit
import QuartzCore
import TFDesignSystem

/// Smart mosaic feedback over the canvas content (INP-08): while detection runs a light band sweeps the image under a
/// faint wash; when it finishes each found area lights up in turn and fades. Pure Core Animation (the main thread only
/// sets it up); with Reduce Motion the sweep becomes a gentle pulse and found areas fade without scaling.
@MainActor
final class ScanEffectView: NSView {
    static let sweepDuration: CFTimeInterval = 1.1
    static let highlightDuration: CFTimeInterval = 1.3
    static let stagger: CFTimeInterval = 0.06

    private var scan: CALayer?
    private(set) var isScanning = false
    /// Highlight layers still on screen (for tests and cleanup).
    private(set) var highlights: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func beginScanning(in content: CGRect, reduceMotion: Bool) {
        removeScan()
        guard let root = layer, content.width > 1, content.height > 1 else { return }
        isScanning = true
        let accent = DS.Overlay.accent
        let container = CALayer()
        container.frame = content
        container.masksToBounds = true
        let wash = CALayer()
        wash.frame = container.bounds
        wash.backgroundColor = accent.withAlphaComponent(0.12).cgColor
        container.addSublayer(wash)
        if reduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.4
            pulse.toValue = 1
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            wash.add(pulse, forKey: "pulse")
        } else {
            let height = min(max(content.height * 0.18, 28), 140)
            let beam = CAGradientLayer()
            beam.frame = CGRect(x: 0, y: -height, width: content.width, height: height)
            // Symmetric glow with a bright core, so it reads the same whichever way the hierarchy is flipped.
            beam.colors = [0, 0.3, 0.9, 0.3, 0].map { accent.withAlphaComponent($0).cgColor }
            beam.locations = [0, 0.32, 0.5, 0.68, 1]
            beam.startPoint = CGPoint(x: 0.5, y: 0)
            beam.endPoint = CGPoint(x: 0.5, y: 1)
            let sweep = CABasicAnimation(keyPath: "position.y")
            sweep.fromValue = -height / 2
            sweep.toValue = content.height + height / 2
            sweep.duration = Self.sweepDuration
            sweep.repeatCount = .infinity
            sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            beam.add(sweep, forKey: "sweep")
            container.addSublayer(beam)
        }
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = DS.Motion.fast
        container.add(appear, forKey: "appear")
        root.addSublayer(container)
        scan = container
    }

    /// Ends the sweep and lights up each found area (view coordinates), staggered.
    func finishScanning(found rects: [CGRect], reduceMotion: Bool) {
        isScanning = false
        if let scan {
            self.scan = nil
            CATransaction.begin()
            CATransaction.setCompletionBlock { scan.removeFromSuperlayer() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = scan.presentation()?.opacity ?? 1
            fade.toValue = 0
            fade.duration = DS.Motion.standard
            scan.opacity = 0
            scan.add(fade, forKey: "fade")
            CATransaction.commit()
        }
        guard let root = layer else { return }
        let accent = DS.Overlay.accent
        let now = CACurrentMediaTime()
        for (index, rect) in rects.prefix(40).enumerated() where rect.width > 0 && rect.height > 0 {
            let box = rect.insetBy(dx: -3, dy: -3)
            let shape = CAShapeLayer()
            shape.frame = box
            shape.path = CGPath(roundedRect: CGRect(origin: .zero, size: box.size), cornerWidth: 4, cornerHeight: 4, transform: nil)
            shape.strokeColor = accent.cgColor
            shape.fillColor = accent.withAlphaComponent(0.25).cgColor
            shape.lineWidth = 2.5
            shape.opacity = 0
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 1, 1, 0]
            opacity.keyTimes = [0, 0.18, 0.7, 1]
            var animations: [CAAnimation] = [opacity]
            if !reduceMotion {
                let scale = CAKeyframeAnimation(keyPath: "transform.scale")
                scale.values = [1.3, 1, 1, 1]
                scale.keyTimes = [0, 0.22, 0.7, 1]
                scale.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .linear)]
                animations.append(scale)
            }
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = Self.highlightDuration
            group.beginTime = now + Double(index) * Self.stagger
            group.fillMode = .backwards
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self, weak shape] in
                shape?.removeFromSuperlayer()
                self?.highlights.removeAll { $0 === shape || $0.superlayer == nil }
            }
            shape.add(group, forKey: "found")
            CATransaction.commit()
            root.addSublayer(shape)
            highlights.append(shape)
        }
    }

    private func removeScan() {
        scan?.removeFromSuperlayer()
        scan = nil
        isScanning = false
    }
}
