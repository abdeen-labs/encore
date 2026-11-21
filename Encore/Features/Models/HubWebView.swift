import AppKit
import SwiftUI
import WebKit

/// State of the in-app Hugging Face page: where it is, whether it can go back, and any popup a page
/// opened (`window.open`, SSO sign-in windows).
@Observable final class HubWebPage: NSObject {
    var url: URL
    var host: String
    var isSecure = true
    var isLoading = false
    var canGoBack = false
    var popup: WKWebView?
    @ObservationIgnored fileprivate(set) var webView: WKWebView?

    init(url: URL) {
        self.url = url
        host = url.host ?? ""
    }

    func goBack() { webView?.goBack() }
    func reload() { webView?.reload() }
    func openInBrowser() { NSWorkspace.shared.open(webView?.url ?? url) }
    func closePopup() { popup?.stopLoading(); popup = nil }

    fileprivate func update(from web: WKWebView) {
        if let u = web.url { url = u; host = u.host ?? ""; isSecure = u.scheme == "https" }
        isLoading = web.isLoading
        canGoBack = web.canGoBack
    }
}

extension HubWebPage: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { update(from: webView) }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { update(from: webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { update(from: webView) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { update(from: webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        update(from: webView)
    }

    /// `window.open` and sign-in popups: a real child web view sharing the configuration (and so the
    /// opener relationship and cookies), shown over the page.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let child = WKWebView(frame: .zero, configuration: configuration)
        child.navigationDelegate = self
        child.uiDelegate = self
        popup = child
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === popup { popup = nil }
    }
}

/// The page itself. Uses the default (persistent) website data store, so signing in to Hugging Face sticks.
struct HubWebView: NSViewRepresentable {
    let page: HubWebPage

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = page
        web.uiDelegate = page
        web.allowsBackForwardNavigationGestures = true
        web.underPageBackgroundColor = NSColor(Color.surfaceSunken)
        page.webView = web
        web.load(URLRequest(url: page.url))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Hosts a popup web view created by the page.
struct PopupWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
