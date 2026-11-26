import SwiftUI
import WebKit

/// 4. 酷天新闻：直接显示 coolnews.ca，内容和网站同步。
struct NewsView: View {
    static let home = URL(string: "https://coolnews.ca")!
    @StateObject private var web = WebState()

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "酷天新闻") {
                Button { web.goBack() } label: { CircleIcon(system: "chevron.left") }
                    .disabled(!web.canGoBack)
                    .accessibilityLabel("返回")
                Button { web.reload() } label: { CircleIcon(system: "arrow.clockwise") }
                    .accessibilityLabel("刷新")
                Link(destination: web.url ?? Self.home) { CircleIcon(system: "safari") }
                    .accessibilityLabel("在 Safari 中打开")
            }
            ZStack(alignment: .top) {
                WebView(state: web, start: Self.home)
                if web.progress < 1 {
                    ProgressView(value: web.progress)
                        .tint(Theme.me)
                        .frame(height: 2)
                }
                if let err = web.error {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 44)).foregroundStyle(Theme.them)
                        Text("新闻加载失败").font(.headline)
                        Text(err).font(.footnote).foregroundStyle(Theme.mute).multilineTextAlignment(.center)
                        Button("重试") { web.reload() }.buttonStyle(.borderedProminent).tint(Theme.me)
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
    }
}

@MainActor
final class WebState: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var url: URL?
    @Published var error: String?
    weak var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []

    func attach(_ w: WKWebView) {
        webView = w
        w.navigationDelegate = self
        observations = [
            w.observe(\.estimatedProgress) { [weak self] w, _ in
                let p = w.estimatedProgress
                Task { @MainActor in self?.progress = p }
            },
            w.observe(\.canGoBack) { [weak self] w, _ in
                let b = w.canGoBack
                Task { @MainActor in self?.canGoBack = b }
            },
            w.observe(\.url) { [weak self] w, _ in
                let u = w.url
                Task { @MainActor in self?.url = u }
            },
        ]
    }

    func goBack() { webView?.goBack() }
    func reload() {
        error = nil
        if webView?.url == nil { webView?.load(URLRequest(url: NewsView.home)) } else { webView?.reload() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in self.error = msg }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in self.error = msg }
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.error = nil; self.webView?.scrollView.refreshControl?.endRefreshing() }
    }
}

struct WebView: UIViewRepresentable {
    let state: WebState
    let start: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let w = WKWebView(frame: .zero, configuration: config)
        w.allowsBackForwardNavigationGestures = true
        w.isOpaque = false
        w.backgroundColor = UIColor(Theme.bg)
        w.scrollView.backgroundColor = UIColor(Theme.bg)
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak w] _ in w?.reload() }, for: .valueChanged)
        w.scrollView.refreshControl = refresh
        state.attach(w)
        w.load(URLRequest(url: start))
        return w
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
