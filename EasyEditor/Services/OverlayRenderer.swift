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

    private static func uiColor(hex: String) -> UIColor? {
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
