import Foundation
import SafariServices
import UIKit

enum ExternalWebURLPolicy {
    static func validatedURL(from value: String?) -> URL? {
        guard let value,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty
        else {
            return nil
        }
        return components.url
    }
}

struct ExternalURLFailure: Identifiable, Equatable {
    let url: String?
    let message: String

    var id: String { "\(url ?? "invalid"):\(message)" }
}

protocol ExternalURLOpening {
    @MainActor
    func open(_ url: URL, completion: @escaping @Sendable (Bool) -> Void)
}

struct UIApplicationExternalURLOpener: ExternalURLOpening {
    @MainActor
    func open(_ url: URL, completion: @escaping @Sendable (Bool) -> Void) {
        UIApplication.shared.open(url, options: [:], completionHandler: completion)
    }
}

protocol InAppExternalURLPresenting {
    @MainActor
    func present(_ url: URL, completion: @escaping @Sendable (Bool) -> Void)
}

struct SafariViewExternalURLPresenter: InAppExternalURLPresenting {
    @MainActor
    func present(_ url: URL, completion: @escaping @Sendable (Bool) -> Void) {
        guard let presenter = Self.presentationController() else {
            completion(false)
            return
        }
        presenter.present(SFSafariViewController(url: url), animated: true) {
            completion(true)
        }
    }

    @MainActor
    private static func presentationController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        return root.map(topViewController)
    }

    @MainActor
    private static func topViewController(from root: UIViewController) -> UIViewController {
        if let presented = root.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = root as? UINavigationController,
           let visible = navigation.visibleViewController {
            return topViewController(from: visible)
        }
        if let tabs = root as? UITabBarController,
           let selected = tabs.selectedViewController {
            return topViewController(from: selected)
        }
        return root
    }
}

@MainActor
final class ExternalURLCoordinator {
    private let opener: any ExternalURLOpening
    private let inAppPresenter: any InAppExternalURLPresenting

    init(
        opener: any ExternalURLOpening,
        inAppPresenter: any InAppExternalURLPresenting = SafariViewExternalURLPresenter()
    ) {
        self.opener = opener
        self.inAppPresenter = inAppPresenter
    }

    func open(
        _ url: URL,
        mode: NativeExternalPageOpeningMode,
        onFailure: @escaping (ExternalURLFailure) -> Void
    ) {
        let completion: @Sendable (Bool) -> Void = { accepted in
            guard !accepted else { return }
            Task { @MainActor in
                onFailure(
                    ExternalURLFailure(
                        url: url.absoluteString,
                        message: "无法打开这个链接，请稍后重试"
                    )
                )
            }
        }
        switch mode {
        case .inApp:
            inAppPresenter.present(url, completion: completion)
        case .defaultBrowser:
            opener.open(url, completion: completion)
        }
    }
}
