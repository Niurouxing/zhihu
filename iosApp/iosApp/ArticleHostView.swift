import SwiftUI

/// Stable SwiftUI owner for one Answer/Article route. Business state lives in the native pager;
/// comments, media and sharing are delegated upward as typed navigation intents.
struct ArticleHostView: View {
    @StateObject private var pager: AnswerPagerStore
    @AppStorage("pinAnswerDate") private var pinAnswerDate = false
    @AppStorage("answerSwitchMode") private var answerSwitchMode = "horizontal"
    let onNavigate: (QANavigationIntent) -> Void

    init(
        route: AnswerRouteDTO,
        repository: QuestionAnswerRepository,
        openedHistory: AnswerOpenedHistory,
        onNavigate: @escaping (QANavigationIntent) -> Void
    ) {
        _pager = StateObject(
            wrappedValue: AnswerPagerStore(
                route: route,
                repository: repository,
                openedHistory: openedHistory
            )
        )
        self.onNavigate = onNavigate
    }

    var body: some View {
        NativeAnswerPager(
            store: pager,
            preferences: QAReadingPreferences(
                pinAnswerDate: pinAnswerDate,
                answerSwitchEnabled: answerSwitchMode != "off"
            ),
            onNavigate: onNavigate
        )
    }
}

extension QAReadingPreferences {
    init(pinAnswerDate: Bool, answerSwitchEnabled: Bool) {
        self.pinAnswerDate = pinAnswerDate
        self.answerSwitchEnabled = answerSwitchEnabled
    }
}
