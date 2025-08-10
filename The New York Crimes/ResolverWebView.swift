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

    init(preferReaderMode: Bool, onResolved: @escaping (URL) -> Void) {
        self.preferReaderMode = preferReaderMode
        self.onResolved = onResolved
    }

    func start(on webView: WKWebView, with originalURL: URL) {
        let host = (originalURL.host ?? "").lowercased()
        let isNYT = (host == "www.nytimes.com" || host == "nytimes.com" || host.hasSuffix(".nytimes.com") || host == "nyti.ms")
        if preferReaderMode, isNYT {
            if let readerURL = URL(string: "https://r.jina.ai/" + originalURL.absoluteString) {
                attemptedReader = true
                webView.load(URLRequest(url: readerURL))
                return
            }
        }
        // Default start via removepaywalls for direct archival
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
              if (/403\s*forbidden/i.test(t) || /Warning:\s*Target URL returned error\s*403/i.test(t) || /CAPTCHA/i.test(t)) return true;
              return false;
            })()
            """#
            webView.evaluateJavaScript(detectBlockJS) { [weak self] result, _ in
                guard let self else { return }
                if let isBlocked = result as? Bool, isBlocked {
                    let rp = URL(string: "https://removepaywalls.com/" + (webView.url?.absoluteString.replacingOccurrences(of: "https://r.jina.ai/", with: "") ?? ""))
                    if let rp { webView.load(URLRequest(url: rp)) }
                } else {
                    self.didResolve = true
                    self.onResolved(currentURL)
                }
            }
            return
        }

        if host == "removepaywalls.com" {
            // Auto click Option 1
            let js = #"""
            (function(){
              try{
                var a1 = document.querySelector('a[href*="archive.is/"]') || document.querySelector('a[href*="archive.today/"]');
                if(a1 && a1.href){ location.href = a1.href; return true; }
                var links = Array.from(document.querySelectorAll('a[href]'));
                var preferred = links.find(function(a){ return /option\s*1/i.test((a.textContent||'').trim()); }) || links[0];
                if(preferred && preferred.href){ location.href = preferred.href; return true; }
              }catch(e){}
              return false;
            })()
            """#
            webView.evaluateJavaScript(js, completionHandler: nil)
            return
        }

        if host.contains("archive.is") || host.contains("archive.today") {
            didResolve = true
            onResolved(currentURL)
            return
        }
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


