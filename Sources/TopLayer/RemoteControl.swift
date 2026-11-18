import SwiftUI
import WebKit

/// Claude replies via Remote Control: instead of injecting text into a session we
/// don't own, show Anthropic's own web client for that session (claude.ai/code/<id>)
/// inside the overlay. Messages typed there reach the live session as real user turns.
///
/// One web view is shared for the whole app so the claude.ai sign-in and the loaded
/// page survive switching sessions and collapsing the overlay.
final class RemoteWeb: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// claude.ai/code: Remote Control for live Claude sessions.
    static let shared = RemoteWeb(home: "https://claude.ai/code")
    /// Codex's own web client, as the fallback on that side.
    static let codex = RemoteWeb(home: "https://chatgpt.com/codex")

    let listURL: String

    /// Holds the main web view plus any sign-in pop-ups stacked on top of it.
    let container = NSView()
    let webView: WKWebView
    private var popups: [WKWebView] = []
    private var loadedTarget: String?

    init(home: String) {
        listURL = home
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()    // persistent: stay signed in across launches
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }

    /// `remoteId` is the session's Remote Control id (`session_…`); nil shows the session list.
    func show(remoteId: String?) {
        let target = remoteId.map { "\(listURL)/\($0)" } ?? listURL
        guard target != loadedTarget, let url = URL(string: target) else { return }
        loadedTarget = target
        webView.load(URLRequest(url: url))
    }

    /// Goes back to the selected session's page, which also recovers from a sign-in
    /// that landed somewhere else or a pop-up that got stuck.
    func reload() {
        closePopups()
        guard let target = loadedTarget, let url = URL(string: target) else { return }
        webView.load(URLRequest(url: url))
    }

    /// The view the user is looking at: the newest pop-up, or the main page.
    var topWebView: WKWebView { popups.last ?? webView }

    private func closePopups() {
        popups.forEach { $0.removeFromSuperview() }
        popups.removeAll()
    }

    // MARK: WKNavigationDelegate

    // Every step is traced so a stranded sign-in can be diagnosed from the log.
    // Host and path only: sign-in URLs can carry tokens in the query string.
    private func name(_ webView: WKWebView) -> String { webView === self.webView ? "main" : "popup" }
    private func place(_ url: URL?) -> String {
        guard let url else { return "(no url)" }
        return "\(url.scheme ?? "?")://\(url.host ?? "")\(url.path)"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let frame = navigationAction.targetFrame == nil ? "new-window" : (navigationAction.targetFrame!.isMainFrame ? "top" : "frame")
        if frame != "frame" {
            log("remote: \(name(webView)) go \(place(navigationAction.request.url)) [\(frame), type \(navigationAction.navigationType.rawValue)]")
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame {
            let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode ?? 0
            log("remote: \(name(webView)) response \(status) \(place(navigationResponse.response.url))")
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        log("remote: \(name(webView)) redirect -> \(place(webView.url))")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("remote: \(name(webView)) loaded \(place(webView.url)) title=\(webView.title ?? "")")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("remote: \(name(webView)) load failed (provisional): \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("remote: \(name(webView)) load failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("remote: \(name(webView)) web process terminated")
    }

    // MARK: WKUIDelegate

    /// Sign-in providers open a pop-up and hand the result back to the page that opened
    /// it (`window.opener`). That link only exists if the pop-up is a real child web view
    /// built from the configuration WebKit passes in; loading its URL in the main view
    /// instead leaves the sign-in stranded on a blank page.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: container.bounds, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.autoresizingMask = [.width, .height]
        container.addSubview(popup)
        popups.append(popup)
        log("remote: popup opened for \(place(navigationAction.request.url)) (\(popups.count) open)")
        return popup
    }

    /// The pop-up called `window.close()`, which is how a finished sign-in dismisses itself.
    func webViewDidClose(_ webView: WKWebView) {
        webView.removeFromSuperview()
        popups.removeAll { $0 === webView }
        log("remote: popup closed (\(popups.count) open)")
    }
}

/// Hosts whichever web client is asked for. Each `RemoteWeb` keeps its own web view
/// alive, so switching between Claude and Codex shows the page already loaded.
struct RemoteControlView: NSViewRepresentable {
    var web: RemoteWeb = .shared
    let remoteId: String?

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        attach(to: host)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        attach(to: host)
    }

    private func attach(to host: NSView) {
        web.show(remoteId: remoteId)
        let page = web.container
        guard page.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        page.frame = host.bounds
        page.autoresizingMask = [.width, .height]
        host.addSubview(page)
    }
}
