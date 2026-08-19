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
      // Colour parsing kept regex-free: computed styles are always rgb()/rgba().
      function parseColor(value) {
        if (!value) return null;
        const open = value.indexOf("(");
        const close = value.lastIndexOf(")");
        if (open < 0 || close < open) return null;
        const parts = value.slice(open + 1, close).split(",").map(function (n) {
          return parseFloat(n);
        });
        if (parts.length < 3 || parts.some(isNaN)) return null;
        return { r: parts[0], g: parts[1], b: parts[2], a: parts.length > 3 ? parts[3] : 1 };
      }

      function luminance(c) {
        const channel = function (v) {
          v = v / 255;
          return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
        };
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
      }

      function contrast(a, b) {
        const la = luminance(a), lb = luminance(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
      }

      function rgb(c) {
        return "rgb(" + Math.round(c.r) + "," + Math.round(c.g) + "," + Math.round(c.b) + ")";
      }

      // The nearest ancestor that actually paints something.
      function backdropOf(node) {
        let el = node;
        while (el && el.nodeType === 1) {
          const c = parseColor(getComputedStyle(el).backgroundColor);
          if (c && c.a > 0.2) return c;
          el = el.parentElement;
        }
        return { r: 255, g: 255, b: 255, a: 1 };
      }

      // A dark page keeps its light type, so it gets a deep amber marker; a
      // light page gets the familiar yellow. Either way the ink is flipped if
      // the page's own text colour wouldn't read on it.
      function styleMark(mark) {
        const inherited = parseColor(getComputedStyle(mark).color) || { r: 0, g: 0, b: 0, a: 1 };
        const page = backdropOf(mark.parentElement);
        const dark = luminance(page) < 0.35;
        const bg = dark ? { r: 110, g: 82, b: 0 } : { r: 255, g: 231, b: 131 };
        let ink = inherited;
        if (contrast(inherited, bg) < 4.5) {
          const black = { r: 20, g: 20, b: 20 };
          const white = { r: 255, g: 255, b: 255 };
          ink = contrast(black, bg) >= contrast(white, bg) ? black : white;
        }
        const bgCSS = rgb(bg), inkCSS = rgb(ink);
        mark.style.setProperty("background-color", bgCSS, "important");
        mark.style.setProperty("color", inkCSS, "important");
        // Sites that clip a gradient to their text ignore `color` alone.
        mark.style.setProperty("-webkit-text-fill-color", inkCSS, "important");
        mark.style.setProperty("text-shadow", "none", "important");
        mark.style.setProperty("box-shadow", "0 0 0 2px " + bgCSS, "important");
        mark.style.setProperty("border-radius", "2px", "important");
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

      function findOnce(text) {
        const sel = window.getSelection();
        sel.removeAllRanges();
        window.scrollTo(0, 0);
        if (!window.find(text, false, false, true, false, false, false)) return null;
        if (!sel.rangeCount) return null;
        const range = sel.getRangeAt(0).cloneRange();
        sel.removeAllRanges();
        return range;
      }

      function rangeFor(text) {
        const cleaned = (text || "").replace(/\\s+/g, " ").trim();
        if (!cleaned) return null;
        const direct = findOnce(cleaned);
        if (direct) return direct;
        // Curly quotes, en dashes and non-breaking spaces are the usual
        // reason an exact match fails; retry on a plain-ASCII rewrite.
        const ascii = cleaned
          .replace(/[‘’‚‛]/g, "'")
          .replace(/[“”„]/g, '"')
          .replace(/[–—]/g, "-")
          .replace(/ /g, " ");
        if (ascii !== cleaned) {
          const asciiMatch = findOnce(ascii);
          if (asciiMatch) return asciiMatch;
        }
        // Then shrink from the front: the opening words are the least likely
        // to have been re-typeset.
        const words = cleaned.split(" ");
        const steps = [15, 12, 10, 8, 6, 5, 4];
        for (let i = 0; i < steps.length; i++) {
          const n = steps[i];
          if (words.length <= n) continue;
          const partial = findOnce(words.slice(0, n).join(" "));
          if (partial) return partial;
        }
        return null;
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
          if (mark) {
            styleMark(mark);
            if (!first) first = mark;
          }
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
