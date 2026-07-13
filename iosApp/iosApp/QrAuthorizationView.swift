import AVFoundation
import SwiftUI
import UIKit
import WebKit

struct QrAuthorizationRequest: Equatable {
    let requestId: String
    let cookiesJSON: String

    init?(requestId: String?, cookiesJSON: String?) {
        guard let requestId,
              !requestId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let cookiesJSON,
              (try? RiskControlCookieCodec.cookieValues(from: cookiesJSON)) != nil
        else {
            return nil
        }
        self.requestId = requestId
        self.cookiesJSON = cookiesJSON
    }
}

enum QrAuthorizationURLPolicy {
    static let loginPrefix = "https://www.zhihu.com/account/scan/login/"

    static func validatedURL(from payload: String) -> URL? {
        guard payload.hasPrefix(loginPrefix), let url = URL(string: payload) else {
            return nil
        }
        return url
    }
}

@MainActor
final class QrAuthorizationModel: ObservableObject {
    enum Phase: Equatable {
        case scanning
        case scanFailure(String)
        case authorizing(URL)
    }

    @Published private(set) var phase: Phase = .scanning
    @Published private(set) var isWebLoading = false
    @Published private(set) var webErrorMessage: String?

    func receiveScan(_ payload: String) {
        guard phase == .scanning else { return }
        guard let url = QrAuthorizationURLPolicy.validatedURL(from: payload) else {
            phase = .scanFailure("这不是知乎扫码授权二维码")
            return
        }
        webErrorMessage = nil
        isWebLoading = true
        phase = .authorizing(url)
    }

    func scannerFailed(_ message: String) {
        guard phase == .scanning else { return }
        phase = .scanFailure(message)
    }

    func retryScanning() {
        guard case .scanFailure = phase else { return }
        webErrorMessage = nil
        isWebLoading = false
        phase = .scanning
    }

    func navigationStarted() {
        isWebLoading = true
        webErrorMessage = nil
    }

    func navigationFinished() {
        isWebLoading = false
    }

    func navigationFailed(_ error: Error) {
        isWebLoading = false
        webErrorMessage = error.localizedDescription
    }

    func authorizationSetupFailed() {
        isWebLoading = false
        webErrorMessage = "无法准备扫码授权页面"
    }
}

struct QrAuthorizationView: View {
    @StateObject private var model = QrAuthorizationModel()
    let request: QrAuthorizationRequest
    let onClose: () -> Void

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                NavigationStack {
                    content
                }
            } else {
                NavigationView {
                    content
                }
                .navigationViewStyle(.stack)
            }
        }
        .accessibilityIdentifier("qr_authorization_native_shell")
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch model.phase {
            case .scanning:
                scannerContent
            case let .scanFailure(message):
                failureContent(message)
            case let .authorizing(url):
                authorizationContent(url)
            }
        }
        .navigationTitle("扫码授权")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("关闭")
                .accessibilityIdentifier("qr_authorization_close")
            }
        }
    }

    private var scannerContent: some View {
        ZStack {
            QrCodeScannerView(
                onCode: model.receiveScan,
                onFailure: model.scannerFailed
            )
            .ignoresSafeArea(edges: .bottom)
            .accessibilityIdentifier("qr_authorization_scanner")

            VStack {
                Spacer()
                Label("扫描知乎网页上的登录二维码", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(.bottom, 28)
            }
        }
    }

    private func failureContent(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
            Button("重新扫描", action: model.retryScanning)
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("qr_authorization_retry")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("qr_authorization_failure")
    }

    private func authorizationContent(_ url: URL) -> some View {
        VStack(spacing: 0) {
            if model.isWebLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在打开授权页面")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
            } else if let message = model.webErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
            }

            QrAuthorizationWebView(
                url: url,
                cookiesJSON: request.cookiesJSON,
                onNavigationStarted: model.navigationStarted,
                onNavigationFinished: model.navigationFinished,
                onNavigationFailed: model.navigationFailed,
                onSetupFailed: model.authorizationSetupFailed
            )
            .accessibilityIdentifier("qr_authorization_webview_container")
        }
    }
}

private struct QrCodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> QrCodeScannerViewController {
        QrCodeScannerViewController(onCode: onCode, onFailure: onFailure)
    }

    func updateUIViewController(_ uiViewController: QrCodeScannerViewController, context: Context) {
        uiViewController.onCode = onCode
        uiViewController.onFailure = onFailure
    }

    static func dismantleUIViewController(
        _ uiViewController: QrCodeScannerViewController,
        coordinator: Void
    ) {
        uiViewController.stopScanning()
    }
}

private final class QrCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: (String) -> Void
    var onFailure: (String) -> Void

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.github.zly2006.zhplus.qr-scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasDeliveredResult = false
    private var isViewActive = true
    private var isSessionActive = true

    init(onCode: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
        self.onCode = onCode
        self.onFailure = onFailure
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        prepareCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    func stopScanning() {
        hasDeliveredResult = true
        isViewActive = false
        sessionQueue.async { [self] in
            isSessionActive = false
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func prepareCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureSession()
                } else {
                    self.reportFailure("未获得相机权限，无法扫描二维码")
                }
            }
        case .denied, .restricted:
            reportFailure("相机权限不可用，请在系统设置中允许访问相机")
        @unknown default:
            reportFailure("当前设备无法使用相机")
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.isSessionActive else { return }
            guard let device = AVCaptureDevice.default(for: .video) else {
                self.reportFailure("当前设备没有可用的相机")
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureMetadataOutput()
                guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                    self.reportFailure("无法启动二维码扫描")
                    return
                }
                self.session.addInput(input)
                self.session.addOutput(output)
                guard output.availableMetadataObjectTypes.contains(.qr) else {
                    self.reportFailure("当前设备不支持二维码扫描")
                    return
                }
                output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                output.metadataObjectTypes = [.qr]

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let layer = AVCaptureVideoPreviewLayer(session: self.session)
                    layer.videoGravity = .resizeAspectFill
                    layer.frame = self.view.bounds
                    self.view.layer.insertSublayer(layer, at: 0)
                    self.previewLayer = layer
                }
                self.session.startRunning()
            } catch {
                self.reportFailure("无法访问相机：\(error.localizedDescription)")
            }
        }
    }

    private func reportFailure(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isViewActive else { return }
            self.onFailure(message)
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasDeliveredResult,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue
        else {
            return
        }
        hasDeliveredResult = true
        stopScanning()
        onCode(value)
    }
}

private struct QrAuthorizationWebView: UIViewRepresentable {
    let url: URL
    let cookiesJSON: String
    let onNavigationStarted: () -> Void
    let onNavigationFinished: () -> Void
    let onNavigationFailed: (Error) -> Void
    let onSetupFailed: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.accessibilityIdentifier = "qr_authorization_webview"

        do {
            let cookies = try RiskControlCookieCodec.cookiesForInjection(
                cookiesJSON: cookiesJSON,
                pageURL: url
            )
            context.coordinator.install(cookies: cookies, in: webView, pageURL: url)
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
        var parent: QrAuthorizationWebView
        private var isActive = true

        init(parent: QrAuthorizationWebView) {
            self.parent = parent
        }

        func install(cookies: [HTTPCookie], in webView: WKWebView, pageURL: URL) {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) { [weak self, weak webView] in
                guard let self, self.isActive, let webView else { return }
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
