import SwiftUI

/// Stable owner for one answer/article reading stream. The clicked answer is first;
/// additional answers are appended vertically by the stream store.
struct ArticleHostView: View {
    @StateObject private var stream: AnswerStreamStore
    @AppStorage("pinAnswerDate") private var pinAnswerDate = false
    let onNavigate: (QANavigationIntent) -> Void

    init(
        route: AnswerRouteDTO,
        repository: QuestionAnswerRepository,
        answerPreloader: NativeFeedAnswerPreloader? = nil,
        commentPreloader: NativeCommentPreloader? = nil,
        openedHistory: AnswerOpenedHistory,
        diagnostics: PerformanceDiagnosticsClient = .disabled,
        onNavigate: @escaping (QANavigationIntent) -> Void
    ) {
        _stream = StateObject(
            wrappedValue: AnswerStreamStore(
                route: route,
                repository: repository,
                answerPreloader: answerPreloader,
                commentPreloader: commentPreloader,
                initialPaginationDelayNanoseconds: 700_000_000,
                openedHistory: openedHistory,
                diagnostics: diagnostics
            )
        )
        self.onNavigate = onNavigate
    }

    var body: some View {
        NativeAnswerStream(
            store: stream,
            pinAnswerDate: pinAnswerDate,
            onNavigate: onNavigate
        )
    }
}
