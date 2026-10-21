import SwiftUI
import AppKit
import QuartzCore

/// Renders sprite frames as a Core Animation `contents` keyframe animation (runs in the render server,
/// ~0% app CPU) with nearest-neighbour scaling, plus idle bob and mood animations.
final class PetSpriteNSView: NSView {
    private let hitLayer = CALayer()
    private let bobLayer = CALayer()
    private let moodLayer = CALayer()
    private let spriteLayer = CALayer()
    private let tintLayer = CALayer()
    private let tintMask = CALayer()

    private var currentAnim: SpriteAnimation?
    private var currentMood: PetMood?
    var spriteSize: CGSize = CGSize(width: 96, height: 96) { didSet { needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }
        // Near-invisible fill so the window server treats the sprite box as hittable for dragging.
        hitLayer.backgroundColor = NSColor.white.withAlphaComponent(0.012).cgColor
        hitLayer.cornerRadius = 12
        root.addSublayer(hitLayer)
        root.addSublayer(bobLayer)
        bobLayer.addSublayer(moodLayer)
        moodLayer.addSublayer(spriteLayer)
        for l in [spriteLayer, tintMask] {
            l.contentsGravity = .resizeAspect
            l.magnificationFilter = .nearest
            l.minificationFilter = .nearest
        }
        spriteLayer.addSublayer(tintLayer)
        tintLayer.backgroundColor = NSColor.systemRed.withAlphaComponent(0.42).cgColor
        tintLayer.mask = tintMask
        tintLayer.isHidden = true
        spriteLayer.shadowColor = NSColor.systemRed.cgColor
        spriteLayer.shadowOffset = .zero
        spriteLayer.shadowRadius = 7
        spriteLayer.shadowOpacity = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        bobLayer.frame = b
        moodLayer.frame = b
        let w = spriteSize.width, h = spriteSize.height
        spriteLayer.frame = CGRect(x: ((b.width - w) / 2).rounded(), y: 3, width: w, height: h)
        tintLayer.frame = spriteLayer.bounds
        tintMask.frame = tintLayer.bounds
        hitLayer.frame = spriteLayer.frame.insetBy(dx: -4, dy: -3)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        [spriteLayer, tintMask].forEach { $0.contentsScale = s }
    }

    func setAnimation(_ anim: SpriteAnimation?) {
        guard anim !== currentAnim else { return }
        currentAnim = anim
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.removeAnimation(forKey: "frames")
        tintMask.removeAnimation(forKey: "frames")
        spriteLayer.contents = anim?.frames.first
        tintMask.contents = anim?.frames.first
        if let anim, anim.isAnimated {
            let ka = CAKeyframeAnimation(keyPath: "contents")
            ka.values = anim.frames
            ka.keyTimes = anim.keyTimes.map { NSNumber(value: $0) }
            ka.calculationMode = .discrete
            ka.duration = anim.duration
            ka.repeatCount = .infinity
            ka.isRemovedOnCompletion = false
            spriteLayer.add(ka, forKey: "frames")
            tintMask.add(ka, forKey: "frames")
        }
        CATransaction.commit()
    }

    func setMood(_ mood: PetMood) {
        guard mood != currentMood else { return }
        currentMood = mood
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bobLayer.removeAllAnimations()
        moodLayer.removeAllAnimations()
        spriteLayer.removeAnimation(forKey: "glow")
        tintLayer.isHidden = mood != .overheated
        spriteLayer.shadowOpacity = 0

        let (period, amp): (Double, Double) = {
            switch mood {
            case .calm: return (2.8, 2)
            case .normal: return (2.0, 3)
            case .excited: return (1.4, 3.5)
            case .overheated: return (1.0, 2.5)
            }
        }()
        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        bob.fromValue = 0
        bob.toValue = amp
        bob.duration = period / 2
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bob.isRemovedOnCompletion = false
        bobLayer.add(bob, forKey: "bob")

        switch mood {
        case .excited:
            let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
            hop.values = [0, 9, 0, 4, 0, 0]
            hop.keyTimes = [0, 0.16, 0.32, 0.42, 0.52, 1]
            hop.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn),
                CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn),
                CAMediaTimingFunction(name: .linear),
            ]
            hop.duration = 1.6
            hop.repeatCount = .infinity
            hop.isRemovedOnCompletion = false
            moodLayer.add(hop, forKey: "mood")
        case .overheated:
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.values = [0, -2.5, 2.5, -2.5, 2.5, -1.5, 0, 0]
            shake.keyTimes = [0, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 1]
            shake.duration = 1.3
            shake.repeatCount = .infinity
            shake.isRemovedOnCompletion = false
            moodLayer.add(shake, forKey: "mood")
            let glow = CABasicAnimation(keyPath: "shadowOpacity")
            glow.fromValue = 0.45
            glow.toValue = 1.0
            glow.duration = 0.8
            glow.autoreverses = true
            glow.repeatCount = .infinity
            glow.isRemovedOnCompletion = false
            spriteLayer.shadowOpacity = 0.7
            spriteLayer.add(glow, forKey: "glow")
        default:
            break
        }
        CATransaction.commit()
    }
}

struct PetSpriteView: NSViewRepresentable {
    var animation: SpriteAnimation?
    var mood: PetMood
    var spriteSize: CGSize

    func makeNSView(context: Context) -> PetSpriteNSView { PetSpriteNSView(frame: .zero) }

    func updateNSView(_ v: PetSpriteNSView, context: Context) {
        if v.spriteSize != spriteSize { v.spriteSize = spriteSize }
        v.setAnimation(animation)
        v.setMood(mood)
    }
}
