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
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { proxyURL != nil },
            set: { if !$0 { proxyURL = nil } }
        ), onDismiss: {
            // Ensure we clear any intermediate state when the cover is dismissed
            safariURL = nil
        }) {
            if let original = proxyURL {
                if let url = safariURL {
                    SafariView(url: url)
                } else {
                    // Hidden resolver does all the steps offscreen; once resolved we swap to SafariView within the same cover
                    BouncingBunnyLoadingView()
                        .padding(40)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            ResolverWebView(originalURL: original, preferReaderMode: true) { resolved in
                                // Switch content to Safari within the same full-screen cover
                                safariURL = resolved
                            }
                        )
                }
            }
        }
        #else
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
                        proxyURL = resolved
                    }
                )
            }
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
    @State private var dadJoke: String = ""

    private static let dadJokes: [String] = [
        "I used to hate facial hair… but then it grew on me.",
        "I ordered a chicken and an egg from Amazon. I’ll let you know.",
        "Why did the scarecrow win an award? He was outstanding in his field.",
        "I’m reading a book on anti-gravity. It’s impossible to put down!",
        "I would tell you a joke about construction, but I’m still working on it.",
        "What do you call fake spaghetti? An impasta.",
        "Why don’t eggs tell jokes? They’d crack each other up.",
        "What do you call cheese that isn’t yours? Nacho cheese.",
        "I don’t trust stairs. They’re always up to something.",
        "I used to be addicted to soap, but I’m clean now."
    ]

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

            if !dadJoke.isEmpty {
                Text(dadJoke)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Dad joke")
            }
        }
        .onAppear {
            isBouncing = true
            // Pick a local placeholder immediately, then try API
            dadJoke = Self.dadJokes.randomElement() ?? ""
            Task {
                if let fetched = await fetchDadJokeOrNil() {
                    await MainActor.run { dadJoke = fetched }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading article")
    }

    // MARK: - Dad Joke API
    private struct DadJokeResponse: Decodable { let joke: String }
    private func fetchDadJokeOrNil() async -> String? {
        do {
            var request = URLRequest(url: URL(string: "https://icanhazdadjoke.com/")!)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("The New York Crimes (dadjokes)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                let decoded = try JSONDecoder().decode(DadJokeResponse.self, from: data)
                let trimmed = decoded.joke.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        } catch {
            // Silent fallback to local list
        }
        return nil
    }
}

#Preview {
    ContentView()
}

