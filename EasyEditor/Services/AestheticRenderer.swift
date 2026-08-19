import Foundation
import CoreImage
import CoreGraphics

/// Real-time CRT / VHS / NTSC treatment.
///
/// The parameters come from bundled **ntsc-rs presets** — the same JSON the
/// desktop toolchain uses — but the rendering here is a Core Image emulation
/// of that look, not ntsc-rs itself: ntsc-rs is a Rust pipeline and can't run
/// per frame on the phone. The preset drives grain, chroma noise, ringing,
/// scanlines, tape wobble and head-switch tearing; the emulation reproduces
/// those on the GPU.
struct AestheticParams: Equatable {
    var name: String = "Default"
    var grain: Double = 0.25        // luma noise
    var chromaNoise: Double = 0.3   // colour speckle
    var chromaBleed: Double = 0.35  // RGB separation
    var scanline: Double = 0.5      // line darkening
    var ringing: Double = 0.3       // edge sharpening/halo
    var wobble: Double = 0.3        // horizontal instability
    var wobbleSpeed: Double = 6
    var snow: Double = 0.2          // tracking noise
    var tear: Double = 0.2          // head-switch band at the bottom

    /// Read the fields we can emulate out of an ntsc-rs preset.
    static func from(presetJSON json: [String: Any], name: String) -> AestheticParams {
        func value(_ key: String, _ fallback: Double) -> Double {
            if let number = json[key] as? Double { return number }
            if let number = json[key] as? Int { return Double(number) }
            if let flag = json[key] as? Bool { return flag ? 1 : 0 }
            return fallback
        }
        var params = AestheticParams()
        params.name = name
        // ntsc-rs intensities are small fractions; scale them into 0…1 range.
        params.grain = min(1, value("luma_noise_intensity", 0.01) * 25)
        params.chromaNoise = min(1, value("chroma_noise_intensity", 0.1) * 4)
        params.chromaBleed = min(1, value("vhs_chroma_loss", 0) * 3
                                 + abs(value("chroma_delay_horizontal", 0)) * 0.4
                                 + 0.2)
        params.scanline = min(1, value("video_scanline_phase_shift", 0) / 3 + 0.25)
        params.ringing = min(1, value("ringing_power", 2) / 8
                             + value("vhs_sharpen", 0) / 4)
        params.wobble = min(1, value("vhs_edge_wave", 0) / 4)
        params.wobbleSpeed = max(1, value("vhs_edge_wave_speed", 6))
        params.snow = min(1, value("tracking_noise_noise_intensity", 0) * 0.8
                          + value("composite_noise", 0) * 0.1)
        params.tear = min(1, value("head_switching_height", 0) / 40)
        return params
    }
}

/// A bundled preset, discovered at launch.
struct AestheticPreset: Identifiable, Equatable {
    let id: String          // file slug
    let name: String
    let params: AestheticParams
}

enum AestheticLibrary {
    /// Loaded once; the JSON is a couple of KB each.
    static let presets: [AestheticPreset] = load()

    static func preset(id: String?) -> AestheticPreset? {
        guard let id else { return presets.first }
        return presets.first { $0.id == id } ?? presets.first
    }

    private static func load() -> [AestheticPreset] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json",
                                          subdirectory: nil) else { return [] }
        var found: [AestheticPreset] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  // Our presets carry _name; other bundled JSON doesn't.
                  let name = json["_name"] as? String else { continue }
            let slug = url.deletingPathExtension().lastPathComponent
            found.append(AestheticPreset(id: slug, name: name,
                                         params: .from(presetJSON: json, name: name)))
        }
        return found.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
}

/// Per-frame configuration handed to the compositor.
struct AestheticFrameConfig: Equatable {
    var mode: AestheticMode
    var params: AestheticParams
    var strength: Double
    var caustics: Double
}

enum AestheticRenderer {

    // MARK: - Backdrop

    /// The ground the picture sits on: a dark field with the mode's glow,
    /// scanlines, drifting snow, and a slow ghost of the picture itself.
    static func backdrop(_ config: AestheticFrameConfig, canvas: CGRect,
                         time: Double, ghost: CIImage?) -> CIImage {
        let tint = config.mode.tint
        let strength = config.strength
        var image = CIImage(color: CIColor(red: 0.008, green: 0.008, blue: 0.012))
            .cropped(to: canvas)

        // Centre glow, like a tube warming the middle of the screen.
        let glow = CIImage.empty().applyingFilter("CIRadialGradient", parameters: [
            kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
            "inputRadius0": 0,
            "inputRadius1": max(canvas.width, canvas.height) * 0.72,
            "inputColor0": CIColor(red: tint.r * strength, green: tint.g * strength,
                                   blue: tint.b * strength),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0),
        ]).cropped(to: canvas)
        image = glow.applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: image,
        ])

        // A ghost of the picture, offset and smeared — the backdrop remembers
        // the frame a beat late, which is what sells VHS.
        if let ghost, config.mode != .none {
            let drift = CGFloat(sin(time * 0.7)) * canvas.width * 0.012
            let lift = CGFloat(cos(time * 0.43)) * canvas.height * 0.006
            let smeared = ghost
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 26])
                .cropped(to: canvas)
                .transformed(by: CGAffineTransform(translationX: drift, y: lift))
            let alpha = CGFloat(0.22 * strength)
            let faded = smeared.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ])
            image = faded.applyingFilter("CIScreenBlendMode", parameters: [
                kCIInputBackgroundImageKey: image,
            ]).cropped(to: canvas)
        }

        // The backdrop wears the treatment at full weight.
        return treat(image, config, canvas: canvas, time: time, weight: 1)
    }

    // MARK: - Caustic spill

    /// Light thrown off the picture onto everything behind it.
    static func caustics(from source: CIImage, canvas: CGRect, amount: Double) -> CIImage? {
        guard amount > 0.01 else { return nil }
        let bloom = source
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: max(canvas.width, canvas.height) * 0.035,
            ])
            .cropped(to: canvas)
        let gain = CGFloat(amount)
        return bloom.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: gain * 0.85),
        ])
    }

    // MARK: - The treatment itself

    /// `weight` 1 = the backdrop's full dose, ~0.35 = the lighter pass the
    /// picture gets, so the whole frame reads as doused without the footage
    /// disappearing under it.
    static func treat(_ input: CIImage, _ config: AestheticFrameConfig,
                      canvas: CGRect, time: Double, weight: Double) -> CIImage {
        let p = config.params
        let s = config.strength * weight
        guard s > 0.01 else { return input }
        var image = input

        // Chroma separation: red and blue pull apart along the line.
        let bleed = CGFloat(p.chromaBleed * s * 6)
        if bleed > 0.4 {
            let red = channel(image, r: 1, g: 0, b: 0)
                .transformed(by: CGAffineTransform(translationX: -bleed, y: 0))
            let blue = channel(image, r: 0, g: 0, b: 1)
                .transformed(by: CGAffineTransform(translationX: bleed, y: 0))
            let green = channel(image, r: 0, g: 1, b: 0)
            image = red
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: blue])
                .cropped(to: canvas)
        }

        // Ringing: the overshoot around hard edges on analogue gear.
        if p.ringing * s > 0.05 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: p.ringing * s * 1.6,
            ])
        }

        // Tape wobble: the frame breathes sideways.
        let wobble = CGFloat(p.wobble * s) * canvas.width * 0.012
        if wobble > 0.3 {
            let shift = wobble * CGFloat(sin(time * p.wobbleSpeed)
                                         + 0.4 * sin(time * p.wobbleSpeed * 2.7))
            image = image.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: shift, y: 0))
                .cropped(to: canvas)
        }

        // Head-switch tear: the bottom band slips out of line.
        if p.tear * s > 0.06 {
            let bandHeight = canvas.height * CGFloat(0.02 + 0.05 * p.tear)
            let band = CGRect(x: canvas.minX, y: canvas.minY,
                              width: canvas.width, height: bandHeight)
            let slip = CGFloat(6 + 26 * p.tear * s) * CGFloat(sin(time * 3.1) * 0.5 + 0.5)
            let torn = image.cropped(to: band)
                .transformed(by: CGAffineTransform(translationX: slip, y: 0))
                .cropped(to: band)
            image = torn.composited(over: image)
        }

        // Scanlines.
        if p.scanline * s > 0.03 {
            let lineHeight = max(1.5, canvas.height / 480)
            let dark = CGFloat(1 - min(0.65, p.scanline * s * 0.8))
            let stripes = CIImage.empty().applyingFilter("CIStripesGenerator", parameters: [
                kCIInputCenterKey: CIVector(x: 0, y: 0),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1),
                "inputColor1": CIColor(red: dark, green: dark, blue: dark),
                kCIInputWidthKey: lineHeight,
                kCIInputSharpnessKey: 0.6,
            ])
            .transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
            .cropped(to: canvas)
            image = image.applyingFilter("CIMultiplyBlendMode", parameters: [
                kCIInputBackgroundImageKey: stripes,
            ]).cropped(to: canvas)
        }

        // Grain and snow, drifting frame to frame.
        let noiseAmount = (p.grain * 0.5 + p.snow) * s
        if noiseAmount > 0.02 {
            let jitterX = CGFloat((time * 137).truncatingRemainder(dividingBy: 512))
            let jitterY = CGFloat((time * 271).truncatingRemainder(dividingBy: 512))
            var noise = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
                .cropped(to: canvas)
            if let random = CIFilter(name: "CIRandomGenerator")?.outputImage {
                noise = random
                    .transformed(by: CGAffineTransform(translationX: jitterX, y: jitterY))
                    .cropped(to: canvas)
            }
            let grey = noise.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: p.chromaNoise,
                kCIInputBrightnessKey: 0,
                kCIInputContrastKey: 1,
            ])
            let a = CGFloat(min(0.35, noiseAmount * 0.4))
            let faded = grey.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
            ])
            image = faded.applyingFilter("CIScreenBlendMode", parameters: [
                kCIInputBackgroundImageKey: image,
            ]).cropped(to: canvas)
        }

        // CRT glass: a little bloom and a vignette to round the corners off.
        if config.mode == .crt {
            image = image.applyingFilter("CIBloom", parameters: [
                kCIInputIntensityKey: 0.35 * s,
                kCIInputRadiusKey: 8,
            ]).cropped(to: canvas)
        }
        image = image.applyingFilter("CIVignette", parameters: [
            kCIInputIntensityKey: 0.9 * s,
            kCIInputRadiusKey: 1.6,
        ]).cropped(to: canvas)

        return image.cropped(to: canvas)
    }

    private static func channel(_ image: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }
}
