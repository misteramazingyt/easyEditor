import Foundation
import WebKit
import UIKit

/// Loads a page in a real WebKit view, waits for it to finish rendering,
/// re-creates any `#:~:text=` highlight, and snapshots the result.
///
/// The highlight is drawn by us rather than left to the browser: WebKit only
/// honours a text directive on user-initiated cross-document navigations, so a
/// programmatic load often shows no highlight at all. We strip the directive,
/// find the passage ourselves, and mark it — which also makes the highlight
/// look identical every time.
@MainActor
final class URLCaptureController: NSObject, ObservableObject, WKNavigationDelegate {

    enum Phase: Equatable {
        case idle, loading, settling, ready, capturing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    /// nil = no text directive in the URL; true/false = whether we found it.
    @Published private(set) var highlightFound: Bool?
    @Published private(set) var pageTitle: String = ""

    let webView: WKWebView
    private var targets: [TextTarget] = []
    private var progressObservation: NSKeyValueObservation?

    struct TextTarget {
        var start: String
        var end: String?
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.highlightScript,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in self?.progress = view.estimatedProgress }
        }
    }

    // MARK: - Loading

    func load(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = trimmed.contains("://") ? trimmed : "https://" + trimmed
        let (clean, parsed) = Self.parseTextFragment(normalized)
        guard let url = clean else {
            phase = .failed("That doesn't look like a web address.")
            return
        }
        targets = parsed
        highlightFound = parsed.isEmpty ? nil : false
        phase = .loading
        progress = 0
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageTitle = webView.title ?? ""
        Task { await settle() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        phase = .failed(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        phase = .failed(error.localizedDescription)
    }

    /// "Fully loaded" means more than didFinish: images decoded, webfonts in,
    /// and lazy content triggered by a pass down the page.
    private func settle() async {
        phase = .settling
        _ = try? await webView.evaluateJavaScript("window.__eeSweep()")
        try? await Task.sleep(nanoseconds: 900_000_000)

        for _ in 0..<20 {
            let done = (try? await webView.evaluateJavaScript("window.__eeReady()")) as? Bool
            if done == true { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        if !targets.isEmpty {
            let payload = targets.map { ["start": $0.start, "end": $0.end ?? ""] }
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                let found = (try? await webView.evaluateJavaScript("window.__eeHighlight(\(json))")) as? Bool
                highlightFound = found ?? false
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        phase = .ready
    }

    /// Re-run the highlight after the user has scrolled or dismissed a banner.
    func refindHighlight() async {
        guard !targets.isEmpty else { return }
        let payload = targets.map { ["start": $0.start, "end": $0.end ?? ""] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let found = (try? await webView.evaluateJavaScript("window.__eeHighlight(\(json))")) as? Bool
        highlightFound = found ?? highlightFound
    }

    // MARK: - Capture

    /// Snapshot the viewport, or the whole page (height-capped) if asked.
    func capture(fullPage: Bool) async -> Data? {
        phase = .capturing
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true

        var restore: CGRect?
        if fullPage {
            let height = min(webView.scrollView.contentSize.height, 8000)
            if height > webView.frame.height {
                restore = webView.frame
                webView.frame = CGRect(x: 0, y: 0, width: webView.frame.width, height: height)
                webView.setNeedsLayout()
                webView.layoutIfNeeded()
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }

        let image: UIImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    Log.importer.error("Snapshot failed: \(error.localizedDescription)")
                }
                continuation.resume(returning: image)
            }
        }
        if let restore {
            webView.frame = restore
            webView.setNeedsLayout()
        }
        phase = .ready
        return image?.jpegData(compressionQuality: 0.92)
    }

    // MARK: - Text fragments

    /// Split a URL into the address to load and the passages to highlight.
    /// Format: `#[fragment]:~:text=[prefix-,]start[,end][,-suffix]&text=…`
    static func parseTextFragment(_ raw: String) -> (URL?, [TextTarget]) {
        guard let markerRange = raw.range(of: ":~:") else {
            return (URL(string: raw), [])
        }
        var base = String(raw[raw.startIndex..<markerRange.lowerBound])
        // Keep an ordinary #section anchor, drop a now-empty "#".
        if base.hasSuffix("#") { base.removeLast() }
        let directives = String(raw[markerRange.upperBound...])

        var targets: [TextTarget] = []
        for directive in directives.split(separator: "&") {
            guard directive.hasPrefix("text=") else { continue }
            let value = String(directive.dropFirst("text=".count))
            var parts = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            // prefix- and -suffix only disambiguate; they aren't highlighted.
            if let first = parts.first, first.hasSuffix("-") { parts.removeFirst() }
            if let last = parts.last, last.hasPrefix("-") { parts.removeLast() }
            guard let start = parts.first?.removingPercentEncoding, !start.isEmpty else { continue }
            let rawEnd = parts.count > 1 ? parts[1].removingPercentEncoding : nil
            let end = (rawEnd?.isEmpty == false) ? rawEnd : nil
            targets.append(TextTarget(start: start, end: end))
        }
        return (URL(string: base), targets)
    }

    // MARK: - Injected script

    private static let highlightScript = """
    (function () {
      const STYLE_ID = "__ee_hl_style";
      function ensureStyle() {
        if (document.getElementById(STYLE_ID)) return;
        const s = document.createElement("style");
        s.id = STYLE_ID;
        s.textContent = "mark.__ee_hl{background:#FFE783;color:inherit;" +
          "border-radius:2px;box-shadow:0 0 0 2px #FFE783;}";
        (document.head || document.documentElement).appendChild(s);
      }

      window.__eeReady = function () {
        if (document.readyState !== "complete") return false;
        const images = Array.from(document.images || []);
        const pending = images.filter(function (i) {
          return !i.complete && i.getBoundingClientRect().top < window.innerHeight * 3;
        });
        const fonts = !document.fonts || document.fonts.status === "loaded";
        return pending.length === 0 && fonts;
      };

      // Walk the page so lazy images load, then return to the top.
      window.__eeSweep = function () {
        const step = Math.max(300, window.innerHeight * 0.9);
        const limit = Math.min(document.body ? document.body.scrollHeight : 0, 20000);
        for (let y = 0; y < limit; y += step) window.scrollTo(0, y);
        window.scrollTo(0, 0);
        return true;
      };

      function rangeFor(text) {
        const sel = window.getSelection();
        sel.removeAllRanges();
        window.scrollTo(0, 0);
        if (!window.find(text, false, false, true, false, false, false)) return null;
        if (!sel.rangeCount) return null;
        const range = sel.getRangeAt(0).cloneRange();
        sel.removeAllRanges();
        return range;
      }

      function wrap(range) {
        const mark = document.createElement("mark");
        mark.className = "__ee_hl";
        try {
          range.surroundContents(mark);
        } catch (e) {
          // Partially-selected nodes can't be surrounded; move the contents.
          try {
            mark.appendChild(range.extractContents());
            range.insertNode(mark);
          } catch (e2) {
            return null;
          }
        }
        return mark;
      }

      window.__eeHighlight = function (targets) {
        ensureStyle();
        document.querySelectorAll("mark.__ee_hl").forEach(function (m) {
          const parent = m.parentNode;
          while (m.firstChild) parent.insertBefore(m.firstChild, m);
          parent.removeChild(m);
        });
        let first = null;
        (targets || []).forEach(function (t) {
          if (!t.start) return;
          const startRange = rangeFor(t.start);
          if (!startRange) return;
          let range = startRange;
          if (t.end) {
            const endRange = rangeFor(t.end);
            if (endRange) {
              const combined = document.createRange();
              combined.setStart(startRange.startContainer, startRange.startOffset);
              combined.setEnd(endRange.endContainer, endRange.endOffset);
              // Guard against a runaway range swallowing the whole article.
              if (combined.toString().length < 3000) range = combined;
            }
          }
          const mark = wrap(range);
          if (mark && !first) first = mark;
        });
        if (first) {
          first.scrollIntoView({ block: "center", inline: "nearest" });
          return true;
        }
        return false;
      };
    })();
    """
}
