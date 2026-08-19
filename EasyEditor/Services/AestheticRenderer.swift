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

    /// Glassy tube: hard scanlines, aperture grille, phosphor bloom, no tape
    /// faults at all.
    static let crt = AestheticParams(
        name: "CRT", grain: 0.12, chromaNoise: 0.1, chromaBleed: 0.18,
        scanline: 1.0, ringing: 0.55, wobble: 0, wobbleSpeed: 1,
        snow: 0.04, tear: 0)

    /// Tape: smeared colour, unstable line, head-switch tear, dirty picture,
    /// and no fine scanlines to speak of.
    static let vhs = AestheticParams(
        name: "VHS", grain: 0.5, chromaNoise: 0.55, chromaBleed: 0.8,
        scanline: 0.12, ringing: 0.2, wobble: 0.75, wobbleSpeed: 5.5,
        snow: 0.45, tear: 0.7)

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
        // ntsc-rs intensities are small fractions; scale them into 0…1.
        params.grain = min(1, value("luma_noise_intensity", 0.01) * 25)
        params.chromaNoise = min(1, value("chroma_noise_intensity", 0.1) * 4)
        params.chromaBleed = min(1, value("vhs_chroma_loss", 0) * 3
                                 + abs(value("chroma_delay_horizontal", 0)) * 0.4 + 0.2)
        params.scanline = min(1, value("video_scanline_phase_shift", 0) / 3 + 0.25)
        params.ringing = min(1, value("ringing_power", 2) / 8 + value("vhs_sharpen", 0) / 4)
        params.wobble = min(1, value("vhs_edge_wave", 0) / 4)
        params.wobbleSpeed = max(1, value("vhs_edge_wave_speed", 6))
        params.snow = min(1, value("tracking_noise_noise_intensity", 0) * 0.8)
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
    /// Bundled ntsc-rs preset slug, handed to the Rust processor as-is.
    var presetID: String?
}

enum AestheticRenderer {

    // MARK: - Safety

    /// Generator filters take no input image, so they must be built directly:
    /// CIImage.empty().applyingFilter(…) hands back an empty image for them,
    /// and an empty image poisons everything composited afterwards — which
    /// shows up as a completely black frame.
    private static func generate(_ name: String, _ parameters: [String: Any]) -> CIImage? {
        guard let output = CIFilter(name: name, parameters: parameters)?.outputImage,
              !output.extent.isEmpty else { return nil }
        return output
    }

    /// Adopt a step only if it produced something real. One filter failing
    /// should cost a detail, never the picture.
    private static func step(_ image: CIImage, _ transform: (CIImage) -> CIImage?) -> CIImage {
        guard let candidate = transform(image), !candidate.extent.isEmpty else { return image }
        return candidate
    }

    private static func fade(_ image: CIImage, _ alpha: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
        ])
    }

    private static func channel(_ image: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    // MARK: - Backdrop

    /// The ground the picture sits on: a dark field with the mode's glow,
    /// drifting snow, scanlines, and a slow smeared ghost of the picture.
    static func backdrop(_ config: AestheticFrameConfig, canvas: CGRect,
                         time: Double, ghost: CIImage?) -> CIImage {
        let tint = config.mode.tint
        let strength = max(0, min(1, config.strength))
        var image = CIImage(color: CIColor(red: 0.01, green: 0.01, blue: 0.014))
            .cropped(to: canvas)

        // Centre glow, like a tube warming the middle of the screen.
        if let glow = generate("CIRadialGradient", [
            kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
            "inputRadius0": 0,
            "inputRadius1": max(canvas.width, canvas.height) * 0.72,
            "inputColor0": CIColor(red: tint.r * strength,
                                   green: tint.g * strength,
                                   blue: tint.b * strength),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0),
        ])?.cropped(to: canvas) {
            image = step(image) {
                glow.applyingFilter("CIAdditionCompositing",
                                    parameters: [kCIInputBackgroundImageKey: $0])
                    .cropped(to: canvas)
            }
        }

        // A ghost of the picture, offset and smeared — the backdrop remembers
        // the frame a beat late, which is what sells the analogue feel.
        if let ghost {
            let drift = CGFloat(sin(time * 0.7)) * canvas.width * 0.012
            let lift = CGFloat(cos(time * 0.43)) * canvas.height * 0.006
            let smeared = ghost
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 26])
                .transformed(by: CGAffineTransform(translationX: drift, y: lift))
                .cropped(to: canvas)
            let faded = fade(smeared, CGFloat(0.22 * strength))
            image = step(image) {
                faded.applyingFilter("CIScreenBlendMode",
                                     parameters: [kCIInputBackgroundImageKey: $0])
                    .cropped(to: canvas)
            }
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
                kCIInputRadiusKey: max(canvas.width, canvas.height) * 0.03,
            ])
            .cropped(to: canvas)
        guard !bloom.extent.isEmpty else { return nil }
        return fade(bloom, CGFloat(min(1, amount)))
    }

    // MARK: - The treatment itself

    /// `weight` 1 = the backdrop's full dose; ~0.38 = the lighter pass the
    /// picture gets, so the frame reads as doused without the footage
    /// disappearing under it.
    static func treat(_ input: CIImage, _ config: AestheticFrameConfig,
                      canvas: CGRect, time: Double, weight: Double) -> CIImage {
        let p = config.params
        let s = max(0, min(1, config.strength)) * weight
        guard s > 0.01, !input.extent.isEmpty else { return input }
        var image = input

        // The Metal kernel handles everything that needs per-line geometry —
        // curvature, wobble, tear — which a filter chain simply cannot do.
        let modeIndex: Int
        switch config.mode {
        case .crt: modeIndex = 0
        case .vhs: modeIndex = 1
        case .ntsc: modeIndex = 2
        case .none: modeIndex = -1
        }
        var kernelHandled = false
        // CRT is crtemu's tube, ported whole.
        if config.mode == .crt,
           let tube = AestheticKernel.shared.applyCRT(to: image, canvas: canvas,
                                                      strength: s, time: time),
           !tube.extent.isEmpty {
            return tube.cropped(to: canvas)
        }
        // NTSC goes through the real ntsc-rs, driven by the preset itself.
        if config.mode == .ntsc, weight > 0.5,
           let processed = NtscRSProcessor.shared.process(image, canvas: canvas,
                                                          presetID: config.presetID,
                                                          frame: Int(time * 30)) {
            let blend = CGFloat(min(1, max(0, s)))
            image = blend >= 0.99
                ? processed
                : step(image) { source in
                    fade(processed, blend).composited(over: source).cropped(to: canvas)
                }
            kernelHandled = true
        }
        if !kernelHandled, modeIndex >= 0,
           let shaded = AestheticKernel.shared.apply(to: image, canvas: canvas,
                                                     mode: modeIndex, strength: s,
                                                     time: time, params: p),
           !shaded.extent.isEmpty {
            image = shaded.cropped(to: canvas)
            kernelHandled = true
        }

        // Chroma separation: red and blue pull apart along the line.
        let bleed = CGFloat(p.chromaBleed * s * 5)
        if !kernelHandled, bleed > 0.5 {
            image = step(image) { source in
                let red = channel(source, r: 1, g: 0, b: 0)
                    .transformed(by: CGAffineTransform(translationX: -bleed, y: 0))
                let green = channel(source, r: 0, g: 1, b: 0)
                let blue = channel(source, r: 0, g: 0, b: 1)
                    .transformed(by: CGAffineTransform(translationX: bleed, y: 0))
                return red
                    .applyingFilter("CIAdditionCompositing",
                                    parameters: [kCIInputBackgroundImageKey: green])
                    .applyingFilter("CIAdditionCompositing",
                                    parameters: [kCIInputBackgroundImageKey: blue])
                    .cropped(to: canvas)
            }
        }

        // Ringing: the overshoot analogue gear leaves around hard edges.
        if p.ringing * s > 0.05 {
            image = step(image) {
                $0.applyingFilter("CISharpenLuminance", parameters: [
                    kCIInputSharpnessKey: p.ringing * s * 1.5,
                ]).cropped(to: canvas)
            }
        }

        // Tape wobble: the frame breathes sideways.
        let wobble = CGFloat(p.wobble * s) * canvas.width * 0.012
        if !kernelHandled, wobble > 0.3 {
            let shift = wobble * CGFloat(sin(time * p.wobbleSpeed)
                                         + 0.4 * sin(time * p.wobbleSpeed * 2.7))
            image = step(image) {
                $0.clampedToExtent()
                    .transformed(by: CGAffineTransform(translationX: shift, y: 0))
                    .cropped(to: canvas)
            }
        }

        // Head-switch tear: the bottom band slips out of line.
        if !kernelHandled, p.tear * s > 0.06 {
            let bandHeight = canvas.height * CGFloat(0.02 + 0.05 * p.tear)
            let band = CGRect(x: canvas.minX, y: canvas.minY,
                              width: canvas.width, height: bandHeight)
            let slip = CGFloat(6 + 26 * p.tear * s) * CGFloat(sin(time * 3.1) * 0.5 + 0.5)
            image = step(image) { source in
                let torn = source.cropped(to: band)
                    .transformed(by: CGAffineTransform(translationX: slip, y: 0))
                    .cropped(to: band)
                guard !torn.extent.isEmpty else { return nil }
                return torn.composited(over: source).cropped(to: canvas)
            }
        }

        // Scanlines.
        if !kernelHandled, p.scanline * s > 0.03 {
            let lineHeight = max(1.5, canvas.height / 480)
            let dark = CGFloat(1 - min(0.6, p.scanline * s * 0.7))
            if let stripes = generate("CIStripesGenerator", [
                kCIInputCenterKey: CIVector(x: 0, y: 0),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1),
                "inputColor1": CIColor(red: dark, green: dark, blue: dark),
                kCIInputWidthKey: lineHeight,
                kCIInputSharpnessKey: 0.6,
            ])?
                .transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
                .cropped(to: canvas), !stripes.extent.isEmpty {
                image = step(image) {
                    $0.applyingFilter("CIMultiplyBlendMode",
                                      parameters: [kCIInputBackgroundImageKey: stripes])
                        .cropped(to: canvas)
                }
            }
        }

        // Grain and snow, drifting frame to frame.
        let noiseAmount = (p.grain * 0.5 + p.snow) * s
        if !kernelHandled, noiseAmount > 0.02,
           let random = generate("CIRandomGenerator", [:]) {
            let jitterX = CGFloat((time * 137).truncatingRemainder(dividingBy: 512))
            let jitterY = CGFloat((time * 271).truncatingRemainder(dividingBy: 512))
            let noise = random
                .transformed(by: CGAffineTransform(translationX: jitterX, y: jitterY))
                .cropped(to: canvas)
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: p.chromaNoise,
                ])
            let faded = fade(noise, CGFloat(min(0.3, noiseAmount * 0.35)))
            image = step(image) {
                faded.applyingFilter("CIScreenBlendMode",
                                     parameters: [kCIInputBackgroundImageKey: $0])
                    .cropped(to: canvas)
            }
        }

        switch config.mode {
        case .crt:
            // Aperture grille: fine vertical mask under the scanlines.
            let cell = max(2.0, canvas.width / 420)
            let dim = CGFloat(1 - min(0.35, 0.4 * s))
            if !kernelHandled, let grille = generate("CIStripesGenerator", [
                kCIInputCenterKey: CIVector(x: 0, y: 0),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1),
                "inputColor1": CIColor(red: dim, green: dim, blue: dim),
                kCIInputWidthKey: cell,
                kCIInputSharpnessKey: 0.35,
            ])?.cropped(to: canvas) {
                image = step(image) {
                    $0.applyingFilter("CIMultiplyBlendMode",
                                      parameters: [kCIInputBackgroundImageKey: grille])
                        .cropped(to: canvas)
                }
            }
            // Phosphor glow.
            image = step(image) {
                $0.applyingFilter("CIBloom", parameters: [
                    kCIInputIntensityKey: 0.9 * s,
                    kCIInputRadiusKey: 12,
                ]).cropped(to: canvas)
            }

        case .vhs:
            // Chroma smear: colour dragged sideways off the luma, which is
            // the single most recognisable thing tape does.
            let smear = CGFloat(6 + 26 * s)
            image = step(image) { source in
                let dragged = source.clampedToExtent()
                    .applyingFilter("CIMotionBlur", parameters: [
                        kCIInputRadiusKey: smear,
                        kCIInputAngleKey: 0,
                    ])
                    .cropped(to: canvas)
                return dragged.applyingFilter("CIColorBlendMode",
                                              parameters: [kCIInputBackgroundImageKey: source])
                    .cropped(to: canvas)
            }
            // Tape softens the whole picture and drops saturation.
            image = step(image) {
                $0.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1 - 0.22 * s,
                    kCIInputContrastKey: 1 + 0.1 * s,
                ]).cropped(to: canvas)
            }

        case .ntsc:
            // Dot crawl: chroma shimmering along the line, frame to frame.
            let crawl = CGFloat(2 + 7 * s) * CGFloat(sin(time * 9) * 0.5 + 0.5)
            image = step(image) { source in
                let shifted = source.clampedToExtent()
                    .transformed(by: CGAffineTransform(translationX: crawl, y: 0))
                    .cropped(to: canvas)
                return shifted.applyingFilter("CIColorBlendMode",
                                              parameters: [kCIInputBackgroundImageKey: source])
                    .cropped(to: canvas)
            }

        case .none:
            break
        }
        image = step(image) {
            $0.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: 0.8 * s,
                kCIInputRadiusKey: 1.7,
            ]).cropped(to: canvas)
        }

        return image.cropped(to: canvas)
    }
}
