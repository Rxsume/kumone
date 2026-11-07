// Sources/Kumone/Features/Player/UrlBackgroundView.swift
//
// Folia `url` （嵌入） background, re-implemented natively with
// WebKit.
//
// Folia source: `components/visualizer/backgrounds/url/`
// (`UrlBackground.tsx`). Folia embeds a user-chosen webpage in an
// inert frame (`pointer-events: none`, no scrolling) behind a fixed
// dark readability gradient. The native version is a `WKWebView`
// wrapped in a `UIViewRepresentable`: interaction and scrolling are
// disabled, so no link can be tapped and no navigation handling is
// needed, and the same fixed top-to-bottom black gradient
// (0.15 → 0.35) sits on top in SwiftUI.
//
// If the page fails to load, the web view stays blank (clear) under
// the gradient — there is no error UI for a background, and the page
// is only reloaded when the URL itself changes.

#if os(iOS)

import SwiftUI
import UIKit
import WebKit

/// Folia `url` background: a user-chosen webpage in an inert frame,
/// under a fixed dark readability gradient.
public struct UrlBackgroundView: View {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public var body: some View {
        ZStack {
            UrlWebView(url: url)
            // Fixed Folia readability gradient, top to bottom.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.15), location: 0),
                    .init(color: .black.opacity(0.35), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - Web view

/// Inert `WKWebView`: no scrolling, no user interaction (Folia's
/// `pointer-events: none`), transparent so a failed load shows the
/// SwiftUI background colour through it. Loads once; reloads only
/// when the URL changes.
private struct UrlWebView: UIViewRepresentable {
    var url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.scrollView.isScrollEnabled = false
        webView.isUserInteractionEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        context.coordinator.load(url, into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(url, into: webView)
    }

    final class Coordinator: NSObject {
        private var loadedURL: URL?

        func load(_ url: URL, into webView: WKWebView) {
            guard loadedURL != url else { return }
            loadedURL = url
            webView.load(URLRequest(url: url))
        }
    }
}

#endif
