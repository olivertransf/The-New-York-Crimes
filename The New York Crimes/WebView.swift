//
//  WebView.swift
//  The New York Crimes
//
//  Created by Assistant on 8/9/25.
//

import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#endif

struct WebView: View {
    let url: URL
    var onArticleLink: ((URL) -> Void)? = nil
    var pageZoom: CGFloat = 1.0
    var preferMobileUserAgent: Bool = false
    var preferReaderMode: Bool = false
    #if os(iOS)
    var onRequestOpenInSafariReader: ((URL) -> Void)? = nil
    #endif

    var body: some View {
        WebViewRepresentable(
            url: url,
            onArticleLink: onArticleLink,
            pageZoom: pageZoom,
            preferMobileUserAgent: preferMobileUserAgent,
            preferReaderMode: preferReaderMode,
            onRequestOpenInSafariReader: onRequestOpenInSafariReader
        )
        .ignoresSafeArea()
    }
}

// MARK: - Coordinator shared between platforms
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let onArticleLink: ((URL) -> Void)?
    private let preferReaderMode: Bool
    private var attemptedReaderForURL: URL?
    #if os(iOS)
    private let onRequestOpenInSafariReader: ((URL) -> Void)?
    init(onArticleLink: ((URL) -> Void)?, preferReaderMode: Bool, onRequestOpenInSafariReader: ((URL) -> Void)?) {
        self.onArticleLink = onArticleLink
        self.preferReaderMode = preferReaderMode
        self.onRequestOpenInSafariReader = onRequestOpenInSafariReader
    }
    #else
    init(onArticleLink: ((URL) -> Void)?, preferReaderMode: Bool) {
        self.onArticleLink = onArticleLink
        self.preferReaderMode = preferReaderMode
    }
    #endif

    // Detect New York Times article links
    private func isNYTArticleURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return false }

        let host = (url.host ?? "").lowercased()
        let path = url.path

        if path == "/" { return false }

        // Accept shortlinks
        if host == "nyti.ms" { return true }

        // Only handle nytimes.com domains
        guard host == "www.nytimes.com" || host.hasSuffix(".nytimes.com") || host == "nytimes.com" else { return false }

        // Exclude non-article areas
        let excludedPrefixes = [
            "/section/", "/topic/", "/crosswords/", "/games/",
            "/account/", "/subscriptions/", "/auth/", "/wirecutter/",
            "/cooking/", "/athletic/"
        ]
        for prefix in excludedPrefixes { if path.hasPrefix(prefix) { return false } }

        // Common article patterns
        // 1) /YYYY/MM/DD/... possibly ending with .html
        if path.range(of: "^/\\d{4}/\\d{2}/\\d{2}/", options: .regularExpression) != nil { return true }
        // 2) interactive stories
        if path.contains("/interactive/") { return true }
        // 3) live coverage pages
        if path.contains("/live/") { return true }
        // 4) opinion, business, etc. with date-less but article-like slugs sometimes exist; require .html
        if path.hasSuffix(".html") { return true }

        return false
    }

    private func proxiedNYTURL(for url: URL) -> URL {
        URL(string: "https://removepaywalls.com/" + url.absoluteString) ?? url
    }

    private func isLikelyAMP(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        return lower.contains("/amp") || lower.contains("outputtype=amp")
    }

    // Receive link taps from injected JS (for SPA navigations)
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "linkTap", let href = message.body as? String, let url = URL(string: href) else { return }
        if isNYTArticleURL(url) {
            DispatchQueue.main.async { [weak self, onArticleLink] in
                guard let self else { return }
                onArticleLink?(self.proxiedNYTURL(for: url))
            }
        }
    }

    // Ensure target=_blank opens in the same web view
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Reset reader attempt when a new main-frame URL is loading
        if let url = navigationAction.request.url, navigationAction.targetFrame?.isMainFrame == true {
            if attemptedReaderForURL != url { attemptedReaderForURL = nil }
        }
        if navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == false,
           let url = navigationAction.request.url {
            if isNYTArticleURL(url) {
                DispatchQueue.main.async { [weak self, onArticleLink] in
                    guard let self else { return }
                    // Hand off the ORIGINAL article URL; resolver handles reader/removepaywalls/archives
                    onArticleLink?(url)
                }
                decisionHandler(.cancel)
                return
            }
            // For other popups, open in same view
            webView.load(URLRequest(url: url))
            decisionHandler(.cancel)
            return
        }

        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() {
            if scheme != "http" && scheme != "https" {
                #if os(iOS)
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                #elseif os(macOS)
                NSWorkspace.shared.open(url)
                #endif
                decisionHandler(.cancel)
                return
            }
            // Block tel:, sms:, mailto: etc from opening grey sheet as popups
            if navigationAction.navigationType == .other,
               navigationAction.targetFrame?.isMainFrame == false {
                decisionHandler(.cancel)
                return
            }
        }

        // Main-frame: intercept NYT article clicks and surface via callback
        if let url = navigationAction.request.url,
           navigationAction.targetFrame?.isMainFrame == true {
            var candidate = url
            // Allow shortlink domain
            if let host = url.host?.lowercased(), host == "nyti.ms", let final = URL(string: url.absoluteString) {
                candidate = final
            }
            if isNYTArticleURL(candidate) {
                DispatchQueue.main.async { [weak self, onArticleLink] in
                    guard let self else { return }
                    // Hand off the ORIGINAL article URL; resolver handles reader/removepaywalls/archives
                    onArticleLink?(candidate)
                }
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let currentURL = webView.url else { return }
        // Handle removepaywalls intermediary: auto-click Option 1, then we'll wrap the archive snapshot if reader mode is on
        if let host = currentURL.host?.lowercased(), host == "removepaywalls.com" {
            if attemptedReaderForURL == currentURL { return }
            attemptedReaderForURL = currentURL
            let js = """
            (function(){
              try{
                var links = Array.from(document.querySelectorAll('a[href]'));
                var preferred = links.find(function(a){ return /option\\s*1/i.test((a.textContent||'').trim()); })
                              || links.find(function(a){ return a.href && a.href.includes('r.jina.ai'); })
                              || links[0];
                if(preferred){ location.href = preferred.href; return true; }
              }catch(e){}
              return false;
            })()
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
            return
        }

        // If reader mode is enabled and we landed on archive.* snapshot, re-open via r.jina.ai for cleaner view
        guard preferReaderMode else { return }
        if let host = currentURL.host?.lowercased(),
           (host.contains("archive.is") || host.contains("archive.today")) {
            let alreadyReader = currentURL.absoluteString.hasPrefix("https://r.jina.ai/") || currentURL.absoluteString.hasPrefix("http://r.jina.ai/")
            if !alreadyReader {
                if attemptedReaderForURL == currentURL { return }
                attemptedReaderForURL = currentURL
                #if os(iOS)
                onRequestOpenInSafariReader?(currentURL)
                return
                #else
                if let wrapped = URL(string: "https://r.jina.ai/" + currentURL.absoluteString) {
                    webView.load(URLRequest(url: wrapped))
                    return
                }
                #endif
            }
        }

        // If r.jina.ai shows a 403/CAPTCHA block, fall back to the underlying URL (e.g., archive snapshot) instead of reader
        if let host = currentURL.host?.lowercased(), host == "r.jina.ai" {
            if attemptedReaderForURL == currentURL { return }
            attemptedReaderForURL = currentURL
            let detectBlockJS = #"""
            (function(){
              var t = (document.body && document.body.innerText) || '';
              if (/403\s*forbidden/i.test(t) || /Warning:\s*Target URL returned error\s*403/i.test(t) || /CAPTCHA/i.test(t)) return true;
              return false;
            })()
            """#
            webView.evaluateJavaScript(detectBlockJS) { result, _ in
                guard let isBlocked = result as? Bool, isBlocked == true else { return }
                let abs = currentURL.absoluteString
                let prefix = "https://r.jina.ai/"
                if abs.hasPrefix(prefix) {
                    let tail = String(abs.dropFirst(prefix.count))
                    if let fallbackURL = URL(string: tail) {
                        webView.load(URLRequest(url: fallbackURL))
                    }
                }
            }
            return
        }
    }

    // Ensure content JavaScript stays enabled on a per-navigation basis (macOS 11+/iOS 14+)
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.allowsContentJavaScript = true
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // Ignore navigation cancelled (-999) noise
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        #if DEBUG
        print("WKWebView didFail navigation: \(nsError.domain)(\(nsError.code)) \(nsError.localizedDescription)")
        #endif
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // Ignore navigation cancelled (-999) noise
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        #if DEBUG
        print("WKWebView didFail provisional: \(nsError.domain)(\(nsError.code)) \(nsError.localizedDescription)")
        #endif
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // Handle window.open
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url, navigationAction.targetFrame == nil else { return nil }
        webView.load(URLRequest(url: url))
        return nil
    }
}

#if os(iOS)
// MARK: - iOS
struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    let onArticleLink: ((URL) -> Void)?
    let pageZoom: CGFloat
    let preferMobileUserAgent: Bool
    let preferReaderMode: Bool
    let onRequestOpenInSafariReader: ((URL) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Persist cookies, sessions, and other site data across launches
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.allowsInlineMediaPlayback = true
        // Inspector is set on the webView instance below

        // Inject JS to capture link clicks for SPA/JS-driven navigations
        let userContent = configuration.userContentController
        userContent.add(UserContentProxy(coordinator: context.coordinator), name: "linkTap")
        let js = """
        (function(){
          function handler(e){
            var a=e.target.closest('a[href]');
            if(!a) return;
            var href=a.href;
            try { window.webkit.messageHandlers.linkTap.postMessage(href); } catch(e) {}
          }
          document.addEventListener('click', handler, true);
        })();
        """
        let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        userContent.addUserScript(script)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // Use a modern Safari user agent to avoid UA-based blocks (mobile UA on iOS)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/605.1.15"
        // Increase readability if requested
        webView.pageZoom = pageZoom
        #if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif
        // If reader mode preferred, wrap only NYT hosts via Jina reader; skip intermediaries like removepaywalls/archive
        var targetURL = url
        if preferReaderMode, let host = url.host?.lowercased() {
            let isNYTHost = (host == "www.nytimes.com" || host == "nytimes.com" || host.hasSuffix(".nytimes.com") || host == "nyti.ms")
            let isAlreadyReader = url.absoluteString.hasPrefix("https://r.jina.ai/") || url.absoluteString.hasPrefix("http://r.jina.ai/")
            let isIntermediary = (host == "removepaywalls.com" || host.contains("archive.is") || host.contains("archive.today"))
            if isNYTHost && !isAlreadyReader && !isIntermediary {
                if let wrapped = URL(string: "https://r.jina.ai/" + url.absoluteString) {
                    targetURL = wrapped
                }
            }
        }
        webView.load(URLRequest(url: targetURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // No-op. If you want to navigate to a new URL, pass a new `url`.
    }

    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator(onArticleLink: onArticleLink, preferReaderMode: preferReaderMode, onRequestOpenInSafariReader: onRequestOpenInSafariReader) }
}
#elseif os(macOS)
// MARK: - macOS
struct WebViewRepresentable: NSViewRepresentable {
    let url: URL
    let onArticleLink: ((URL) -> Void)?
    let pageZoom: CGFloat
    let preferMobileUserAgent: Bool
    let preferReaderMode: Bool
    let onRequestOpenInSafariReader: ((URL) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default() // persist cookies & storage
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Inspector is set on the webView instance below

        // Inject JS to capture link clicks for SPA/JS-driven navigations
        let userContent = configuration.userContentController
        userContent.add(UserContentProxy(coordinator: context.coordinator), name: "linkTap")
        let js = """
        (function(){
          function handler(e){
            var a=e.target.closest('a[href]');
            if(!a) return;
            var href=a.href;
            try { window.webkit.messageHandlers.linkTap.postMessage(href); } catch(e) {}
          }
          document.addEventListener('click', handler, true);
        })();
        """
        let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        userContent.addUserScript(script)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // Use a modern Safari user agent to avoid UA-based blocks
        if preferMobileUserAgent {
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/605.1.15"
        } else {
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
        }
        // Increase readability if requested
        webView.pageZoom = pageZoom
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif
        // If reader mode preferred, wrap only NYT hosts via Jina reader; skip intermediaries like removepaywalls/archive
        var targetURL = url
        if preferReaderMode, let host = url.host?.lowercased() {
            let isNYTHost = (host == "www.nytimes.com" || host == "nytimes.com" || host.hasSuffix(".nytimes.com") || host == "nyti.ms")
            let isAlreadyReader = url.absoluteString.hasPrefix("https://r.jina.ai/") || url.absoluteString.hasPrefix("http://r.jina.ai/")
            let isIntermediary = (host == "removepaywalls.com" || host.contains("archive.is") || host.contains("archive.today"))
            if isNYTHost && !isAlreadyReader && !isIntermediary {
                if let wrapped = URL(string: "https://r.jina.ai/" + url.absoluteString) {
                    targetURL = wrapped
                }
            }
        }
        webView.load(URLRequest(url: targetURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No-op
    }

    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator(onArticleLink: onArticleLink, preferReaderMode: preferReaderMode) }
}
#endif

// Helper to avoid retaining cycles when adding script handlers
private final class UserContentProxy: NSObject, WKScriptMessageHandler {
    weak var coordinator: WebViewCoordinator?
    init(coordinator: WebViewCoordinator?) { self.coordinator = coordinator }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        coordinator?.userContentController(userContentController, didReceive: message)
    }
}


