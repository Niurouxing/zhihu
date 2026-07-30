import Foundation
import XCTest
@testable import iosApp

@MainActor
final class NativeNotificationFeatureTests: XCTestCase {
    func testNotificationDefaultsPreserveInviteOptIn() {
        let suite = "NativeNotificationFeatureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let preferences = NativeNotificationPreferences(defaults: defaults)

        XCTAssertTrue(preferences.displayInApp[.likeAnswer] == true)
        XCTAssertTrue(preferences.displayInApp[.likeComment] == true)
        XCTAssertTrue(preferences.displayInApp[.replyComment] == true)
        XCTAssertTrue(preferences.displayInApp[.inviteAnswer] == false)
        XCTAssertFalse(preferences.autoMarkAsRead)
        XCTAssertTrue(preferences.showsUnreadBadge)
    }

    func testUnknownNotificationVerbRemainsVisible() {
        let suite = "NativeNotificationUnknown.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = NativeNotificationPreferences(defaults: defaults)

        XCTAssertTrue(preferences.shouldDisplay(verb: "系统发布了一条新消息"))
        XCTAssertFalse(preferences.shouldDisplay(verb: "邀请你回答问题"))
    }

    func testCategorySwitchRetainsPerCategoryCache() async {
        let preferences = NativeNotificationPreferences(
            defaults: UserDefaults(suiteName: "NativeNotificationCache.\(UUID().uuidString)")!
        )
        let repository = NativeNotificationRepository(
            fetchPage: { category, _ in
                let item = NativeNotificationItem(
                    id: category.rawValue,
                    title: category.title,
                    subtitle: "",
                    body: "",
                    created: 1,
                    createdText: "刚刚",
                    isRead: true,
                    authorName: nil,
                    avatarURL: nil,
                    destination: nil
                )
                return NativePage(items: [item], paging: NativePaging(next: nil, isEnd: true))
            },
            fetchUnreadCounts: { [:] },
            markCategoryAsRead: { _ in }
        )
        let store = NativeNotificationStore(repository: repository, preferences: preferences)

        await store.refresh()
        await store.select(.likes)
        await store.select(.comments)

        XCTAssertEqual(store.items.map(\.id), [NativeNotificationCategory.comments.rawValue])
    }

    func testLiveRepositoryMarksOnlyRequestedCategoryWithV3MobileEndpoint() async throws {
        defer { NotificationURLProtocol.setHandler(nil) }
        let recorder = NotificationRequestRecorder()
        NotificationURLProtocol.setHandler { request in
            recorder.record(request)
            return (204, Data())
        }
        let client = ZhihuAPIClient(
            accountStore: NotificationAccountStore(),
            session: makeNotificationSession()
        )

        try await NativeNotificationRepository.live(client: client).markCategoryAsRead(.favorites)

        let request = try XCTUnwrap(recorder.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.zhihu.com/notifications/v3/timeline/entry/favlist_me/actions/readall"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-version"), "3.1.8")
    }

    func testUserReadActionOnlyClearsSelectedCategoryAndItsCachedPage() async {
        let marked = NotificationCategoryRecorder()
        let preferences = NativeNotificationPreferences(
            defaults: UserDefaults(suiteName: "NativeNotificationUserRead.\(UUID().uuidString)")!
        )
        let repository = makeCategoryRepository(marked: marked)
        let store = NativeNotificationStore(repository: repository, preferences: preferences)

        await store.refresh()
        await store.select(.likes)
        await store.select(.comments)
        await store.markCurrentCategoryAsReadFromUser()

        XCTAssertEqual(marked.categories, [.comments])
        XCTAssertEqual(store.unreadCounts[.comments], 0)
        XCTAssertEqual(store.unreadCounts[.likes], 3)
        XCTAssertTrue(store.items.allSatisfy(\.isRead))

        await store.select(.likes)
        XCTAssertEqual(store.unreadCounts[.likes], 3)
        XCTAssertTrue(store.items.allSatisfy { !$0.isRead })
    }

    func testAutomaticReadOnlyClearsCategoryBeingViewed() async {
        let marked = NotificationCategoryRecorder()
        let preferences = NativeNotificationPreferences(
            defaults: UserDefaults(suiteName: "NativeNotificationAutoRead.\(UUID().uuidString)")!
        )
        preferences.setAutoMarkAsRead(true)
        let store = NativeNotificationStore(
            repository: makeCategoryRepository(marked: marked),
            preferences: preferences
        )

        await store.refresh()

        XCTAssertEqual(marked.categories, [.comments])
        XCTAssertEqual(store.unreadCounts[.comments], 0)
        XCTAssertEqual(store.unreadCounts[.likes], 3)

        await store.select(.likes)

        XCTAssertEqual(marked.categories, [.comments, .likes])
        XCTAssertEqual(store.unreadCounts[.comments], 0)
        XCTAssertEqual(store.unreadCounts[.likes], 0)
        XCTAssertEqual(store.unreadCounts[.favorites], 4)
    }

    func testAccountChangeDropsAllNotificationCachesBeforeReload() async {
        let preferences = NativeNotificationPreferences(
            defaults: UserDefaults(suiteName: "NativeNotificationIsolation.\(UUID().uuidString)")!
        )
        let store = NativeNotificationStore(
            repository: makeCategoryRepository(marked: NotificationCategoryRecorder()),
            preferences: preferences
        )
        await store.refresh()
        await store.select(.likes)
        XCTAssertFalse(store.items.isEmpty)
        XCTAssertGreaterThan(store.unreadCount, 0)

        store.accountDidChange()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)
        await store.refresh()
        XCTAssertEqual(store.items.map(\.id), [NativeNotificationCategory.likes.rawValue])
    }

    private func makeCategoryRepository(
        marked: NotificationCategoryRecorder
    ) -> NativeNotificationRepository {
        NativeNotificationRepository(
            fetchPage: { category, _ in
                let item = NativeNotificationItem(
                    id: category.rawValue,
                    title: category.title,
                    subtitle: "",
                    body: "",
                    created: 1,
                    createdText: "刚刚",
                    isRead: false,
                    authorName: nil,
                    avatarURL: nil,
                    destination: nil
                )
                return NativePage(items: [item], paging: NativePaging(next: nil, isEnd: true))
            },
            fetchUnreadCounts: {
                marked.applyingReads(to: [
                    .comments: 2,
                    .likes: 3,
                    .favorites: 4,
                    .follows: 5,
                ])
            },
            markCategoryAsRead: { category in
                marked.record(category)
            }
        )
    }
}

private func makeNotificationSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NotificationURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class NotificationURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    private static let lock = NSLock()
    private static var storedHandler: Handler?

    static func setHandler(_ handler: Handler?) {
        lock.lock()
        storedHandler = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.storedHandler
        Self.lock.unlock()
        guard let handler else { return }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class NotificationRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    func record(_ request: URLRequest) {
        let captured = URLRequestBodyCapture.capture(request)
        lock.lock()
        storedRequest = captured
        lock.unlock()
    }
}

private final class NotificationCategoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCategories: [NativeNotificationCategory] = []

    var categories: [NativeNotificationCategory] {
        lock.lock()
        defer { lock.unlock() }
        return storedCategories
    }

    func record(_ category: NativeNotificationCategory) {
        lock.lock()
        storedCategories.append(category)
        lock.unlock()
    }

    func applyingReads(
        to counts: [NativeNotificationCategory: Int]
    ) -> [NativeNotificationCategory: Int] {
        lock.lock()
        defer { lock.unlock() }
        var result = counts
        for category in storedCategories {
            result[category] = 0
        }
        return result
    }
}

private final class NotificationAccountStore: AccountJSONStore, @unchecked Sendable {
    private let lock = NSLock()
    private var json = #"{"cookies":{"d_c0":"device","z_c0":"login","_xsrf":"token"},"userAgent":"test"}"#

    func load() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return json
    }

    func save(_ accountJSON: String) throws {
        lock.lock()
        json = accountJSON
        lock.unlock()
    }

    func clear() throws {
        lock.lock()
        json = ""
        lock.unlock()
    }
}
