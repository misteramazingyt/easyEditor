import SwiftUI

/// Adjust what part of a screenshot actually goes in.
///
/// A quote scan arrives framed by whatever produced it, which is rarely the
/// framing you want on a timeline — there is usually a margin, a running head,
/// or a second paragraph you were not quoting. Drag the window over the part
/// that matters and insert that.
struct ImageCropSheet: View {
    let image: UIImage
    /// Cropped JPEG, ready to insert.
    let onUse: (Data) -> Void

    @Environment(\.dismiss) private var dismiss

    /// The crop, in unit coordinates of the image.
    @State private var crop = CGRect(x: 0.06, y: 0.06, width: 0.88, height: 0.88)
    @State private var dragStart: CGRect?

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var unit: CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: 0, y: 0)
            case .topRight: return CGPoint(x: 1, y: 0)
            case .bottomLeft: return CGPoint(x: 0, y: 1)
            case .bottomRight: return CGPoint(x: 1, y: 1)
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let frame = fitted(in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            .overlay {
                                // Everything outside the window goes dim, so
                                // what you are keeping is what you can read.
                                Rectangle()
                                    .fill(.black.opacity(0.6))
                                    .frame(width: frame.width, height: frame.height)
                                    .position(x: frame.midX, y: frame.midY)
                                    .reverseMask {
                                        Rectangle()
                                            .frame(width: crop.width * frame.width,
                                                   height: crop.height * frame.height)
                                            .position(x: frame.minX + crop.midX * frame.width,
                                                      y: frame.minY + crop.midY * frame.height)
                                    }
                                    .allowsHitTesting(false)
                            }
                        window(in: frame)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .background(Color.black)

                controls
            }
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Insert") { insert() }.fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - The window

    private func window(in frame: CGRect) -> some View {
        let rect = CGRect(x: frame.minX + crop.minX * frame.width,
                          y: frame.minY + crop.minY * frame.height,
                          width: crop.width * frame.width,
                          height: crop.height * frame.height)
        return ZStack {
            Rectangle()
                .strokeBorder(.white, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
                .position(x: rect.midX, y: rect.midY)
                .gesture(moveGesture(frame: frame))

            // Thirds, to line a passage up by.
            Path { path in
                for i in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: rect.minY))
                    path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    let y = rect.minY + rect.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(.white.opacity(0.25), lineWidth: 0.5)
            .allowsHitTesting(false)

            ForEach(Corner.allCases, id: \.self) { corner in
                Rectangle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle().inset(by: -14))
                    .position(x: rect.minX + corner.unit.x * rect.width,
                              y: rect.minY + corner.unit.y * rect.height)
                    .gesture(cornerGesture(corner, frame: frame))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("Reset") { crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
                .buttonStyle(.bordered)
            Spacer()
            Text("\(Int(crop.width * image.size.width))×\(Int(crop.height * image.size.height))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(red: 0.07, green: 0.08, blue: 0.11))
    }

    // MARK: - Geometry

    /// The image, aspect-fit into the space available.
    private func fitted(in size: CGSize) -> CGRect {
        let scale = min(size.width / max(1, image.size.width),
                        size.height / max(1, image.size.height))
        let width = image.size.width * scale
        let height = image.size.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }

    private func moveGesture(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStart ?? crop
                if dragStart == nil { dragStart = crop }
                var moved = start
                moved.origin.x = min(max(0, start.minX + value.translation.width / frame.width),
                                     1 - start.width)
                moved.origin.y = min(max(0, start.minY + value.translation.height / frame.height),
                                     1 - start.height)
                crop = moved
            }
            .onEnded { _ in dragStart = nil }
    }

    private func cornerGesture(_ corner: Corner, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStart ?? crop
                if dragStart == nil { dragStart = crop }
                let dx = value.translation.width / frame.width
                let dy = value.translation.height / frame.height
                var left = start.minX, right = start.maxX
                var top = start.minY, bottom = start.maxY
                if corner.unit.x == 0 { left = start.minX + dx } else { right = start.maxX + dx }
                if corner.unit.y == 0 { top = start.minY + dy } else { bottom = start.maxY + dy }
                let minimum = 0.06
                left = min(max(0, left), right - minimum)
                right = max(min(1, right), left + minimum)
                top = min(max(0, top), bottom - minimum)
                bottom = max(min(1, bottom), top + minimum)
                crop = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: - Cutting it

    private func insert() {
        guard let cgImage = image.cgImage else {
            dismiss()
            return
        }
        // Unit crop into pixels, in the image's own orientation.
        let pixels = CGRect(x: crop.minX * CGFloat(cgImage.width),
                            y: crop.minY * CGFloat(cgImage.height),
                            width: crop.width * CGFloat(cgImage.width),
                            height: crop.height * CGFloat(cgImage.height)).integral
        guard let cut = cgImage.cropping(to: pixels),
              let data = UIImage(cgImage: cut, scale: image.scale,
                                 orientation: image.imageOrientation)
                  .jpegData(compressionQuality: 0.95) else {
            dismiss()
            return
        }
        onUse(data)
        dismiss()
    }
}

private extension View {
    /// Punch a hole in something, for the dimmed surround.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .topLeading) {
                    mask().blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}
