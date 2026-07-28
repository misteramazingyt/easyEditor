import Foundation
import UIKit
import CoreImage

/// Renders title text and still images into CIImages the compositor can
/// composite per frame. The same rendering path serves preview and export, so
/// what you see is exactly what ships.
enum OverlayRenderer {

    /// Render a text payload at canvas scale. The image is sized to the text.
    static func render(text: TextPayload, canvasWidth: CGFloat) -> CIImage? {
        let style = text.style
        let font = UIFont(name: style.fontName, size: style.fontSize)
            ?? UIFont.boldSystemFont(ofSize: style.fontSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: uiColor(hex: style.colorHex) ?? .white,
            .paragraphStyle: paragraph,
        ]
        if style.hasShadow {
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = style.fontSize * 0.08
            shadow.shadowOffset = CGSize(width: 0, height: style.fontSize * 0.04)
            attributes[.shadow] = shadow
        }

        let string = NSAttributedString(string: text.string, attributes: attributes)
        let maxWidth = canvasWidth * 0.92
        var bounds = string.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading],
                                         context: nil).size
        bounds.width = min(maxWidth, ceil(bounds.width) + style.fontSize * 0.5)
        bounds.height = ceil(bounds.height) + style.fontSize * 0.4

        let padding: CGFloat = style.backgroundHex != nil ? style.fontSize * 0.3 : 0
        let canvas = CGSize(width: bounds.width + padding * 2, height: bounds.height + padding * 2)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        let image = renderer.image { ctx in
            if let bgHex = style.backgroundHex, let bg = uiColor(hex: bgHex) {
                bg.setFill()
                let rect = CGRect(origin: .zero, size: canvas)
                UIBezierPath(roundedRect: rect, cornerRadius: style.fontSize * 0.25).fill()
            }
            _ = ctx // silence unused when no background
            string.draw(with: CGRect(x: padding, y: padding + style.fontSize * 0.2,
                                     width: bounds.width, height: bounds.height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        context: nil)
        }
        guard let cg = image.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }

    /// Load a still image clip from disk at a sane size for compositing.
    static func render(imageURL: URL) -> CIImage? {
        guard let ui = UIImage(contentsOfFile: imageURL.path)?.scaledDown(maxDimension: 2160),
              let cg = ui.cgImage else { return nil }
        return CIImage(cgImage: cg)
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
