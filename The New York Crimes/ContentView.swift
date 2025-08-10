//
//  ContentView.swift
//  The New York Crimes
//
//  Created by Oliver Tran on 8/9/25.
//

import SwiftUI
import WebKit
import AuthenticationServices

struct ContentView: View {
    @State private var isAuthenticating = false
    @State private var proxyURL: URL? = nil
    #if os(iOS)
    @State private var safariURL: URL? = nil
    #endif
    #if os(iOS)
    @State private var authPresentationContextProvider = ASPresentationAnchorProvider()
    #endif

    var body: some View {
        WebView(
            url: URL(string: "https://www.nytimes.com")!,
            onArticleLink: { url in
                proxyURL = url
            }
        )
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(isAuthenticating ? "Signing in…" : "Sign in") {
                    startNYTSignIn()
                }
                .disabled(isAuthenticating)
            }
        }
        .sheet(isPresented: Binding(
            get: { proxyURL != nil },
            set: { if !$0 { proxyURL = nil } }
        ), onDismiss: { proxyURL = nil }) {
            if let original = proxyURL {
                // Hidden resolver does all the steps offscreen; once resolved we display a clean WebView
                BouncingBunnyLoadingView()
                .padding(40)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    ResolverWebView(originalURL: original, preferReaderMode: true) { resolved in
                        #if os(iOS)
                        // If we resolved to archive snapshot and Reader is available, open Safari Reader
                        safariURL = resolved
                        proxyURL = nil
                        #else
                        proxyURL = resolved
                        #endif
                    }
                )
            }
        }
        #if os(iOS)
        .sheet(isPresented: Binding(
            get: { safariURL != nil },
            set: { if !$0 { safariURL = nil } }
        )) {
            if let url = safariURL { SafariView(url: url) }
        }
        #endif
    }

    private func startNYTSignIn() {
        #if os(iOS) || os(macOS)
        let authURL = URL(string: "https://myaccount.nytimes.com/auth/login")!
        let callbackScheme = "https" // broad enough; session completes within the page
        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { _, _ in
            isAuthenticating = false
        }
        isAuthenticating = true
        #if os(iOS)
        session.presentationContextProvider = authPresentationContextProvider
        #endif
        session.prefersEphemeralWebBrowserSession = false
        session.start()
        #endif
    }
}

#if os(iOS)
import UIKit
final class ASPresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? UIWindow()
    }
}
#endif

// Cute bouncing bunny loading indicator
struct BouncingBunnyLoadingView: View {
    @State private var isBouncing = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Capsule()
                    .fill(Color.black.opacity(0.1))
                    .frame(width: 64, height: 10)
                    .scaleEffect(x: isBouncing ? 1.08 : 0.92, y: 1.0)
                    .offset(y: 24)
                    .blur(radius: 0.5)

                Text("🐰")
                    .font(.system(size: 64))
                    .scaleEffect(isBouncing ? 1.05 : 0.95)
                    .offset(y: isBouncing ? -14 : -4)
                    .animation(
                        .interpolatingSpring(stiffness: 220, damping: 7)
                        .repeatForever(autoreverses: true),
                        value: isBouncing
                    )
            }
            .frame(height: 96)

            Text("Loading article…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .onAppear { isBouncing = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading article")
    }
}

#Preview {
    ContentView()
}

