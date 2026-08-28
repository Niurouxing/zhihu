import CoreGraphics
import XCTest
@testable import iosApp

@MainActor
final class NativeShellPreferencesTests: XCTestCase {
    func testHapticPreferencesDefaultEnabledAtStandardStrength() {
        let preferences = NativeShellPreferences(defaults: makeDefaults())

        XCTAssertTrue(preferences.hapticsEnabled)
        XCTAssertEqual(preferences.hapticStrength, .standard)
        XCTAssertEqual(
            preferences.hapticFeedbackConfiguration,
            .init(isEnabled: true, strength: .standard)
        )
    }

    func testExternalPageOpeningDefaultsToBrowserAndPersistsInAppChoice() {
        let defaults = makeDefaults()
        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.externalPageOpeningMode, .defaultBrowser)

        preferences.setExternalPageOpeningMode(.inApp)

        XCTAssertEqual(
            NativeShellPreferences(defaults: defaults).externalPageOpeningMode,
            .inApp
        )
        XCTAssertEqual(
            defaults.string(forKey: NativeShellPreferences.Key.externalPageOpeningMode),
            NativeExternalPageOpeningMode.inApp.rawValue
        )
    }

    func testExternalPageOpeningRejectsUnknownStoredValueWithoutRewritingIt() {
        let defaults = makeDefaults()
        defaults.set("future-mode", forKey: NativeShellPreferences.Key.externalPageOpeningMode)

        XCTAssertEqual(
            NativeShellPreferences(defaults: defaults).externalPageOpeningMode,
            .defaultBrowser
        )
        XCTAssertEqual(
            defaults.string(forKey: NativeShellPreferences.Key.externalPageOpeningMode),
            "future-mode"
        )
    }

    func testRecommendationPreferencesDefaultPersistAndClampTargetCount() {
        let defaults = makeDefaults()
        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.homeRecommendationSource, .app)
        XCTAssertEqual(preferences.homeRefreshTargetItemCount, 20)
        XCTAssertEqual(
            preferences.homeRecommendationRefreshConfiguration,
            .defaultValue
        )

        preferences.setHomeRecommendationSource(.web)
        preferences.setHomeRefreshTargetItemCount(3)
        XCTAssertEqual(preferences.homeRefreshTargetItemCount, 6)

        let restored = NativeShellPreferences(defaults: defaults)
        XCTAssertEqual(restored.homeRecommendationSource, .web)
        XCTAssertEqual(restored.homeRefreshTargetItemCount, 6)

        restored.setHomeRefreshTargetItemCount(50)
        XCTAssertEqual(restored.homeRefreshTargetItemCount, 20)
    }

    func testHapticPreferencesPersistUserOverridesAndRejectUnknownStrength() {
        let defaults = makeDefaults()
        let preferences = NativeShellPreferences(defaults: defaults)

        preferences.setHapticsEnabled(false)
        preferences.setHapticStrength(.strong)

        let restored = NativeShellPreferences(defaults: defaults)
        XCTAssertFalse(restored.hapticsEnabled)
        XCTAssertEqual(restored.hapticStrength, .strong)

        defaults.set("unknown", forKey: NativeShellPreferences.Key.hapticStrength)
        XCTAssertEqual(NativeShellPreferences(defaults: defaults).hapticStrength, .standard)
    }

    func testQuestionAuthorBlocklistPersistsDeduplicatesAndUnblocks() {
        let defaults = makeDefaults()
        let first = FeedAuthorDTO(
            memberID: "asker",
            urlToken: "old-token",
            displayName: "旧名称",
            avatarURL: nil,
            headline: ""
        )
        let updated = FeedAuthorDTO(
            memberID: "asker",
            urlToken: "new-token",
            displayName: "新名称",
            avatarURL: URL(string: "https://pic.zhimg.com/asker.jpg"),
            headline: ""
        )
        let store = QuestionAuthorBlocklistStore(defaults: defaults)

        store.block(first, now: Date(timeIntervalSince1970: 10))
        store.block(updated, now: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.displayName, "新名称")
        XCTAssertTrue(store.isBlocked(memberID: "asker"))

        let restored = QuestionAuthorBlocklistStore(defaults: defaults)
        XCTAssertEqual(restored.entries, store.entries)

        restored.unblock(memberID: "asker")
        XCTAssertFalse(restored.isBlocked(memberID: "asker"))
        XCTAssertTrue(QuestionAuthorBlocklistStore(defaults: defaults).entries.isEmpty)
    }

    func testQuestionAuthorBlocklistIgnoresMalformedPersistence() {
        let defaults = makeDefaults()
        defaults.set(
            Data("not-json".utf8),
            forKey: "blockedQuestionAuthors.v1"
        )

        XCTAssertTrue(QuestionAuthorBlocklistStore(defaults: defaults).entries.isEmpty)
    }

    func testHapticFeedbackActionGatesDeliveryAndForwardsConfiguredStrength() {
        var deliveredEvent: NativeHapticFeedbackEvent?
        var deliveredStrength: NativeHapticStrength?
        let enabled = NativeHapticFeedbackAction(
            configuration: .init(isEnabled: true, strength: .light)
        ) { event, strength in
            deliveredEvent = event
            deliveredStrength = strength
        }

        enabled(.longPress)

        XCTAssertEqual(deliveredEvent, .longPress)
        XCTAssertEqual(deliveredStrength, .light)

        enabled(.refreshSucceeded)

        XCTAssertEqual(deliveredEvent, .refreshSucceeded)
        XCTAssertEqual(deliveredStrength, .light)

        let disabled = NativeHapticFeedbackAction(
            configuration: .init(isEnabled: false, strength: .strong)
        ) { event, strength in
            deliveredEvent = event
            deliveredStrength = strength
        }
        deliveredEvent = nil
        deliveredStrength = nil

        disabled(.commit)

        XCTAssertNil(deliveredEvent)
        XCTAssertNil(deliveredStrength)
    }

    func testHapticStrengthPreviewUsesExplicitNewStrengthExactlyOnce() {
        var deliveredEvents: [NativeHapticFeedbackEvent] = []
        var deliveredStrengths: [NativeHapticStrength] = []
        let action = NativeHapticFeedbackAction(
            configuration: .init(isEnabled: true, strength: .light)
        ) { event, strength in
            deliveredEvents.append(event)
            deliveredStrengths.append(strength)
        }

        action.previewStrength(.strong)

        XCTAssertEqual(deliveredEvents, [.strengthPreview])
        XCTAssertEqual(deliveredStrengths, [.strong])
    }

    func testHapticStrengthSelectionOnlyPreviewsEnabledUserChanges() {
        XCTAssertTrue(NativeHapticStrengthSelectionPolicy.shouldPreview(
            current: .standard,
            selected: .strong,
            isHapticsEnabled: true
        ))
        XCTAssertFalse(NativeHapticStrengthSelectionPolicy.shouldPreview(
            current: .strong,
            selected: .strong,
            isHapticsEnabled: true
        ))
        XCTAssertFalse(NativeHapticStrengthSelectionPolicy.shouldPreview(
            current: .standard,
            selected: .strong,
            isHapticsEnabled: false
        ))
    }

    func testHomeChannelsHaveFixedProductOrder() {
        XCTAssertEqual(HomeChannel.allCases, [.recommendation, .following, .hot, .daily])
        XCTAssertEqual(HomeChannel.allCases.map(\.id), [
            "recommendation",
            "following",
            "hot",
            "daily",
        ])
        XCTAssertEqual(HomeChannel.allCases.map(\.id), HomeChannel.allCases.map(\.rawValue))
        XCTAssertEqual(HomeChannel.allCases.map(\.title), ["推荐", "关注", "热榜", "日报"])
    }

    func testChannelSwipeRequiresHorizontalIntentAndEnoughDistance() {
        XCTAssertEqual(channelTarget(
            currentIndex: 1,
            translation: CGSize(width: 100, height: 100),
            predicted: CGSize(width: 180, height: 100)
        ), 1)
        XCTAssertEqual(channelTarget(
            currentIndex: 1,
            translation: CGSize(width: 17, height: 0),
            predicted: CGSize(width: 24, height: 0)
        ), 1)
    }

    func testChannelSwipeMovesOnePositionForDistanceOrPrediction() {
        XCTAssertEqual(channelTarget(
            currentIndex: 1,
            translation: CGSize(width: -18, height: 0),
            predicted: CGSize(width: -18, height: 0)
        ), 2)
        XCTAssertEqual(channelTarget(
            currentIndex: 2,
            translation: CGSize(width: 18, height: 0),
            predicted: CGSize(width: 18, height: 0)
        ), 1)
        XCTAssertEqual(channelTarget(
            currentIndex: 1,
            translation: CGSize(width: -5, height: 0),
            predicted: CGSize(width: -25, height: 0)
        ), 2)
    }

    func testChannelSwipeNeverCrossesEdgesAndRejectsZeroWidth() {
        XCTAssertEqual(channelTarget(
            currentIndex: 0,
            translation: CGSize(width: 100, height: 0),
            predicted: CGSize(width: 140, height: 0)
        ), 0)
        XCTAssertEqual(channelTarget(
            currentIndex: 3,
            translation: CGSize(width: -100, height: 0),
            predicted: CGSize(width: -140, height: 0)
        ), 3)
        XCTAssertEqual(channelTarget(
            currentIndex: 2,
            translation: CGSize(width: -100, height: 0),
            predicted: CGSize(width: -140, height: 0),
            containerWidth: 0
        ), 2)
    }

    func testHomeChannelRefreshStatusCoversLoadingAndRelativeTimeBoundaries() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(HomeChannelRefreshStatusText.text(
            lastSuccessfulRefreshAt: nil,
            isRefreshing: false,
            now: now
        ), "尚未更新")
        XCTAssertEqual(HomeChannelRefreshStatusText.text(
            lastSuccessfulRefreshAt: nil,
            isRefreshing: true,
            now: now
        ), "更新中…")
        XCTAssertEqual(HomeChannelRefreshStatusText.text(
            lastSuccessfulRefreshAt: now.addingTimeInterval(-30),
            isRefreshing: false,
            now: now
        ), "刚刚更新")
        XCTAssertEqual(HomeChannelRefreshStatusText.text(
            lastSuccessfulRefreshAt: now.addingTimeInterval(-4 * 60),
            isRefreshing: false,
            now: now
        ), "4 分钟前更新")
        XCTAssertEqual(HomeChannelRefreshStatusText.text(
            lastSuccessfulRefreshAt: now.addingTimeInterval(-60 * 60),
            isRefreshing: false,
            now: now
        ), "1 小时前更新")
        XCTAssertEqual(HomeChannelRefreshStatusText.text(
            lastSuccessfulRefreshAt: now.addingTimeInterval(-2 * 60 * 60),
            isRefreshing: false,
            now: now
        ), "2 小时前更新")
    }

    func testHomeRefreshPresentationMapKeepsEveryChannelMetadataAndLoadingState() {
        let recommendationDate = Date(timeIntervalSince1970: 101)
        let followingDate = Date(timeIntervalSince1970: 202)
        let hotDate = Date(timeIntervalSince1970: 303)
        let dailyDate = Date(timeIntervalSince1970: 404)
        let presentations = HomeChannelRefreshPresentationMap(
            recommendation: .init(
                metadata: .init(lastSuccessfulRefreshAt: recommendationDate, lastViewedAt: nil),
                isRefreshing: false
            ),
            following: .init(
                metadata: .init(lastSuccessfulRefreshAt: followingDate, lastViewedAt: nil),
                isRefreshing: true
            ),
            hot: .init(
                metadata: .init(lastSuccessfulRefreshAt: hotDate, lastViewedAt: nil),
                isRefreshing: false
            ),
            daily: .init(
                metadata: .init(lastSuccessfulRefreshAt: dailyDate, lastViewedAt: nil),
                isRefreshing: true
            )
        )

        XCTAssertEqual(
            presentations.presentation(for: .recommendation).metadata.lastSuccessfulRefreshAt,
            recommendationDate
        )
        XCTAssertEqual(
            presentations.presentation(for: .following).metadata.lastSuccessfulRefreshAt,
            followingDate
        )
        XCTAssertTrue(presentations.presentation(for: .following).isRefreshing)
        XCTAssertEqual(
            presentations.presentation(for: .hot).metadata.lastSuccessfulRefreshAt,
            hotDate
        )
        XCTAssertEqual(
            presentations.presentation(for: .daily).metadata.lastSuccessfulRefreshAt,
            dailyDate
        )
        XCTAssertTrue(presentations.presentation(for: .daily).isRefreshing)
    }

    func testHomeTopBarHasOnlyCreationAndNotificationControls() {
        XCTAssertEqual(HomeTopBarControl.visibleControls, [.creation, .notifications])
    }

    func testHomeNotificationIndicatorOnlyShowsDotForUnreadNotifications() {
        let empty = HomeNotificationIndicatorPresentation(unreadCount: 0)
        XCTAssertFalse(empty.showsDot)
        XCTAssertEqual(empty.accessibilityLabel, "通知")
        XCTAssertEqual(empty.accessibilityValue, "无未读通知")

        let unread = HomeNotificationIndicatorPresentation(unreadCount: 3)
        XCTAssertTrue(unread.showsDot)
        XCTAssertEqual(unread.accessibilityLabel, "通知，3 条未读")
        XCTAssertEqual(unread.accessibilityValue, "3 条未读")
    }

    func testInvalidThemeFallsBackWithoutOverwritingStoredRawValue() {
        let defaults = makeDefaults()
        defaults.set("FUTURE", forKey: NativeShellPreferences.Key.themeMode)

        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.themeMode, .system)
        XCTAssertEqual(defaults.string(forKey: NativeShellPreferences.Key.themeMode), "FUTURE")
    }

    func testRestoredReadingFeedSearchAndSharePreferencesConsumeLegacyKeys() {
        let defaults = makeDefaults()
        defaults.set(125, forKey: NativeShellPreferences.Key.contentFontSize)
        defaults.set(180, forKey: NativeShellPreferences.Key.contentLineHeight)
        defaults.set(130, forKey: NativeShellPreferences.Key.contentBlockSpacing)
        defaults.set(false, forKey: NativeShellPreferences.Key.showFeedThumbnail)
        defaults.set(false, forKey: NativeShellPreferences.Key.showSearchHotSearch)
        defaults.set(false, forKey: NativeShellPreferences.Key.showSearchHistory)
        defaults.set("copy", forKey: NativeShellPreferences.Key.shareActionMode)

        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.contentFontSizePercent, 125)
        XCTAssertEqual(preferences.contentLineHeightPercent, 180)
        XCTAssertEqual(preferences.contentBlockSpacingPercent, 130)
        XCTAssertFalse(preferences.showsFeedThumbnails)
        XCTAssertFalse(preferences.showsSearchHotSearch)
        XCTAssertFalse(preferences.showsSearchHistory)
        XCTAssertEqual(preferences.defaultShareAction, .copyLink)
    }

    func testRestoredPreferenceSettersPersistSemanticValues() {
        let defaults = makeDefaults()
        let preferences = NativeShellPreferences(defaults: defaults)

        preferences.setFeedDensity(.compact)
        preferences.setFeedExcerptLines(4)
        preferences.setDefaultShareAction(.systemShare)

        XCTAssertEqual(defaults.string(forKey: NativeShellPreferences.Key.feedDensity), "compact")
        XCTAssertEqual(defaults.integer(forKey: NativeShellPreferences.Key.feedExcerptLines), 4)
        XCTAssertEqual(defaults.string(forKey: NativeShellPreferences.Key.shareActionMode), "share")
    }

    func testRefreshHapticRequiresAChangedExistingSuccessTimestamp() {
        let firstSuccess = Date(timeIntervalSince1970: 100)
        let nextSuccess = Date(timeIntervalSince1970: 200)

        XCTAssertFalse(NativeRefreshHapticPolicy.shouldEmit(
            previousSuccessfulRefreshAt: nil,
            currentSuccessfulRefreshAt: firstSuccess
        ))
        XCTAssertFalse(NativeRefreshHapticPolicy.shouldEmit(
            previousSuccessfulRefreshAt: firstSuccess,
            currentSuccessfulRefreshAt: firstSuccess
        ))
        XCTAssertFalse(NativeRefreshHapticPolicy.shouldEmit(
            previousSuccessfulRefreshAt: firstSuccess,
            currentSuccessfulRefreshAt: nil
        ))
        XCTAssertTrue(NativeRefreshHapticPolicy.shouldEmit(
            previousSuccessfulRefreshAt: firstSuccess,
            currentSuccessfulRefreshAt: nextSuccess
        ))
    }

    func testHomeChromeRangesPlaceSearchBeforeRefreshOverscroll() {
        XCTAssertEqual(
            NativeHomeTopChromeLayout.revealedOffset,
            0
        )
        XCTAssertEqual(
            NativeHomeTopChromeLayout.collapsedOffset,
            NativeHomeTopChromeLayout.refreshRevealHeight
        )
        XCTAssertEqual(
            NativeHomeTopChromeLayout.hiddenLeadingContentHeight,
            NativeHomeTopChromeLayout.refreshRevealHeight
                + NativeHomeTopChromeLayout.searchDrawerHeight
        )
        XCTAssertGreaterThan(
            NativeHomeTopChromeLayout.searchDrawerHeight,
            NativeHomeTopChromeLayout.searchFieldHeight
                + NativeHomeTopChromeLayout.searchBottomInset
        )
        XCTAssertEqual(
            NativeHomeTopChromeLayout.refreshPullDistance(normalizedOffset: -20),
            20
        )
        XCTAssertEqual(
            NativeHomeTopChromeLayout.refreshPullDistance(normalizedOffset: 20),
            0
        )
    }

    func testSearchDrawerSnapsOpenAfterAShallowPullAndClosedBelowThreshold() {
        XCTAssertEqual(
            NativeHomeSearchDrawerSnapPolicy.target(
                normalizedOffset: 37,
                isRefreshing: false
            ),
            .revealed
        )
        XCTAssertEqual(
            NativeHomeSearchDrawerSnapPolicy.target(
                normalizedOffset: 39,
                isRefreshing: false
            ),
            .collapsed
        )
        XCTAssertEqual(
            NativeHomeSearchDrawerSnapPolicy.target(
                normalizedOffset: 0,
                isRefreshing: false
            ),
            .revealed
        )
        XCTAssertEqual(
            NativeHomeSearchDrawerSnapPolicy.target(
                normalizedOffset: 56,
                isRefreshing: false
            ),
            .collapsed
        )
        XCTAssertNil(NativeHomeSearchDrawerSnapPolicy.target(
            normalizedOffset: -20,
            isRefreshing: true
        ))
        XCTAssertNil(NativeHomeSearchDrawerSnapPolicy.target(
            normalizedOffset: -20,
            isRefreshing: false
        ))
        XCTAssertNil(NativeHomeSearchDrawerSnapPolicy.target(
            normalizedOffset: 112,
            isRefreshing: false
        ))
        XCTAssertNil(NativeHomeSearchDrawerSnapPolicy.target(
            normalizedOffset: .nan,
            isRefreshing: false
        ))

    }

    func testTopBarScrollIntentUsesAsymmetricDirectionThresholds() {
        var tracker = NativeHomeTopBarScrollIntentTracker()
        tracker.updateInteraction(isInteracting: true, offset: 100)

        XCTAssertNil(tracker.updateOffset(110, isActive: true))
        XCTAssertNil(tracker.updateOffset(117.9, isActive: true))
        XCTAssertEqual(tracker.updateOffset(118.5, isActive: true), .hide)

        XCTAssertNil(tracker.updateOffset(115.1, isActive: true))
        XCTAssertEqual(tracker.updateOffset(114, isActive: true), .show)
    }

    func testTopBarScrollIntentResetsDistanceWhenDirectionReverses() {
        var tracker = NativeHomeTopBarScrollIntentTracker()
        tracker.updateInteraction(isInteracting: true, offset: 100)

        XCTAssertNil(tracker.updateOffset(112, isActive: true))
        XCTAssertNil(tracker.updateOffset(110, isActive: true))
        XCTAssertNil(tracker.updateOffset(108.5, isActive: true))
        XCTAssertEqual(tracker.updateOffset(108, isActive: true), .show)
    }

    func testTopBarScrollIntentIgnoresInactiveAndProgrammaticMovement() {
        var tracker = NativeHomeTopBarScrollIntentTracker()
        tracker.updateInteraction(isInteracting: false, offset: 20)

        XCTAssertNil(tracker.updateOffset(200, isActive: true))
        XCTAssertNil(tracker.updateOffset(220, isActive: false))
        XCTAssertNil(tracker.updateOffset(.infinity, isActive: true))
    }

    func testTopBarScrollIntentAlwaysShowsAtTop() {
        var tracker = NativeHomeTopBarScrollIntentTracker()
        tracker.updateInteraction(isInteracting: false, offset: 80)

        XCTAssertEqual(tracker.updateOffset(1, isActive: true), .show)
        XCTAssertEqual(tracker.updateOffset(-20, isActive: true), .show)
    }

    func testTopBarScrollIntentWaitsUntilPullDrawerIsFullyOutOfView() {
        var tracker = NativeHomeTopBarScrollIntentTracker()
        tracker.updateInteraction(isInteracting: true, offset: 0)

        XCTAssertEqual(tracker.updateOffset(0.4, isActive: true), .show)
        XCTAssertNil(tracker.updateOffset(80, isActive: true))
        XCTAssertNil(
            tracker.updateOffset(
                NativeHomeTopChromeLayout.hiddenLeadingContentHeight - 0.1,
                isActive: true
            )
        )
        XCTAssertEqual(
            tracker.updateOffset(
                NativeHomeTopChromeLayout.hiddenLeadingContentHeight + 0.5,
                isActive: true
            ),
            .hide
        )
    }

    func testTopBarScrollIntentAccumulatesSubToleranceMovement() {
        var tracker = NativeHomeTopBarScrollIntentTracker()
        tracker.updateInteraction(isInteracting: true, offset: 100)

        XCTAssertNil(tracker.updateOffset(99.7, isActive: true))
        XCTAssertNil(tracker.updateOffset(99.4, isActive: true))
        XCTAssertNil(tracker.updateOffset(99.1, isActive: true))
        XCTAssertNil(tracker.updateOffset(98.8, isActive: true))
        XCTAssertNil(tracker.updateOffset(98.5, isActive: true))
        XCTAssertNil(tracker.updateOffset(98.2, isActive: true))
        XCTAssertNil(tracker.updateOffset(97.9, isActive: true))
        XCTAssertNil(tracker.updateOffset(97.6, isActive: true))
        XCTAssertNil(tracker.updateOffset(97.3, isActive: true))
        XCTAssertNil(tracker.updateOffset(97, isActive: true))
        XCTAssertNil(tracker.updateOffset(96.7, isActive: true))
        XCTAssertNil(tracker.updateOffset(96.4, isActive: true))
        XCTAssertNil(tracker.updateOffset(96.1, isActive: true))
        XCTAssertEqual(tracker.updateOffset(95.8, isActive: true), .show)
    }

    func testOnlySelectedChannelOwnsScrolling() {
        let selection = HomeChannel.following.id
        let activeChannels = HomeChannel.allCases.filter { channel in
            NativeChannelPresentationPolicy.isActive(
                isEnabled: true,
                channelID: channel.id,
                selection: selection
            )
        }

        XCTAssertEqual(activeChannels, [.following])
        XCTAssertFalse(NativeChannelPresentationPolicy.isActive(
            isEnabled: true,
            channelID: HomeChannel.recommendation.id,
            selection: HomeChannel.following.id
        ))
        XCTAssertFalse(NativeChannelPresentationPolicy.isActive(
            isEnabled: false,
            channelID: selection,
            selection: selection
        ))
    }

    func testChannelPagesShareOneContinuousHorizontalCoordinateSystem() {
        let width: CGFloat = 390
        let drag: CGFloat = -117

        XCTAssertEqual(NativeChannelPageTransitionPolicy.pageOffset(
            pageIndex: 0,
            selectedIndex: 1,
            containerWidth: width,
            dragTranslation: drag
        ), -507)
        XCTAssertEqual(NativeChannelPageTransitionPolicy.pageOffset(
            pageIndex: 1,
            selectedIndex: 1,
            containerWidth: width,
            dragTranslation: drag
        ), -117)
        XCTAssertEqual(NativeChannelPageTransitionPolicy.pageOffset(
            pageIndex: 2,
            selectedIndex: 1,
            containerWidth: width,
            dragTranslation: drag
        ), 273)
    }

    func testChannelInteractiveTranslationClampsPagesAndEdges() {
        XCTAssertEqual(NativeChannelPageTransitionPolicy.interactiveTranslation(
            rawTranslation: -500,
            currentIndex: 1,
            channelCount: 4,
            containerWidth: 390
        ), -390)
        XCTAssertEqual(NativeChannelPageTransitionPolicy.interactiveTranslation(
            rawTranslation: 80,
            currentIndex: 0,
            channelCount: 4,
            containerWidth: 390
        ), 0)
        XCTAssertEqual(NativeChannelPageTransitionPolicy.interactiveTranslation(
            rawTranslation: -80,
            currentIndex: 3,
            channelCount: 4,
            containerWidth: 390
        ), 0)
    }

    func testNonScrollableNestedStripDoesNotExcludeChannelSwipe() {
        XCTAssertFalse(NativeChannelSwipeExclusionPolicy.shouldExcludeParentSwipe(
            nestedContentWidth: 120,
            nestedViewportWidth: 390
        ))
        XCTAssertTrue(NativeChannelSwipeExclusionPolicy.shouldExcludeParentSwipe(
            nestedContentWidth: 520,
            nestedViewportWidth: 390
        ))
        XCTAssertFalse(NativeChannelSwipeExclusionPolicy.shouldExcludeParentSwipe(
            nestedContentWidth: nil,
            nestedViewportWidth: nil
        ))
    }

    func testChannelSwitcherMountsOnlyTheSelectedPageAndItsNeighbors() {
        XCTAssertTrue(NativeChannelPresentationPolicy.shouldMount(
            pageIndex: 0,
            selectedIndex: 1,
            channelCount: 4
        ))
        XCTAssertTrue(NativeChannelPresentationPolicy.shouldMount(
            pageIndex: 2,
            selectedIndex: 1,
            channelCount: 4
        ))
        XCTAssertFalse(NativeChannelPresentationPolicy.shouldMount(
            pageIndex: 3,
            selectedIndex: 1,
            channelCount: 4
        ))
        XCTAssertFalse(NativeChannelPresentationPolicy.shouldMount(
            pageIndex: -1,
            selectedIndex: 1,
            channelCount: 4
        ))
    }

    func testChannelSwipeDirectionLockRejectsVerticalPan() {
        XCTAssertFalse(NativeChannelSwipePolicy.shouldBegin(velocity: CGPoint(x: 20, y: 300)))
        XCTAssertFalse(NativeChannelSwipePolicy.shouldBegin(velocity: CGPoint(x: 100, y: 100)))
        XCTAssertTrue(NativeChannelSwipePolicy.shouldBegin(velocity: CGPoint(x: 300, y: 20)))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "NativeShellPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func channelTarget(
        currentIndex: Int,
        translation: CGSize,
        predicted: CGSize,
        containerWidth: CGFloat = 100
    ) -> Int {
        NativeChannelSwipePolicy.targetIndex(
            currentIndex: currentIndex,
            channelCount: HomeChannel.allCases.count,
            translation: translation,
            predictedEndTranslation: predicted,
            containerWidth: containerWidth
        )
    }

}
