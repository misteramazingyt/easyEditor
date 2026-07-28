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

    var isIdentity: Bool {
        brightness == 0 && contrast == 1 && saturation == 1
            && (temp ?? 0) == 0 && (tint ?? 0) == 0
            && (hue ?? 0) == 0 && (vignette ?? 0) == 0
    }
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
    var fontName: String = "HelveticaNeue-Bold"
    var fontSize: Double = 72          // points at 1080p canvas scale
    var colorHex: String = "#FFFFFF"
    var backgroundHex: String? = nil   // nil = no plate behind the text
    var hasShadow: Bool = true

    static let title = TextStyleModel()
    static let caption = TextStyleModel(fontName: "HelveticaNeue-Medium",
                                        fontSize: 44,
                                        colorHex: "#FFFFFF",
                                        backgroundHex: "#000000AA",
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
