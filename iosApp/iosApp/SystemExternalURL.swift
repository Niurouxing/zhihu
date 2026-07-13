import Foundation
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

@MainActor
final class ExternalURLCoordinator {
    private let opener: any ExternalURLOpening

    init(opener: any ExternalURLOpening) {
        self.opener = opener
    }

    func open(_ url: URL, onFailure: @escaping (ExternalURLFailure) -> Void) {
        opener.open(url) { accepted in
            guard !accepted else { return }
            onFailure(
                ExternalURLFailure(
                    url: url.absoluteString,
                    message: "系统无法打开这个链接，请稍后重试"
                )
            )
        }
    }
}
