import Foundation
import CoreGraphics
import SwiftUI

// MARK: - Clip kinds & lanes

enum ClipKind: String, Codable {
    case video      // primary storyline or connected b-roll
    case image      // connected still image overlay
    case title      // connected text (titles + captions share the lane)
    case music      // connected audio below the storyline
    case voiceover  // recorded narration
    case sfx        // short sound effect
}

/// FCP-style layers, top to bottom as drawn in the timeline.
/// `primary` is the magnetic storyline; everything else is a connected clip.
enum Lane: String, Codable, CaseIterable {
    case titles     // purple, 1/5 the height of the primary lane
    case images     // 1/3 the height of the primary lane
    case broll      // 1/2 the height of the primary lane
    case primary    // the magnetic storyline
    case voice      // voiceover + SFX, below the storyline
    case music      // green, FCP style

    var isAboveStoryline: Bool {
        self == .titles || self == .images || self == .broll
    }

    var isAudio: Bool { self == .voice || self == .music }

    /// Which lanes a clip of a given kind is allowed to occupy (drag targets).
    static func allowed(for kind: ClipKind) -> [Lane] {
        switch kind {
        case .video: return [.primary, .broll]
        case .image: return [.images]
        case .title: return [.titles]
        case .music: return [.music, .voice]
        case .voiceover, .sfx: return [.voice, .music]
        }
    }
}

// MARK: - Canvas

enum AspectPreset: String, Codable, CaseIterable, Identifiable {
    case portrait916 = "9:16"
    case landscape169 = "16:9"
    case square11 = "1:1"

    var id: String { rawValue }

    var renderSize: CGSize {
        switch self {
        case .portrait916: return CGSize(width: 1080, height: 1920)
        case .landscape169: return CGSize(width: 1920, height: 1080)
        case .square11: return CGSize(width: 1080, height: 1080)
        }
    }
}

// MARK: - Color adjustments (TikTok "Adjust" parity)

struct Adjustments: Codable, Equatable {
    var brightness: Double = 0   // -0.5 ... 0.5
    var contrast: Double = 1     //  0.5 ... 1.5
    var saturation: Double = 1   //  0   ... 2
    // Optional so projects saved by older builds still decode.
    var temp: Double?            // -1 (cool) ... 1 (warm)
    var tint: Double?            // -1 (green) ... 1 (magenta)
    var hue: Double?             // -1 ... 1 (mapped to ±π)
    var vignette: Double?        //  0 ... 1
    var retouch: Double?         //  0 ... 1 (skin-smoothing softener)

    var isIdentity: Bool {
        brightness == 0 && contrast == 1 && saturation == 1
            && (temp ?? 0) == 0 && (tint ?? 0) == 0
            && (hue ?? 0) == 0 && (vignette ?? 0) == 0
            && (retouch ?? 0) == 0
    }
}

// MARK: - Effects (structural Core Image looks, TikTok effect-grid parity)

enum EffectPreset: String, Codable, CaseIterable, Identifiable {
    // Basic
    case blur, pixelate, bloom, sharpen
    // Retro
    case comic, dotScreen, crystallize, thermal, xray, noirEdges
    // Vibe
    case kaleidoscope, zoomBlur, vortex, fisheye, mirror

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .bloom: return "Bloom"
        case .sharpen: return "Sharpen"
        case .comic: return "Comic"
        case .dotScreen: return "Dots"
        case .crystallize: return "Crystal"
        case .thermal: return "Thermal"
        case .xray: return "X-Ray"
        case .noirEdges: return "Edges"
        case .kaleidoscope: return "Kaleido"
        case .zoomBlur: return "Zoom Blur"
        case .vortex: return "Vortex"
        case .fisheye: return "Fisheye"
        case .mirror: return "Mirror"
        }
    }

    var systemImage: String {
        switch self {
        case .blur: return "drop.halffull"
        case .pixelate: return "squareshape.split.3x3"
        case .bloom: return "sparkles"
        case .sharpen: return "triangle"
        case .comic: return "book"
        case .dotScreen: return "circle.grid.3x3.fill"
        case .crystallize: return "hexagon.fill"
        case .thermal: return "flame"
        case .xray: return "bolt.horizontal"
        case .noirEdges: return "scribble.variable"
        case .kaleidoscope: return "asterisk"
        case .zoomBlur: return "dot.radiowaves.left.and.right"
        case .vortex: return "hurricane"
        case .fisheye: return "circle.lefthalf.striped.horizontal"
        case .mirror: return "rectangle.split.2x1"
        }
    }

    var category: String {
        switch self {
        case .blur, .pixelate, .bloom, .sharpen: return "Basic"
        case .comic, .dotScreen, .crystallize, .thermal, .xray, .noirEdges: return "Retro"
        case .kaleidoscope, .zoomBlur, .vortex, .fisheye, .mirror: return "Vibe"
        }
    }

    static var categories: [String] { ["Basic", "Retro", "Vibe"] }
}

// MARK: - Masks (TikTok mask tool)

enum MaskShape: String, Codable, CaseIterable, Identifiable {
    case linear, mirror, circle, rectangle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .mirror: return "Mirror"
        case .circle: return "Circle"
        case .rectangle: return "Rectangle"
        }
    }

    var systemImage: String {
        switch self {
        case .linear: return "rectangle.tophalf.filled"
        case .mirror: return "rectangle.split.1x2"
        case .circle: return "circle"
        case .rectangle: return "rectangle"
        }
    }
}

/// Geometry in unit canvas coordinates (y down, like placements).
struct MaskSettings: Codable, Equatable {
    var shape: MaskShape = .circle
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var size: Double = 0.5      // fraction of the smaller canvas dimension
    var feather: Double = 0.15  // 0 ... 0.5
    var isInverted = false
}

// MARK: - Filters (TikTok filter parity, Core Image based)

enum FilterPreset: String, Codable, CaseIterable, Identifiable {
    case none, vivid, warm, cool, mono, noir, fade, chrome, instant, transfer, sepia

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "Original"
        default: return rawValue.capitalized
        }
    }

    /// nil means "build by hand" (vivid/warm/cool use CIColorControls / temperature).
    var ciFilterName: String? {
        switch self {
        case .none, .vivid, .warm, .cool: return nil
        case .mono: return "CIPhotoEffectMono"
        case .noir: return "CIPhotoEffectNoir"
        case .fade: return "CIPhotoEffectFade"
        case .chrome: return "CIPhotoEffectChrome"
        case .instant: return "CIPhotoEffectInstant"
        case .transfer: return "CIPhotoEffectTransfer"
        case .sepia: return "CISepiaTone"
        }
    }
}

// MARK: - Transitions

enum TransitionStyle: String, Codable, CaseIterable, Identifiable {
    case none, crossDissolve, fadeToBlack, slideLeft, slideRight, zoom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .crossDissolve: return "Dissolve"
        case .fadeToBlack: return "Fade to Black"
        case .slideLeft: return "Slide Left"
        case .slideRight: return "Slide Right"
        case .zoom: return "Zoom"
        }
    }

    var systemImage: String {
        switch self {
        case .none: return "square"
        case .crossDissolve: return "square.on.square.intersection.dashed"
        case .fadeToBlack: return "moon.fill"
        case .slideLeft: return "arrow.left.square"
        case .slideRight: return "arrow.right.square"
        case .zoom: return "plus.magnifyingglass"
        }
    }
}

struct Transition: Codable, Equatable {
    var style: TransitionStyle = .crossDissolve
    var duration: Double = 0.5

    /// Engine overlap between adjacent clips. `none` butts clips together.
    var overlap: Double { style == .none ? 0 : duration }
}

// MARK: - Text

struct TextStyleModel: Codable, Equatable {
    var fontName: String = "TikTokSans-Bold"
    var fontSize: Double = 72          // points at 1080p canvas scale
    var colorHex: String = "#FFFFFF"
    var backgroundHex: String? = nil   // nil = no plate behind the text
    var hasShadow: Bool = true
    /// TikTok-style heavy black stroke around the glyphs (optional so old
    /// projects decode).
    var outline: Bool? = nil

    static let title = TextStyleModel()
    static let caption = TextStyleModel(fontName: "TikTokSans-SemiBold",
                                        fontSize: 44,
                                        colorHex: "#FFFFFF",
                                        backgroundHex: "#000000B4",
                                        hasShadow: false)
}

struct TextPayload: Codable, Equatable {
    var string: String = "Title"
    var style: TextStyleModel = .title
}

/// Where a connected image/title sits on the canvas, in unit coordinates
/// (0,0 = top-left, 1,1 = bottom-right; y grows downward like UIKit).
struct OverlayPlacement: Codable, Equatable {
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var widthFraction: Double = 0.8    // overlay width as a fraction of canvas width
    var opacity: Double = 1

    static let title = OverlayPlacement(centerX: 0.5, centerY: 0.4, widthFraction: 0.9)
    static let caption = OverlayPlacement(centerX: 0.5, centerY: 0.82, widthFraction: 0.9)
    static let image = OverlayPlacement(centerX: 0.5, centerY: 0.5, widthFraction: 0.6)
}

// MARK: - Aesthetics (CRT / VHS / NTSC treatment)

enum AestheticMode: String, Codable, CaseIterable, Identifiable {
    case none, crt, vhs, ntsc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .crt: return "CRT"
        case .vhs: return "VHS"
        case .ntsc: return "NTSC"
        }
    }

    var systemImage: String {
        switch self {
        case .none: return "circle.slash"
        case .crt: return "tv"
        case .vhs: return "recordingtape"
        case .ntsc: return "antenna.radiowaves.left.and.right"
        }
    }

    /// The glow a backdrop of this kind throws.
    var tint: (r: Double, g: Double, b: Double) {
        switch self {
        case .none: return (0, 0, 0)
        case .crt: return (0.10, 0.55, 0.22)   // phosphor green
        case .vhs: return (0.32, 0.12, 0.42)   // magenta-violet bloom
        case .ntsc: return (0.14, 0.20, 0.50)  // blue broadcast cast
        }
    }
}

/// Project-wide look. The backdrop wears the effect fully; the picture over it
/// wears a lighter version, so the whole frame reads as doused in it without
/// the footage disappearing.
struct AestheticSettings: Codable, Equatable {
    var mode: AestheticMode = .none
    /// Bundled ntsc-rs preset slug driving the parameters.
    var presetID: String?
    /// 0…1, scales everything. At 1 the frame wears exactly the look shown on
    /// the gallery tile.
    var strength: Double = 0.85
    /// How much the picture spills light into the backdrop.
    var caustics: Double = 0.5
    /// Camera takes usually shouldn't smear the room with their own glow.
    var excludeCameraTakes: Bool = true

    var isActive: Bool { mode != .none && strength > 0.01 }
}

// MARK: - Blend modes

enum BlendMode: String, Codable, CaseIterable, Identifiable {
    case normal, screen, multiply, overlay, add
    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    /// nil = ordinary source-over compositing.
    var ciFilterName: String? {
        switch self {
        case .normal: return nil
        case .screen: return "CIScreenBlendMode"
        case .multiply: return "CIMultiplyBlendMode"
        case .overlay: return "CIOverlayBlendMode"
        case .add: return "CIAdditionCompositing"
        }
    }
}

// MARK: - Background removal

enum CutoutMode: String, Codable, CaseIterable, Identifiable {
    case person = "Person"        // Vision person segmentation, per frame
    case subject = "Auto Subject" // Vision subject lift (images)
    case whiteKey = "White BG"    // key out near-white
    case blackKey = "Black BG"    // key out near-black
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .person: return "person.crop.rectangle"
        case .subject: return "wand.and.rays"
        case .whiteKey: return "square.dashed"
        case .blackKey: return "square.dashed.inset.filled"
        }
    }
}

// MARK: - Easing

enum EasingCurve: String, Codable, CaseIterable, Identifiable {
    case none, sine, quad, cubic, quart, quint, expo, circ, back, elastic, bounce
    var id: String { rawValue }
    var displayName: String { rawValue == "none" ? "None" : rawValue.capitalized }
}

// MARK: - In/Out entrance & exit animations (connected clips only)

enum AnchorPoint: String, Codable, CaseIterable, Identifiable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    var id: String { rawValue }

    /// Off-screen direction in unit canvas coordinates (y down).
    var direction: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: -1, y: -1)
        case .top: return CGPoint(x: 0, y: -1)
        case .topRight: return CGPoint(x: 1, y: -1)
        case .left: return CGPoint(x: -1, y: 0)
        case .center: return .zero
        case .right: return CGPoint(x: 1, y: 0)
        case .bottomLeft: return CGPoint(x: -1, y: 1)
        case .bottom: return CGPoint(x: 0, y: 1)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        }
    }
}

enum SpeedPreset: String, Codable, CaseIterable, Identifiable {
    case standard = "Default", snappy = "Snappy", clean = "Clean", slow = "Slow", custom = "Custom"
    var id: String { rawValue }
}

enum MotionPresetChoice: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case leftRight = "Left → Right"
    case rightLeft = "Right → Left"
    case upDown = "Up → Down"
    case downUp = "Down → Up"
    case scaleRotation = "Scale+Rotation"
    case custom = "Custom"
    var id: String { rawValue }
}

/// One end of the clip (beginning or end): what animates and how.
struct EndConfig: Codable, Equatable {
    var anchor: AnchorPoint = .center
    /// "In"/"Out" are the ends of the motion *curve*, not of the clip.
    /// In = none gives the snappy default.
    var easeIn: EasingCurve = .none
    var easeOut: EasingCurve = .expo
    var durationFrames: Double = 30      // at 30 fps
    var animateScale = true
    var animateRotation = false
    var animatePosition = false
    // Overrides for the hidden-end values (defaults per spec).
    var scaleValue: Double = 0           // scale when fully hidden
    var rotationDegrees: Double = 180    // begin animates from -this, end to +this
    var positionDistance: Double = 1.1   // × canvas size, off-screen at anchor

    var durationSeconds: Double { max(1, durationFrames) / 30 }
}

/// Focus treatment applied to the *main track* while this clip is visible.
enum FocusStyle: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case blur = "Blur"
    case darken = "Darken"
    case blurDarken = "BL+DK"
    case pixelate = "Pixelate"
    case pixelateDarken = "PIX+DK"
    var id: String { rawValue }

    var blurs: Bool { self == .blur || self == .blurDarken }
    var darkens: Bool { self == .darken || self == .blurDarken || self == .pixelateDarken }
    var pixelates: Bool { self == .pixelate || self == .pixelateDarken }
}

struct InOutSettings: Codable, Equatable {
    var isEnabled = true
    var isGlobal = false
    var speedPreset: SpeedPreset = .standard
    var motionPreset: MotionPresetChoice = .none
    var begin = EndConfig()
    var end = EndConfig()

    mutating func applySpeedPreset(_ preset: SpeedPreset) {
        speedPreset = preset
        let config: (frames: Double, easeIn: EasingCurve, easeOut: EasingCurve)
        switch preset {
        case .standard: config = (30, .none, .expo)
        case .snappy: config = (8, .none, .back)
        case .clean: config = (60, .expo, .expo)
        case .slow: config = (30, .sine, .sine)
        case .custom: return
        }
        begin.durationFrames = config.frames
        begin.easeIn = config.easeIn
        begin.easeOut = config.easeOut
        end.durationFrames = config.frames
        end.easeIn = config.easeIn
        end.easeOut = config.easeOut
    }

    mutating func applyMotionPreset(_ preset: MotionPresetChoice) {
        motionPreset = preset
        func setMotion(beginAnchor: AnchorPoint, endAnchor: AnchorPoint,
                       scale: Bool, rotation: Bool, position: Bool) {
            begin.anchor = beginAnchor; end.anchor = endAnchor
            begin.animateScale = scale; end.animateScale = scale
            begin.animateRotation = rotation; end.animateRotation = rotation
            begin.animatePosition = position; end.animatePosition = position
        }
        switch preset {
        case .none: setMotion(beginAnchor: .center, endAnchor: .center,
                              scale: true, rotation: false, position: false)
        case .leftRight: setMotion(beginAnchor: .left, endAnchor: .right,
                                   scale: false, rotation: false, position: true)
        case .rightLeft: setMotion(beginAnchor: .right, endAnchor: .left,
                                   scale: false, rotation: false, position: true)
        case .upDown: setMotion(beginAnchor: .top, endAnchor: .bottom,
                                scale: false, rotation: false, position: true)
        case .downUp: setMotion(beginAnchor: .bottom, endAnchor: .top,
                                scale: false, rotation: false, position: true)
        case .scaleRotation: setMotion(beginAnchor: .center, endAnchor: .center,
                                       scale: true, rotation: true, position: false)
        case .custom: break
        }
    }
}

// MARK: - Looping animation (connected clips only)

enum LoopPreset: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case shake = "Camera Shake"
    case spin = "360 Spin"
    case wobble = "Wobble"
    case pulse = "Pulsation"
    case floating = "Floating"
    case pixelPulse = "Pixel Pulse"
    case glitch = "Glitch"
    case jello = "Jello"
    case oscillation = "Oscillation"
    var id: String { rawValue }
}

enum OscillationMode: String, Codable, CaseIterable, Identifiable {
    case leftRight = "Left / Right"
    case upDown = "Up / Down"
    case rotation = "Rotation"
    var id: String { rawValue }
}

enum LoopType: String, Codable, CaseIterable, Identifiable {
    case pingPong = "Ping-Pong"
    case restart = "Loop"
    var id: String { rawValue }
}

struct LoopAnimationSettings: Codable, Equatable {
    var preset: LoopPreset = .none
    var isGlobal = false
    var amount: Double = 18       // canvas points at 1080p scale (or degrees / %)
    var speed: Double = 40        // period ≈ 60/speed seconds
    var easing: EasingCurve = .sine
    var loopType: LoopType = .pingPong
    var phase: Double = 0         // seconds
    var mode: OscillationMode = .leftRight

    var period: Double { max(0.15, 60 / max(1, speed)) }
}

// MARK: - Compositing (drop shadow / glow / outline / blur)

enum CompositingEffect: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case dropShadow = "Drop Shadow"
    case glow = "Glow"
    case outline = "Outline"
    case blur = "Blur"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .none: return "circle.slash"
        case .dropShadow: return "square.fill.on.square"
        case .glow: return "rays"
        case .outline: return "square.dashed"
        case .blur: return "drop.halffull"
        }
    }
}

struct CompositingSettings: Codable, Equatable {
    var effect: CompositingEffect = .dropShadow
    var offsetX: Double = 12      // canvas points at 1080p scale
    var offsetY: Double = 18
    var blur: Double = 24
    var opacity: Double = 0.75
    var spread: Double = 0
    var colorHex: String = "#000000"
}

// MARK: - Color helpers

extension Color {
    /// "#RRGGBB" or "#RRGGBBAA".
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = Double((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(v & 0xFF) / 255 : 1
        self = Color(red: r, green: g, blue: b, opacity: a)
    }

    static func fromHex(_ hex: String, fallback: Color = .white) -> Color {
        Color(hex: hex) ?? fallback
    }
}
