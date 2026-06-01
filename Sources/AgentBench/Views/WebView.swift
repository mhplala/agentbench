import SwiftUI
import WebKit

// Renders an agent's produced HTML artifact.
//
// SECURITY: the HTML is UNTRUSTED (it was just written by an agent). By default
// we render it inert: JavaScript disabled, NO file:// base URL (so it can't read
// workspace files), and a content-rule list that blocks every network/subresource
// load — only the inline markup/CSS renders. Full fidelity (JS + relative assets +
// network) is opt-in via `trusted`, surfaced behind an explicit user action.
struct HTMLPreview: NSViewRepresentable {
    let html: String
    let baseDir: String?
    var fileURL: URL? = nil          // the actual HTML file on disk (enables sibling assets)
    var readAccessDir: String? = nil // dir WKWebView may read (the workspace)
    var trusted: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = trusted
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = context.coordinator
        context.coordinator.trusted = trusted
        apply(wv, context: context)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        // JS toggle requires reconfiguring; re-apply only when trust/html changed.
        if context.coordinator.lastTrusted != trusted || context.coordinator.lastHTML != html {
            wv.configuration.defaultWebpagePreferences.allowsContentJavaScript = trusted
            context.coordinator.trusted = trusted
            apply(wv, context: context)
        }
    }

    private func apply(_ wv: WKWebView, context: Context) {
        context.coordinator.lastTrusted = trusted
        context.coordinator.lastHTML = html
        context.coordinator.loadedOnce = false

        let doLoad = {
            if self.trusted, let fileURL = self.fileURL,
               FileManager.default.fileExists(atPath: fileURL.path) {
                // Prefer the loopback HTTP server: ES modules / importmap / fetch /
                // workers only work over http(s), never file://.
                if let httpURL = PreviewServer.shared.url(forFile: fileURL) {
                    wv.load(URLRequest(url: httpURL))
                } else {
                    // fallback: load the file directly (static HTML/CSS still render)
                    let access = URL(fileURLWithPath: self.readAccessDir
                        ?? fileURL.deletingLastPathComponent().path, isDirectory: true)
                    wv.loadFileURL(fileURL, allowingReadAccessTo: access)
                }
            } else if self.trusted, let baseDir = self.baseDir, !baseDir.isEmpty {
                _ = wv.loadHTMLString(self.html, baseURL: URL(fileURLWithPath: baseDir, isDirectory: true))
            } else {
                _ = wv.loadHTMLString(self.html, baseURL: nil)   // untrusted: no file access
            }
        }

        if trusted {
            wv.configuration.userContentController.removeAllContentRuleLists()
            doLoad()
        } else {
            // Block ALL resource loads (network + file) so an untrusted artifact
            // can't phone home or pull local assets. Inline HTML/CSS still renders.
            Coordinator.blockAllRuleList { list in
                wv.configuration.userContentController.removeAllContentRuleLists()
                if let list { wv.configuration.userContentController.add(list) }
                doLoad()
            }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var trusted = false
        var lastTrusted: Bool? = nil
        var lastHTML: String? = nil
        var loadedOnce = false

        // Allow only the initial in-memory document load; block link clicks,
        // redirects, form submits and any other top-level navigation.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if !loadedOnce {
                loadedOnce = true
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        private static var cachedList: WKContentRuleList?
        static func blockAllRuleList(_ completion: @escaping (WKContentRuleList?) -> Void) {
            if let cachedList { completion(cachedList); return }
            let json = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "agentbench-block-all", encodedContentRuleList: json
            ) { list, _ in
                cachedList = list
                completion(list)
            }
        }
    }
}
