//
//  ResolverWebView.swift
//  The New York Crimes
//
//  Created by Assistant on 8/9/25.
//

import SwiftUI
import WebKit

struct ResolverWebView: View {
    let originalURL: URL
    let preferReaderMode: Bool
    let onResolved: (URL) -> Void

    var body: some View {
        #if os(iOS)
        ResolverRepresentable_iOS(originalURL: originalURL, preferReaderMode: preferReaderMode, onResolved: onResolved)
            .frame(width: 1, height: 1)
            .opacity(0.01)
        #elseif os(macOS)
        ResolverRepresentable_macOS(originalURL: originalURL, preferReaderMode: preferReaderMode, onResolved: onResolved)
            .frame(width: 1, height: 1)
            .opacity(0.01)
        #endif
    }
}

// MARK: - Shared Coordinator Logic
final class ResolverCoordinator: NSObject, WKNavigationDelegate {
    let preferReaderMode: Bool
    let onResolved: (URL) -> Void
    private var attemptedReader = false
    private var didResolve = false
    private var originalURL: URL?
    private var timeoutWorkItem: DispatchWorkItem?
    private var triedArchiveDirect = false

    init(preferReaderMode: Bool, onResolved: @escaping (URL) -> Void) {
        self.preferReaderMode = preferReaderMode
        self.onResolved = onResolved
    }

    func start(on webView: WKWebView, with originalURL: URL) {
        self.originalURL = originalURL
        // Start a safety timeout to avoid hanging on iPad
        startTimeout(on: webView)
        // Always begin at removepaywalls; we'll resolve to an archive snapshot first
        let abs = originalURL.absoluteString
        if let rp = URL(string: "https://removepaywalls.com/" + abs) {
            webView.load(URLRequest(url: rp))
        } else {
            webView.load(URLRequest(url: originalURL))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !didResolve, let currentURL = webView.url else { return }
        let host = (currentURL.host ?? "").lowercased()

        if host == "r.jina.ai" {
            // Detect 403/CAPTCHA; if blocked, fall back to removepaywalls
            let detectBlockJS = #"""
            (function(){
              var t = (document.body && document.body.innerText) || '';
              if (/403\\s*forbidden/i.test(t) || /Warning:\\s*Target URL returned error\\s*403/i.test(t) || /CAPTCHA/i.test(t)) return true;
              return false;
            })()
            """#
            webView.evaluateJavaScript(detectBlockJS) { [weak self] result, _ in
                guard let self else { return }
                if let isBlocked = result as? Bool, isBlocked {
                    // Prefer direct archive candidates instead of removepaywalls to reduce flakiness on iPad
                    self.loadArchiveCandidates(on: webView)
                } else {
                    self.didResolve = true
                    self.cancelTimeout()
                    self.onResolved(currentURL)
                }
            }
            return
        }

        if host == "removepaywalls.com" {
            // Prefer an archive.* link; otherwise force a direct archive.today run with the original URL
            let js = #"""
            (function(){
              try {
                var links = Array.from(document.querySelectorAll('a[href]'));
                var archiveLink = links.find(function(a){ return /https?:\/\/archive\.(is|today|ph|md|vn|fo)\//i.test(a.href); });
                if (archiveLink && archiveLink.href) { location.href = archiveLink.href; return 'clicked-archive'; }
              } catch(e) {}
              try {
                var current = location.href;
                var orig = current.replace(/^https?:\/\/removepaywalls\.com\//i,'');
                var target = 'https://archive.today/?run=1&url=' + encodeURIComponent(orig);
                location.href = target;
                return 'fallback-archive.today-run';
              } catch(e) {}
              return 'no-op';
            })()
            """#
            webView.evaluateJavaScript(js, completionHandler: nil)
            return
        }

        if host.contains("archive.is") || host.contains("archive.today") || host.contains("archive.ph") || host.contains("archive.md") || host.contains("archive.vn") || host.contains("archive.fo") {
            // If we landed on the archive root or submit without a target, drive a run with the original URL
            let path = currentURL.path
            let query = currentURL.query ?? ""
            if (path == "/" && query.isEmpty) || path.lowercased().contains("/submit") && (URLComponents(url: currentURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value?.isEmpty ?? true) {
                loadArchiveCandidates(on: webView)
                return
            }
            // Detect CAPTCHA/blocked content on archive hosts and, on iOS, hand off original URL to Apple's Reader
            let detectBlockJS = #"""
            (function(){
              var t = (document.body && document.body.innerText) || '';
              if (/403\\s*forbidden/i.test(t) || /captcha/i.test(t) || /verify\\s*you\\s*are\\s*human/i.test(t) || /security\\s*check/i.test(t)) return true;
              return false;
            })()
            """#
            webView.evaluateJavaScript(detectBlockJS) { [weak self] result, _ in
                guard let self else { return }
                #if os(iOS)
                if let blocked = result as? Bool, blocked == true, let original = self.originalURL {
                    self.didResolve = true
                    self.cancelTimeout()
                    self.onResolved(original)
                    return
                }
                #endif
                self.didResolve = true
                self.cancelTimeout()
                self.onResolved(currentURL)
            }
            return
        }
    }

    private func loadArchiveCandidates(on webView: WKWebView) {
        guard let original = originalURL else { return }
        if triedArchiveDirect { return }
        triedArchiveDirect = true
        // Try endpoints that usually 302 to a concrete snapshot
        let candidates = [
            "https://archive.is/latest/" + original.absoluteString,
            "https://archive.md/oldest/" + original.absoluteString,
            "https://archive.today/?run=1&url=" + (original.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? original.absoluteString)
        ]
        if let first = URL(string: candidates[0]) {
            webView.load(URLRequest(url: first))
        } else if let second = URL(string: candidates[1]) {
            webView.load(URLRequest(url: second))
        } else if let third = URL(string: candidates[2]) {
            webView.load(URLRequest(url: third))
        }
    }

    private func startTimeout(on webView: WKWebView) {
        cancelTimeout()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.didResolve { return }
            // Fallback preference: r.jina.ai -> archive.today run -> original URL
            if let original = self.originalURL {
                #if os(iOS)
                // iOS/iPadOS: avoid r.jina.ai; prefer archive.today run or original
                if let run = URL(string: "https://archive.today/?run=1&url=" + original.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!) {
                    self.didResolve = true
                    self.onResolved(run)
                    return
                }
                self.didResolve = true
                self.onResolved(original)
                #else
                // macOS: allow r.jina.ai as a reader-like fallback
                if let reader = URL(string: "https://r.jina.ai/" + original.absoluteString) {
                    self.didResolve = true
                    self.onResolved(reader)
                    return
                }
                if let run = URL(string: "https://archive.today/?run=1&url=" + original.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!) {
                    self.didResolve = true
                    self.onResolved(run)
                    return
                }
                self.didResolve = true
                self.onResolved(original)
                #endif
            }
        }
        timeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: work)
    }

    private func cancelTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }
}

#if os(iOS)
// MARK: - iOS Resolver
struct ResolverRepresentable_iOS: UIViewRepresentable {
    let originalURL: URL
    let preferReaderMode: Bool
    let onResolved: (URL) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.start(on: webView, with: originalURL)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) { }

    func makeCoordinator() -> ResolverCoordinator { ResolverCoordinator(preferReaderMode: preferReaderMode, onResolved: onResolved) }
}
#elseif os(macOS)
// MARK: - macOS Resolver
struct ResolverRepresentable_macOS: NSViewRepresentable {
    let originalURL: URL
    let preferReaderMode: Bool
    let onResolved: (URL) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.start(on: webView, with: originalURL)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) { }

    func makeCoordinator() -> ResolverCoordinator { ResolverCoordinator(preferReaderMode: preferReaderMode, onResolved: onResolved) }
}
#endif


