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
            markAllAsRead: {}
        )
        let store = NativeNotificationStore(repository: repository, preferences: preferences)

        await store.refresh()
        await store.select(.likes)
        await store.select(.comments)

        XCTAssertEqual(store.items.map(\.id), [NativeNotificationCategory.comments.rawValue])
    }
}
