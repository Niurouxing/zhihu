import SwiftUI
import WebKit

@MainActor
final class RiskControlModel: ObservableObject {
    @Published private(set) var isLoading = true
    @Published private(set) var isCompleting = false
    @Published private(set) var errorMessage: String?

    let request: RiskControlRequest

    private let onCompleted: (String) async throws -> Void
    private var cookieStore: WKHTTPCookieStore?
    private var completionGate = LoginSubmissionGate()

    init(
        request: RiskControlRequest,
        onCompleted: @escaping (String) async throws -> Void
    ) {
        self.request = request
        self.onCompleted = onCompleted
    }

    var canComplete: Bool {
        cookieStore != nil && !isLoading && !isCompleting
    }

    func activate() {
        completionGate.activate()
    }

    func attachCookieStore(_ cookieStore: WKHTTPCookieStore) {
        self.cookieStore = cookieStore
    }

    func navigationStarted() {
        isLoading = true
        errorMessage = nil
    }

    func navigationFinished() {
        isLoading = false
    }

    func navigationFailed(_ error: Error) {
        isLoading = false
        errorMessage = error.localizedDescription
    }

    func setupFailed() {
        isLoading = false
        errorMessage = "无法准备安全验证页面"
    }

    func cancel() {
        completionGate.deactivate()
        isCompleting = false
    }

    func complete() {
        guard let cookieStore,
              let submissionID = completionGate.beginSubmission()
        else {
            return
        }

        isCompleting = true
        errorMessage = nil
        cookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self, self.completionGate.accepts(submissionID) else { return }
                do {
                    let cookiesJSON = try ZhihuCookieCollector.jsonString(
                        from: cookies,
                        for: self.request.url
                    )
                    do {
                        try await self.onCompleted(cookiesJSON)
                        guard self.completionGate.finish(submissionID) else { return }
                        self.isCompleting = false
                        self.completionGate.deactivate()
                    } catch {
                        guard self.completionGate.finish(submissionID) else { return }
                        self.isCompleting = false
                        self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                } catch {
                    _ = self.completionGate.finish(submissionID)
                    self.isCompleting = false
                    self.errorMessage = "无法读取验证信息，请重试"
                }
            }
        }
    }
}

struct RiskControlView: View {
    @StateObject private var model: RiskControlModel
    private let onClose: (String) -> Void

    init(
        request: RiskControlRequest,
        onClose: @escaping (String) -> Void,
        onCompleted: @escaping (String) async throws -> Void
    ) {
        self.onClose = onClose
        _model = StateObject(
            wrappedValue: RiskControlModel(
                request: request,
                onCompleted: onCompleted
            )
        )
    }

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                NavigationStack {
                    riskControlContent
                }
            } else {
                NavigationView {
                    riskControlContent
                }
                .navigationViewStyle(.stack)
            }
        }
        .accessibilityIdentifier("risk_control_native_shell")
        .onAppear(perform: model.activate)
        .onDisappear(perform: model.cancel)
        .interactiveDismissDisabled(model.isCompleting)
    }

    private var riskControlContent: some View {
        VStack(spacing: 0) {
            statusView

            RiskControlWebView(
                request: model.request,
                onCookieStoreReady: model.attachCookieStore,
                onNavigationStarted: model.navigationStarted,
                onNavigationFinished: model.navigationFinished,
                onNavigationFailed: model.navigationFailed,
                onSetupFailed: model.setupFailed
            )
        }
        .navigationTitle("安全验证")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    model.cancel()
                    onClose(model.request.requestId)
                } label: {
                    Image(systemName: "xmark")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("关闭")
                .accessibilityIdentifier("risk_control_close")
                .disabled(model.isCompleting)
            }

            ToolbarItem(placement: .bottomBar) {
                Button(action: model.complete) {
                    Label("完成验证并重试", systemImage: "checkmark.circle")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("risk_control_complete")
                .disabled(!model.canComplete)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if model.isCompleting {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在提交验证")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("risk_control_completing")
            Divider()
        } else if model.isLoading {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在加载安全验证")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("risk_control_loading")
            Divider()
        } else if let errorMessage = model.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
        }
    }
}

private struct RiskControlWebView: UIViewRepresentable {
    let request: RiskControlRequest
    let onCookieStoreReady: (WKHTTPCookieStore) -> Void
    let onNavigationStarted: () -> Void
    let onNavigationFinished: () -> Void
    let onNavigationFailed: (Error) -> Void
    let onSetupFailed: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.accessibilityIdentifier = "risk_control_webview"

        do {
            let cookies = try RiskControlCookieCodec.cookiesForInjection(
                cookiesJSON: request.cookiesJSON,
                pageURL: request.url
            )
            context.coordinator.install(cookies: cookies, in: webView, pageURL: request.url)
        } catch {
            onSetupFailed()
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.deactivate()
        uiView.navigationDelegate = nil
        uiView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: RiskControlWebView
        private var isActive = true

        init(parent: RiskControlWebView) {
            self.parent = parent
        }

        func install(cookies: [HTTPCookie], in webView: WKWebView, pageURL: URL) {
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                cookieStore.setCookie(cookie) {
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self, weak webView] in
                guard let self, self.isActive, let webView else { return }
                self.parent.onCookieStoreReady(cookieStore)
                webView.load(URLRequest(url: pageURL))
            }
        }

        func deactivate() {
            isActive = false
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onNavigationStarted()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onNavigationFinished()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.onNavigationFailed(error)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.onNavigationFailed(error)
        }
    }
}
