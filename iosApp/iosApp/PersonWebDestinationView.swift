import SwiftUI
import WebKit

struct PersonWebDestinationView: View {
    let route: PersonWebRoute
    @StateObject private var model: PersonWebDestinationModel

    init(
        route: PersonWebRoute,
        accountStore: AccountJSONStore,
        openExternal: @escaping (URL) -> Void
    ) {
        self.route = route
        _model = StateObject(wrappedValue: PersonWebDestinationModel(
            route: route,
            accountStore: accountStore,
            openExternal: openExternal
        ))
    }

    var body: some View {
        ZStack {
            PersonWebView(webView: model.webView)
            if model.isLoading {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            if let error = model.error {
                PersonWebFailure(message: error, retry: model.reload)
                    .background(Color(.systemBackground))
            }
        }
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: model.goBack) { Image(systemName: "chevron.backward") }
                    .disabled(!model.canGoBack)
                    .accessibilityLabel("网页后退")
                Button(action: model.goForward) { Image(systemName: "chevron.forward") }
                    .disabled(!model.canGoForward)
                    .accessibilityLabel("网页前进")
                Button(action: model.reload) { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("重新加载")
                if #available(iOS 16, *) {
                    ShareLink(item: model.currentURL ?? route.url) { Image(systemName: "square.and.arrow.up") }
                } else {
                    PersonWebLegacyShareButton(url: model.currentURL ?? route.url)
                }
            }
        }
        .task { await model.loadIfNeeded() }
        .accessibilityIdentifier("person_web_destination")
    }
}

@MainActor
private final class PersonWebDestinationModel: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var error: String?
    @Published var currentURL: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false

    private let route: PersonWebRoute
    private let accountStore: AccountJSONStore
    private let openExternal: (URL) -> Void
    private var progressObservation: NSKeyValueObservation?
    private var hasLoaded = false

    init(
        route: PersonWebRoute,
        accountStore: AccountJSONStore,
        openExternal: @escaping (URL) -> Void
    ) {
        self.route = route
        self.accountStore = accountStore
        self.openExternal = openExternal
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in self?.progress = view.estimatedProgress }
        }
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    func reload() {
        Task { await load() }
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    func goForward() {
        if webView.canGoForward { webView.goForward() }
    }

    private func load() async {
        do {
            error = nil
            isLoading = true
            let account = try loadAccount()
            webView.customUserAgent = account.userAgent
            for cookie in account.cookies {
                await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            }
            webView.load(URLRequest(url: route.url))
        } catch {
            isLoading = false
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        updateNavigationState()
        persistWebCookies()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        error = nil
        updateNavigationState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if Self.isTrustedZhihuURL(url) {
            decisionHandler(.allow)
        } else if url.scheme == "https" || url.scheme == "http" {
            openExternal(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.cancel)
        }
    }

    private func navigationFailed(_ failure: Error) {
        if (failure as NSError).code == NSURLErrorCancelled { return }
        isLoading = false
        error = failure.localizedDescription
        updateNavigationState()
    }

    private func updateNavigationState() {
        currentURL = webView.url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func loadAccount() throws -> (cookies: [HTTPCookie], userAgent: String) {
        guard let account = try ZhihuAccountSessionCodec.credentials(from: accountStore.load()) else {
            return ([], ZhihuAPIClient.defaultUserAgent)
        }
        let cookies = account.cookies.compactMap { name, value -> HTTPCookie? in
            HTTPCookie(properties: [
                .name: name,
                .value: value,
                .domain: ".zhihu.com",
                .path: "/",
                .secure: "TRUE",
                .originURL: route.url,
            ])
        }
        let userAgent = account.userAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cookies, userAgent?.isEmpty == false ? userAgent! : ZhihuAPIClient.defaultUserAgent)
    }

    private func persistWebCookies() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self else { return }
                do {
                    try ZhihuAccountCookieWriter.merge(cookies: cookies, into: self.accountStore)
                } catch {
                    self.error = "账号 Cookie 保存失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private static func isTrustedZhihuURL(_ url: URL) -> Bool {
        ZhihuAPIURLPolicy.allows(url)
    }
}

private struct PersonWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

private struct PersonWebFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
            Text("网页加载失败").font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("重试", action: retry).buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PersonWebLegacyShareButton: View {
    let url: URL
    @State private var isPresenting = false

    var body: some View {
        Button { isPresenting = true } label: { Image(systemName: "square.and.arrow.up") }
            .sheet(isPresented: $isPresenting) {
                PersonWebActivityController(items: [url])
            }
    }
}

private struct PersonWebActivityController: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
