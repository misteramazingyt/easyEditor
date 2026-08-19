import SwiftUI
import WebKit

/// Paste a URL, watch it load, and drop a screenshot on the timeline. If the
/// address carries a `#:~:text=` fragment the passage is highlighted and
/// centred before the shot is taken.
struct URLCaptureSheet: View {
    /// Saves the screenshot and places it at the playhead; true on success.
    let onCapture: (Data, OverlayPlacement) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = URLCaptureController()

    @State private var urlText = ""
    @State private var fullPage = false
    @State private var isInserting = false
    @FocusState private var urlFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.05, green: 0.06, blue: 0.09).ignoresSafeArea()
                VStack(spacing: 0) {
                    addressBar
                    statusBar
                    WebViewContainer(webView: controller.webView)
                        .background(.white)
                    captureBar
                }
            }
            .navigationTitle("URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await autoPaste()
        }
    }

    // MARK: Address

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").foregroundStyle(.secondary)
            TextField("Paste a link", text: $urlText)
                .focused($urlFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { go() }
            if !urlText.isEmpty {
                Button {
                    urlText = ""
                    urlFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            PasteButton(payloadType: String.self) { items in
                if let first = items.first {
                    Task { @MainActor in paste(first) }
                }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.capsule)
            .tint(.blue)
            Button("Go") { go() }
                .font(.callout.weight(.semibold))
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func go() {
        urlFocused = false
        controller.load(urlText)
    }

    /// Load whatever link is already on the clipboard, with no prompt and no
    /// tap. Pattern detection hands back only what the system already
    /// recognises as a URL, so it doesn't trip the paste alert the way
    /// reading the pasteboard's text would.
    private func autoPaste() async {
        guard urlText.isEmpty else { return }
        let detected = try? await UIPasteboard.general.detectedValues(for: [\.probableWebURL])
        // String(describing:) so this holds whether the system hands back a
        // String or a URL.
        guard let probable = detected?.probableWebURL else {
            urlFocused = true
            return
        }
        let candidate = String(describing: probable).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            urlFocused = true
            return
        }
        urlText = candidate
        go()
    }

    private func paste(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        urlText = trimmed
        go()
    }

    // MARK: Status

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 8) {
            switch controller.phase {
            case .idle:
                Text("Paste a link, including a #:~:text= highlight if you have one.")
                    .font(.caption2).foregroundStyle(.secondary)
            case .loading:
                ProgressView().controlSize(.mini)
                Text("Loading \(Int(controller.progress * 100))%")
                    .font(.caption2).foregroundStyle(.secondary)
            case .settling:
                ProgressView().controlSize(.mini)
                Text("Waiting for the page to finish rendering…")
                    .font(.caption2).foregroundStyle(.secondary)
            case .ready:
                if let found = controller.highlightFound {
                    Image(systemName: found ? "highlighter" : "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(found ? .yellow : .orange)
                    Text(found ? "Highlight found and centred"
                               : "Couldn't find that passage — scroll to what you want")
                        .font(.caption2)
                        .foregroundStyle(found ? Color.secondary : Color.orange)
                } else {
                    Image(systemName: "checkmark.circle").font(.caption2).foregroundStyle(.green)
                    Text(controller.pageTitle.isEmpty ? "Ready" : controller.pageTitle)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            case .capturing:
                ProgressView().controlSize(.mini)
                Text("Capturing…").font(.caption2).foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "xmark.octagon").font(.caption2).foregroundStyle(.red)
                Text(message).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
            if controller.highlightFound != nil, controller.phase == .ready {
                Button {
                    Task { await controller.refindHighlight() }
                } label: {
                    Label("Re-centre", systemImage: "scope").font(.caption2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    // MARK: Capture

    private var captureBar: some View {
        VStack(spacing: 8) {
            Toggle(isOn: $fullPage) {
                Text("Capture the whole page")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 4)

            Button {
                capture()
            } label: {
                HStack(spacing: 8) {
                    if isInserting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "camera.viewfinder")
                    }
                    Text(isInserting ? "Inserting…" : "CAPTURE & INSERT")
                        .font(.subheadline.weight(.bold)).kerning(1)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(readyToCapture ? Color.blue.opacity(0.85) : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!readyToCapture || isInserting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.07, green: 0.08, blue: 0.11))
    }

    private var readyToCapture: Bool {
        controller.phase == .ready
    }

    private func capture() {
        guard !isInserting else { return }
        isInserting = true
        Task {
            defer { isInserting = false }
            guard let data = await controller.capture(fullPage: fullPage) else { return }
            // Full-page grabs are tall; let them run past the canvas edges
            // rather than shrinking the text to nothing.
            let placement = OverlayPlacement(centerX: 0.5, centerY: 0.5,
                                             widthFraction: fullPage ? 1.0 : 0.98)
            if await onCapture(data, placement) {
                Haptics.success()
                dismiss()
            }
        }
    }
}

/// Hosts the controller's live WKWebView so the user can watch it load and
/// scroll to exactly what they want before shooting.
private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
