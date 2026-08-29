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
        XCTAssertEqual(HomeChannel.allCases, [.following, .recommendation, .hot, .daily])
        XCTAssertEqual(HomeChannel.allCases.map(\.id), [
            "following",
            "recommendation",
            "hot",
            "daily",
        ])
        XCTAssertEqual(HomeChannel.allCases.map(\.id), HomeChannel.allCases.map(\.rawValue))
        XCTAssertEqual(HomeChannel.allCases.map(\.title), ["关注", "推荐", "热榜", "日报"])
        XCTAssertEqual(HomeChannel.allCases.map(\.systemImage), [
            "person.2.fill",
            "sparkles",
            "flame.fill",
            "newspaper.fill",
        ])
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

    func testHomeFloatingSurfaceHasOnlyCreationAndNotificationControls() {
        XCTAssertEqual(HomeFloatingControl.visibleControls, [.creation, .notifications])
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

    func testHomePullRegionsKeepSearchAndRefreshFeedbackCompact() {
        XCTAssertEqual(
            NativeHomePullRegionLayout.revealedOffset,
            0
        )
        XCTAssertEqual(
            NativeHomePullRegionLayout.collapsedOffset,
            NativeHomeFloatingControlsLayout.contentClearance
        )
        XCTAssertEqual(
            NativeHomePullRegionLayout.leadingContentHeight,
            NativeHomeFloatingControlsLayout.contentClearance
                + NativeHomePullRegionLayout.searchDrawerHeight
        )
        XCTAssertEqual(
            NativeHomeFloatingControlsLayout.contentClearance,
            NativeHomeFloatingControlsLayout.height
        )
        XCTAssertGreaterThan(
            NativeHomePullRegionLayout.searchDrawerHeight,
            NativeHomePullRegionLayout.searchFieldHeight
                + NativeHomePullRegionLayout.searchBottomInset
        )
    }

    func testHomeRefreshTriggerNeedsOnlyAShortPullBeyondRevealedSearch() {
        let collapsedOffset = NativeHomePullRegionLayout.collapsedOffset
        let threshold = collapsedOffset
            + NativeHomeRefreshTriggerPolicy.pullDistanceBeyondSearch

        XCTAssertFalse(NativeHomeRefreshTriggerPolicy.shouldRequestRefresh(
            interactionStartOffset: collapsedOffset,
            maximumDownwardTranslation: threshold - 0.1,
            hasSearchDrawer: true,
            isActive: true,
            isRefreshInFlight: false
        ))
        XCTAssertTrue(NativeHomeRefreshTriggerPolicy.shouldRequestRefresh(
            interactionStartOffset: collapsedOffset,
            maximumDownwardTranslation: threshold,
            hasSearchDrawer: true,
            isActive: true,
            isRefreshInFlight: false
        ))
        XCTAssertFalse(NativeHomeRefreshTriggerPolicy.shouldRequestRefresh(
            interactionStartOffset: collapsedOffset,
            maximumDownwardTranslation: threshold + 20,
            hasSearchDrawer: true,
            isActive: true,
            isRefreshInFlight: true
        ))
    }

    func testCollapsedSearchDrawerRevealsOnlyAfterItsPullThreshold() {
        let collapsedOffset = NativeHomePullRegionLayout.collapsedOffset
        XCTAssertEqual(
            NativeHomeSearchDrawerSnapPolicy.target(
                normalizedOffset: collapsedOffset
                    - NativeHomeSearchDrawerSnapPolicy.revealDistance,
                currentAnchor: .collapsed,
                isRefreshing: false
            ),
            .revealed
        )
        XCTAssertEqual(
            NativeHomeSearchDrawerSnapPolicy.target(
                normalizedOffset: collapsedOffset
                    - NativeHomeSearchDrawerSnapPolicy.revealDistance
                    + 1,
                currentAnchor: .collapsed,
                isRefreshing: false
            ),
            .collapsed
        )
    }

    func testRevealedSearchDrawerClosesAfterASlightUpwardMovement() {
        let collapseDistance = NativeHomeSearchDrawerSnapPolicy.collapseDistance
        XCTAssertEqual(
            NativeHomeSearchDrawerSnapPolicy.target(
                normalizedOffset: collapseDistance - 0.1,
                currentAnchor: .revealed,
                isRefreshing: false
            ),
            .revealed
        )
        XCTAssertEqual(
            NativeHomeSearchDrawerSnapPolicy.target(
                normalizedOffset: collapseDistance,
                currentAnchor: .revealed,
                isRefreshing: false
            ),
            .collapsed
        )
    }

    func testSearchDrawerSnapPolicyHonorsSettledBoundsAndRefreshState() {
        XCTAssertEqual(
            NativeHomeSearchDrawerSnapPolicy.target(
                normalizedOffset: NativeHomePullRegionLayout.revealedOffset,
                currentAnchor: .collapsed,
                isRefreshing: false
            ),
            .revealed
        )
        XCTAssertEqual(
            NativeHomeSearchDrawerSnapPolicy.target(
                normalizedOffset: NativeHomePullRegionLayout.collapsedOffset,
                currentAnchor: .revealed,
                isRefreshing: false
            ),
            .collapsed
        )
        XCTAssertNil(NativeHomeSearchDrawerSnapPolicy.target(
            normalizedOffset: -20,
            currentAnchor: .revealed,
            isRefreshing: true
        ))
        XCTAssertNil(NativeHomeSearchDrawerSnapPolicy.target(
            normalizedOffset: -20,
            currentAnchor: .revealed,
            isRefreshing: false
        ))
        XCTAssertNil(NativeHomeSearchDrawerSnapPolicy.target(
            normalizedOffset: NativeHomePullRegionLayout.collapsedOffset + 56,
            currentAnchor: .collapsed,
            isRefreshing: false
        ))
        XCTAssertNil(NativeHomeSearchDrawerSnapPolicy.target(
            normalizedOffset: .nan,
            currentAnchor: .collapsed,
            isRefreshing: false
        ))
    }

    func testSearchDrawerBoundaryStateTracksRefreshAndDeepScrollRegions() {
        XCTAssertEqual(
            NativeHomeSearchDrawerSnapPolicy.boundaryAnchor(normalizedOffset: -20),
            .revealed
        )
        XCTAssertEqual(
            NativeHomeSearchDrawerSnapPolicy.boundaryAnchor(
                normalizedOffset: NativeHomePullRegionLayout.revealedOffset
            ),
            .revealed
        )
        XCTAssertNil(NativeHomeSearchDrawerSnapPolicy.boundaryAnchor(
            normalizedOffset: NativeHomePullRegionLayout.collapsedOffset / 2
        ))
        XCTAssertEqual(
            NativeHomeSearchDrawerSnapPolicy.boundaryAnchor(
                normalizedOffset: NativeHomePullRegionLayout.collapsedOffset + 1
            ),
            .collapsed
        )
        XCTAssertNil(NativeHomeSearchDrawerSnapPolicy.boundaryAnchor(
            normalizedOffset: .nan
        ))
    }

    func testSearchDrawerRestorationNormalizesInterruptedOffsetsToAnAnchor() {
        let maximumOffset: CGFloat = 300

        XCTAssertEqual(
            NativeHomeSearchDrawerRestorationPolicy.resolve(
                restoredNormalizedOffset: nil,
                maximumNormalizedOffset: maximumOffset
            ),
            NativeHomeSearchDrawerRestoredPosition(
                normalizedOffset: NativeHomePullRegionLayout.collapsedOffset,
                anchor: .collapsed
            )
        )
        XCTAssertEqual(
            NativeHomeSearchDrawerRestorationPolicy.resolve(
                restoredNormalizedOffset: 12,
                maximumNormalizedOffset: maximumOffset
            ),
            NativeHomeSearchDrawerRestoredPosition(
                normalizedOffset: NativeHomePullRegionLayout.revealedOffset,
                anchor: .revealed
            )
        )
        XCTAssertEqual(
            NativeHomeSearchDrawerRestorationPolicy.resolve(
                restoredNormalizedOffset: 44,
                maximumNormalizedOffset: maximumOffset
            ),
            NativeHomeSearchDrawerRestoredPosition(
                normalizedOffset: NativeHomePullRegionLayout.collapsedOffset,
                anchor: .collapsed
            )
        )
        XCTAssertEqual(
            NativeHomeSearchDrawerRestorationPolicy.resolve(
                restoredNormalizedOffset: 220,
                maximumNormalizedOffset: maximumOffset
            ),
            NativeHomeSearchDrawerRestoredPosition(
                normalizedOffset: 220,
                anchor: .collapsed
            )
        )
    }

    func testFloatingControlsScrollIntentUsesAsymmetricDirectionThresholds() {
        var tracker = NativeHomeFloatingControlsScrollIntentTracker()
        tracker.updateInteraction(isInteracting: true, offset: 200)

        XCTAssertNil(tracker.updateOffset(210, isActive: true))
        XCTAssertNil(tracker.updateOffset(217.9, isActive: true))
        XCTAssertEqual(tracker.updateOffset(218.5, isActive: true), .hide)

        XCTAssertNil(tracker.updateOffset(211.1, isActive: true))
        XCTAssertEqual(tracker.updateOffset(210.4, isActive: true), .show)
    }

    func testFloatingControlsScrollIntentResetsDistanceWhenDirectionReverses() {
        var tracker = NativeHomeFloatingControlsScrollIntentTracker()
        tracker.updateInteraction(isInteracting: true, offset: 200)

        XCTAssertNil(tracker.updateOffset(212, isActive: true))
        XCTAssertNil(tracker.updateOffset(210, isActive: true))
        XCTAssertNil(tracker.updateOffset(204.6, isActive: true))
        XCTAssertEqual(tracker.updateOffset(203.9, isActive: true), .show)
    }

    func testFloatingControlsScrollIntentIgnoresInactiveAndProgrammaticMovement() {
        var tracker = NativeHomeFloatingControlsScrollIntentTracker()
        tracker.updateInteraction(isInteracting: false, offset: 20)

        XCTAssertNil(tracker.updateOffset(200, isActive: true))
        XCTAssertNil(tracker.updateOffset(220, isActive: false))
        XCTAssertNil(tracker.updateOffset(.infinity, isActive: true))
    }

    func testFloatingControlsScrollIntentAlwaysShowsThroughPullRegions() {
        var tracker = NativeHomeFloatingControlsScrollIntentTracker()
        tracker.updateInteraction(isInteracting: false, offset: 200)

        XCTAssertEqual(
            tracker.updateOffset(NativeHomePullRegionLayout.collapsedOffset, isActive: true),
            .show
        )
        XCTAssertEqual(tracker.updateOffset(1, isActive: true), .show)
        XCTAssertEqual(tracker.updateOffset(-20, isActive: true), .show)
    }

    func testFloatingControlsWaitUntilFeedMovesBeyondItsTopPosition() {
        var tracker = NativeHomeFloatingControlsScrollIntentTracker()
        let collapsedOffset = NativeHomePullRegionLayout.collapsedOffset
        tracker.updateInteraction(isInteracting: true, offset: collapsedOffset)

        XCTAssertEqual(
            tracker.updateOffset(collapsedOffset + 0.4, isActive: true),
            .show
        )
        XCTAssertNil(tracker.updateOffset(collapsedOffset + 17.9, isActive: true))
        XCTAssertEqual(
            tracker.updateOffset(collapsedOffset + 18.5, isActive: true),
            .hide
        )
    }

    func testFloatingControlsScrollIntentAccumulatesSubToleranceMovement() {
        var tracker = NativeHomeFloatingControlsScrollIntentTracker()
        tracker.updateInteraction(isInteracting: true, offset: 200)

        for step in 1...27 {
            XCTAssertNil(
                tracker.updateOffset(
                    200 - CGFloat(step) * 0.3,
                    isActive: true
                )
            )
        }
        XCTAssertEqual(tracker.updateOffset(191.6, isActive: true), .show)
    }

    func testFloatingControlsSettleShortFlicksAndAlwaysRecoverAtTop() {
        var tracker = NativeHomeFloatingControlsScrollIntentTracker()
        tracker.updateInteraction(isInteracting: true, offset: 200)
        XCTAssertNil(tracker.updateOffset(204, isActive: true))
        XCTAssertEqual(
            tracker.endInteraction(offset: 204, verticalPanVelocity: -240),
            .hide
        )

        tracker.updateInteraction(isInteracting: true, offset: 204)
        XCTAssertEqual(
            tracker.endInteraction(offset: 202, verticalPanVelocity: 220),
            .show
        )

        tracker.updateInteraction(isInteracting: true, offset: 80)
        XCTAssertEqual(
            tracker.endInteraction(
                offset: NativeHomePullRegionLayout.collapsedOffset,
                verticalPanVelocity: 0
            ),
            .show
        )
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
