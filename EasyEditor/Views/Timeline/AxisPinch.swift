import SwiftUI
import UIKit

/// A pinch that knows which way it was made.
///
/// SwiftUI's magnification gesture reports a single scalar, which is all you
/// need to zoom something uniformly and no help at all when the two axes mean
/// different things — here, time across and layer height down. UIKit still
/// hands over the individual touches, so the angle between them is readable.
///
/// The recognizer is installed on the host view's parent rather than on the
/// representable itself: a UIView laid over the timeline would swallow the
/// scrub and drag gestures underneath it, and one laid behind would never see
/// a touch. On the parent it observes without intercepting.
struct AxisPinch: UIViewRepresentable {
    enum Axis { case horizontal, vertical }

    /// Called with the scale since the pinch began, and the axis it committed
    /// to on the first move.
    var onChange: (CGFloat, Axis) -> Void
    var onEnd: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onEnd: onEnd)
    }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.recognizer = context.coordinator.recognizer
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
    }

    final class HostView: UIView {
        var recognizer: UIPinchGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let recognizer, let target = superview else { return }
            if recognizer.view !== target {
                recognizer.view?.removeGestureRecognizer(recognizer)
                target.addGestureRecognizer(recognizer)
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChange: (CGFloat, Axis) -> Void
        var onEnd: () -> Void
        lazy var recognizer: UIPinchGestureRecognizer = {
            let gesture = UIPinchGestureRecognizer(self, action: #selector(handle(_:)))
            gesture.delegate = self
            gesture.cancelsTouchesInView = false
            return gesture
        }()
        private var axis: Axis?

        init(onChange: @escaping (CGFloat, Axis) -> Void, onEnd: @escaping () -> Void) {
            self.onChange = onChange
            self.onEnd = onEnd
        }

        @objc func handle(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                axis = nil
            case .changed:
                guard gesture.numberOfTouches == 2 else { return }
                if axis == nil {
                    // Commit to whichever way the fingers are further apart,
                    // once, so the gesture doesn't flip axis mid-pinch.
                    let a = gesture.location(ofTouch: 0, in: gesture.view)
                    let b = gesture.location(ofTouch: 1, in: gesture.view)
                    let dx = abs(a.x - b.x), dy = abs(a.y - b.y)
                    guard max(dx, dy) > 24 else { return }
                    axis = dx >= dy ? .horizontal : .vertical
                }
                if let axis { onChange(gesture.scale, axis) }
            case .ended, .cancelled, .failed:
                axis = nil
                onEnd()
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

private extension UIPinchGestureRecognizer {
    convenience init(_ target: Any, action: Selector) {
        self.init(target: target, action: action)
    }
}

/// The keyframe marker shape.
struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}
