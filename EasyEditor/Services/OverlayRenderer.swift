import Foundation
import UIKit
import CoreImage

/// Renders title text and still images into CIImages the compositor can
/// composite per frame. The same rendering path serves preview and export, so
/// what you see is exactly what ships.
enum OverlayRenderer {

    /// Render a text payload at canvas scale, TikTok style: per-line rounded
    /// background bubbles, optional heavy outline, bundled TikTok Sans.
    /// The image is sized to the text.
    static func render(text: TextPayload, canvasWidth: CGFloat) -> CIImage? {
        if text.style.effectiveSkin == .tube {
            return renderTube(text: text, canvasWidth: canvasWidth)
        }
        let style = text.style
        let fontSize = CGFloat(style.fontSize)
        let font = UIFont(name: style.fontName, size: fontSize)
            ?? UIFont.boldSystemFont(ofSize: fontSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = fontSize * 0.06

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: uiColor(hex: style.colorHex) ?? .white,
            .paragraphStyle: paragraph,
        ]
        if style.outline == true {
            // Negative width = stroke AND fill; value is % of font size.
            attributes[.strokeColor] = UIColor.black
            attributes[.strokeWidth] = -6.5
        } else if style.hasShadow && style.backgroundHex == nil {
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = fontSize * 0.1
            shadow.shadowOffset = CGSize(width: 0, height: fontSize * 0.03)
            attributes[.shadow] = shadow
        }

        // Layout with TextKit so we know each line's exact rect (for bubbles).
        let maxWidth = canvasWidth * 0.9
        let storage = NSTextStorage(attributedString:
            NSAttributedString(string: text.string, attributes: attributes))
        let container = NSTextContainer(size: CGSize(width: maxWidth,
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)

        let hasPlate = style.backgroundHex != nil
        let padX = fontSize * (hasPlate ? 0.42 : 0.18)
        let padY = fontSize * (hasPlate ? 0.3 : 0.18)
        let canvas = CGSize(width: ceil(used.width) + padX * 2,
                            height: ceil(used.height) + padY * 2)
        let origin = CGPoint(x: padX - used.minX, y: padY - used.minY)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        let image = renderer.image { _ in
            if let bgHex = style.backgroundHex, let bg = uiColor(hex: bgHex) {
                // One line-hugging rounded bubble per line, filled as a single
                // path so overlaps don't double-darken — the TikTok look.
                let path = UIBezierPath()
                let glyphRange = manager.glyphRange(for: container)
                manager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
                    var plate = usedRect.offsetBy(dx: origin.x, dy: origin.y)
                    plate = plate.insetBy(dx: -fontSize * 0.3, dy: -fontSize * 0.12)
                    let radius = min(plate.height / 2, fontSize * 0.38)
                    path.append(UIBezierPath(roundedRect: plate, cornerRadius: radius))
                }
                bg.setFill()
                path.fill()
            }
            let glyphRange = manager.glyphRange(for: container)
            manager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
        }
        guard let cg = image.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }

    /// Load a still image clip from disk at a sane size for compositing,
    /// optionally removing its background.
    static func render(imageURL: URL, cutout: CutoutMode? = nil) -> CIImage? {
        guard let ui = UIImage(contentsOfFile: imageURL.path)?.scaledDown(maxDimension: 2160),
              let cg = ui.cgImage else { return nil }
        let image = CIImage(cgImage: cg)
        switch cutout {
        case .none:
            return image
        case .subject, .person:
            return CutoutService.subjectCutout(cgImage: cg) ?? image
        case .whiteKey:
            return CutoutService.colorKeyed(image, removeWhite: true)
        case .blackKey:
            return CutoutService.colorKeyed(image, removeWhite: false)
        }
    }

    static func uiColor(hex: String) -> UIColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - Tube captions

extension OverlayRenderer {

    /// The dark an energised tube sits at when it is showing nothing — not
    /// true black, because a tube never is. Taken from the outro renderer,
    /// where it was measured off the reference.
    private static let tubeBlack = UIColor(red: 0.016, green: 0.026, blue: 0.014, alpha: 1)

    /// A caption in a box of its own: constant size whatever the line says, so
    /// captions hold still instead of breathing with the word count. The text
    /// is fitted to the box rather than the box to the text.
    ///
    /// This renders the plate only — the phosphor bloom and the glass go on
    /// per frame in the compositor, where they can move.
    static func renderTube(text: TextPayload, canvasWidth: CGFloat) -> CIImage? {
        let tube = text.style.effectiveTube
        let width = max(160, canvasWidth * tube.widthFraction)
        let height = max(60, width / max(1.4, tube.aspect))
        let inset = height * 0.14

        let color = uiColor(hex: text.style.colorHex) ?? .white
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        // Shrink to fit rather than wrap out of the box: the box is the point.
        let body = text.string.uppercased()
        var size = CGFloat(text.style.fontSize) * (width / 900)
        var attributes: [NSAttributedString.Key: Any] = [:]
        var measured = CGSize.zero
        let limit = CGSize(width: width - inset * 2, height: height - inset * 2)
        for _ in 0..<24 {
            let font = UIFont(name: text.style.fontName, size: size)
                ?? UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
            paragraph.lineSpacing = size * 0.12
            attributes = [.font: font, .foregroundColor: color,
                          .kern: size * 0.06, .paragraphStyle: paragraph]
            measured = (body as NSString).boundingRect(
                with: CGSize(width: limit.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes, context: nil).size
            if measured.height <= limit.height { break }
            size *= 0.92
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                               format: format)
        let image = renderer.image { context in
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            // Slightly rounded, like the corner of a tube rather than a card.
            let plate = UIBezierPath(roundedRect: bounds, cornerRadius: height * 0.09)
            tubeBlack.setFill()
            plate.fill()

            // A faint wash toward the middle: the tube is lit even where the
            // picture is empty.
            context.cgContext.saveGState()
            plate.addClip()
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor(red: 0.10, green: 0.13, blue: 0.20, alpha: 1).cgColor,
                         tubeBlack.cgColor] as CFArray,
                locations: [0, 1]) {
                context.cgContext.drawRadialGradient(
                    gradient,
                    startCenter: CGPoint(x: bounds.midX, y: bounds.midY), startRadius: 0,
                    endCenter: CGPoint(x: bounds.midX, y: bounds.midY),
                    endRadius: max(bounds.width, bounds.height) * 0.62,
                    options: [])
            }
            context.cgContext.restoreGState()

            let textRect = CGRect(x: inset,
                                  y: (height - measured.height) / 2,
                                  width: width - inset * 2,
                                  height: measured.height)
            (body as NSString).draw(with: textRect,
                                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                                    attributes: attributes, context: nil)
        }
        return CIImage(image: image)
    }
}
