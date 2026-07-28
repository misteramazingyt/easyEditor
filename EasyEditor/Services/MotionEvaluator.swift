import Foundation
import CoreGraphics

/// Pure math for the animation system: easing curves, in/out entrance and
/// exit interpolation, and looping-preset transforms. Evaluated per frame by
/// the compositor, so any curve shape (elastic, bounce…) works exactly.
enum MotionEvaluator {

    // MARK: - Easing

    /// Ease-in form of each curve, t ∈ 0…1.
    static func easeIn(_ curve: EasingCurve, _ t: Double) -> Double {
        let t = min(1, max(0, t))
        switch curve {
        case .none: return t
        case .sine: return 1 - cos(t * .pi / 2)
        case .quad: return t * t
        case .cubic: return t * t * t
        case .quart: return t * t * t * t
        case .quint: return t * t * t * t * t
        case .expo: return t <= 0 ? 0 : pow(2, 10 * (t - 1))
        case .circ: return 1 - sqrt(max(0, 1 - t * t))
        case .back:
            let c = 1.70158
            return t * t * ((c + 1) * t - c)
        case .elastic:
            if t <= 0 { return 0 }
            if t >= 1 { return 1 }
            return -pow(2, 10 * (t - 1)) * sin((t - 1.075) * (2 * .pi) / 0.3)
        case .bounce:
            return 1 - bounceOut(1 - t)
        }
    }

    private static func bounceOut(_ t: Double) -> Double {
        let n1 = 7.5625, d1 = 2.75
        var t = t
        if t < 1 / d1 { return n1 * t * t }
        if t < 2 / d1 { t -= 1.5 / d1; return n1 * t * t + 0.75 }
        if t < 2.5 / d1 { t -= 2.25 / d1; return n1 * t * t + 0.9375 }
        t -= 2.625 / d1
        return n1 * t * t + 0.984375
    }

    /// Combined curve: `inCurve` shapes the first half, `outCurve` the back
    /// half (the classic in/out split).
    static func combined(_ t: Double, in inCurve: EasingCurve, out outCurve: EasingCurve) -> Double {
        let t = min(1, max(0, t))
        if t < 0.5 {
            return easeIn(inCurve, t * 2) / 2
        }
        return 1 - easeIn(outCurve, (1 - t) * 2) / 2
    }

    // MARK: - Per-frame motion state

    struct MotionState {
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
        var rotation: CGFloat = 0            // radians
        var offset: CGPoint = .zero          // canvas points
        var pixellate: CGFloat = 0           // extra pixellation scale (0 = off)
        var glitchSeed: UInt64 = 0           // nonzero = glitch frame
        var glitchShift: CGFloat = 0

        var isIdentity: Bool {
            scaleX == 1 && scaleY == 1 && rotation == 0 && offset == .zero
                && pixellate == 0 && glitchSeed == 0
        }
    }

    /// Evaluate entrance/exit + loop state for a connected clip at time `t`.
    static func state(at t: Double,
                      clipStart: Double, clipEnd: Double,
                      inOut: InOutSettings?, loop: LoopAnimationSettings?,
                      canvas: CGSize) -> MotionState {
        var state = MotionState()

        if let io = inOut, io.isEnabled {
            // Hidden factor h: 0 = fully on screen, 1 = fully hidden.
            let beginDur = io.begin.durationSeconds
            if t - clipStart < beginDur {
                let p = (t - clipStart) / beginDur
                let h = 1 - combined(p, in: io.begin.easeIn, out: io.begin.easeOut)
                apply(config: io.begin, hidden: h, sign: -1, canvas: canvas, to: &state)
            }
            let endDur = io.end.durationSeconds
            if clipEnd - t < endDur {
                let p = (clipEnd - t) / endDur
                let h = 1 - combined(p, in: io.end.easeIn, out: io.end.easeOut)
                apply(config: io.end, hidden: h, sign: 1, canvas: canvas, to: &state)
            }
        }

        if let loop, loop.preset != .none {
            applyLoop(loop, elapsed: max(0, t - clipStart) + loop.phase,
                      canvas: canvas, to: &state)
        }
        return state
    }

    private static func apply(config: EndConfig, hidden: Double, sign: Double,
                              canvas: CGSize, to state: inout MotionState) {
        let h = min(1.5, max(0, hidden)) // overshoot curves may exceed 0…1
        if config.animateScale {
            let s = 1 + (config.scaleValue - 1) * h
            state.scaleX *= CGFloat(max(0.0001, s))
            state.scaleY *= CGFloat(max(0.0001, s))
        }
        if config.animateRotation {
            state.rotation += CGFloat(sign * config.rotationDegrees * h * .pi / 180)
        }
        if config.animatePosition {
            let direction = config.anchor.direction
            let distance = CGFloat(config.positionDistance * h)
            state.offset.x += direction.x * canvas.width * distance
            state.offset.y += direction.y * canvas.height * distance
        }
    }

    // MARK: Loop presets

    private static func applyLoop(_ loop: LoopAnimationSettings, elapsed: Double,
                                  canvas: CGSize, to state: inout MotionState) {
        let unit = min(canvas.width, canvas.height) / 1080  // amounts are 1080p points
        let amount = CGFloat(loop.amount) * unit
        let period = loop.period
        let cycle = (elapsed / period).truncatingRemainder(dividingBy: 1)

        /// Signed oscillation -1…1 honoring loop type + easing.
        func wave() -> Double {
            let raw: Double
            switch loop.loopType {
            case .pingPong: raw = sin(2 * .pi * cycle)
            case .restart: raw = cycle * 2 - 1
            }
            let shaped = easeIn(loop.easing == .none ? .sine : loop.easing, abs(raw))
            return raw < 0 ? -shaped : shaped
        }

        switch loop.preset {
        case .none:
            break
        case .shake:
            let jitter = amount * 0.35
            state.offset.x += jitter * CGFloat(sin(elapsed * 37) + 0.6 * sin(elapsed * 23 + 1.7))
            state.offset.y += jitter * CGFloat(cos(elapsed * 31 + 0.5) + 0.6 * sin(elapsed * 43))
            state.rotation += 0.004 * CGFloat(sin(elapsed * 29))
        case .spin:
            state.rotation += CGFloat(2 * .pi * (elapsed / period))
        case .wobble:
            state.rotation += CGFloat(Double(amount / unit) * 0.15 * .pi / 180) * CGFloat(wave() * 10)
        case .pulse:
            let s = 1 + 0.01 * Double(amount / unit) * wave()
            state.scaleX *= CGFloat(max(0.05, s))
            state.scaleY *= CGFloat(max(0.05, s))
        case .floating:
            state.offset.x += amount * CGFloat(sin(2 * .pi * elapsed / (period * 1.31)))
            state.offset.y += amount * 0.6 * CGFloat(sin(2 * .pi * elapsed / period + .pi / 3))
        case .pixelPulse:
            state.pixellate = amount * CGFloat(abs(sin(.pi * elapsed / period)))
        case .glitch:
            let slot = UInt64(elapsed * 9)
            var seed = slot &* 6364136223846793005 &+ 1442695040888963407
            seed = (seed >> 30) ^ seed
            if seed % 4 == 0 { // glitch ~25% of slots
                state.glitchSeed = seed
                let r = CGFloat(Double(seed % 1000) / 1000 - 0.5)
                state.glitchShift = amount * 0.8 * r
                state.offset.x += amount * 0.3 * r
            }
        case .jello:
            let phase = (elapsed / period).truncatingRemainder(dividingBy: 1)
            let bounce = abs(sin(.pi * phase))
            state.offset.y -= amount * CGFloat(bounce)
            state.scaleY *= CGFloat(1 - 0.12 * (1 - bounce))
            state.scaleX *= CGFloat(1 + 0.06 * (1 - bounce))
        case .oscillation:
            let s = wave()
            switch loop.mode {
            case .leftRight: state.offset.x += amount * CGFloat(s)
            case .upDown: state.offset.y += amount * CGFloat(s)
            case .rotation: state.rotation += CGFloat(Double(amount / unit) * s * .pi / 180)
            }
        }
    }
}
