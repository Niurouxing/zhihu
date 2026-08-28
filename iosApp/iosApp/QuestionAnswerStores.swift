import Foundation

@MainActor
final class QuestionStore: ObservableObject {
    @Published private(set) var question: QuestionDTO?
    @Published private(set) var answers: [AnswerPreviewDTO] = []
    @Published private(set) var initialLoad: QAInitialLoadState = .idle
    @Published private(set) var nextPage: QANextPageState = .idle
    @Published private(set) var isEnd = false
    @Published private(set) var isFollowMutationInFlight = false
    @Published private(set) var message: QAUserMessage?
    @Published var sort: QuestionAnswerSort = .default
    @Published var isDetailExpanded = true

    let route: QuestionRouteDTO
    private let repository: QuestionAnswerRepository
    private var nextURL: URL?
    private var generation: UInt64 = 0

    init(route: QuestionRouteDTO, repository: QuestionAnswerRepository) {
        self.route = route
        self.repository = repository
    }

    func loadIfNeeded() async {
        guard initialLoad == .idle else { return }
        await refresh()
    }

    func refresh() async {
        generation &+= 1
        let accepted = generation
        initialLoad = .loading
        nextPage = .idle
        do {
            async let detail = repository.fetchQuestion(route)
            async let page = repository.fetchQuestionAnswers(
                questionID: route.questionID,
                sort: sort,
                after: nil
            )
            let (loadedQuestion, loadedPage) = try await (detail, page)
            guard generation == accepted else { return }
            question = loadedQuestion
            answers = loadedPage.items
            nextURL = loadedPage.nextURL
            isEnd = loadedPage.isEnd
            initialLoad = .loaded
            Task {
                await repository.recordReadHistory(
                    contentToken: String(loadedQuestion.id),
                    contentType: "question"
                )
            }
        } catch {
            guard generation == accepted else { return }
            if error.isNativeRequestCancellation {
                initialLoad = question == nil ? .idle : .loaded
                return
            }
            initialLoad = .failed(error.localizedDescription)
        }
    }

    func selectSort(_ sort: QuestionAnswerSort) async {
        guard self.sort != sort else { return }
        self.sort = sort
        await refresh()
    }

    func loadMore() async {
        guard initialLoad == .loaded, nextPage != .loading, !isEnd else { return }
        let accepted = generation
        nextPage = .loading
        do {
            let page = try await repository.fetchQuestionAnswers(
                questionID: route.questionID,
                sort: sort,
                after: nextURL
            )
            guard generation == accepted else { return }
            let existing = Set(answers.map(\.answerID))
            answers.append(contentsOf: page.items.filter { !existing.contains($0.answerID) })
            nextURL = page.nextURL
            isEnd = page.isEnd
            nextPage = .idle
        } catch {
            guard generation == accepted else { return }
            if error.isNativeRequestCancellation {
                nextPage = .idle
                return
            }
            nextPage = .failed(error.localizedDescription)
        }
    }

    func toggleFollowing() async {
        guard let question, !isFollowMutationInFlight else { return }
        isFollowMutationInFlight = true
        defer { isFollowMutationInFlight = false }
        let target = !question.isFollowing
        do {
            try await repository.setQuestionFollowing(target, questionID: question.id)
            guard self.question?.id == question.id else { return }
            self.question = question.replacingFollow(
                isFollowing: target,
                followerCount: question.followerCount + (target ? 1 : -1)
            )
            message = QAUserMessage(text: target ? "已关注问题" : "已取消关注问题")
        } catch {
            if error.isNativeRequestCancellation { return }
            message = QAUserMessage(text: "关注操作失败：\(error.localizedDescription)")
        }
    }

    func answerRoute(for preview: AnswerPreviewDTO) -> AnswerRouteDTO {
        return AnswerRouteDTO(
            contentID: preview.answerID,
            kind: .answer,
            questionID: preview.questionID,
            provisionalTitle: preview.questionTitle,
            source: AnswerPageSourceDTO(
                questionID: preview.questionID,
                order: sort,
                orderedAnswers: answers,
                selectedAnswerID: preview.answerID,
                nextURL: nextURL
            )
        )
    }

    func dismissMessage() { message = nil }
}

@MainActor
final class AnswerStore: ObservableObject, Identifiable {
    let id: Int64
    let initialRoute: AnswerRouteDTO
    let initialPreview: NativeFeedAnswerPreview?

    @Published private(set) var content: AnswerDTO?
    @Published private(set) var loadState: QAInitialLoadState = .idle
    @Published private(set) var isVoteMutationInFlight = false
    @Published private(set) var collections: [QACollectionDTO] = []
    @Published private(set) var collectionsState: QAInitialLoadState = .idle
    @Published private(set) var activeCollectionID: String?
    @Published private(set) var message: QAUserMessage?

    private let repository: QuestionAnswerRepository
    private let answerPreloader: NativeFeedAnswerPreloader?
    private var revision: UInt64 = 0
    private var didScheduleReadHistory = false

    init(
        route: AnswerRouteDTO,
        repository: QuestionAnswerRepository,
        preloadedContent: AnswerDTO? = nil,
        initialPreview: NativeFeedAnswerPreview? = nil,
        answerPreloader: NativeFeedAnswerPreloader? = nil
    ) {
        initialRoute = route
        id = route.contentID
        self.repository = repository
        self.answerPreloader = answerPreloader
        self.initialPreview = initialPreview
        if let preloadedContent,
           preloadedContent.route.contentID == route.contentID,
           preloadedContent.route.kind == route.kind {
            content = preloadedContent
            loadState = .loaded
        }
    }

    func loadIfNeeded() async {
        if let content, loadState == .loaded {
            scheduleReadHistory(for: content)
            return
        }
        guard loadState == .idle else { return }
        await retry()
    }

    func retry() async {
        revision &+= 1
        let accepted = revision
        loadState = .loading
        do {
            let loaded: AnswerDTO
            if let answerPreloader {
                loaded = try await answerPreloader.answer(for: initialRoute)
            } else {
                loaded = try await repository.fetchAnswer(initialRoute)
            }
            guard revision == accepted else { return }
            content = loaded
            loadState = .loaded
            scheduleReadHistory(for: loaded)
        } catch {
            guard revision == accepted else { return }
            if error.isNativeRequestCancellation {
                loadState = content == nil ? .idle : .loaded
                return
            }
            loadState = .failed(error.localizedDescription)
        }
    }

    private func scheduleReadHistory(for content: AnswerDTO) {
        guard !didScheduleReadHistory else { return }
        didScheduleReadHistory = true
        Task {
            await repository.recordReadHistory(
                contentToken: String(content.route.contentID),
                contentType: content.route.kind.rawValue
            )
        }
    }

    func setVote(_ requested: QAVoteState) async {
        guard let content, !isVoteMutationInFlight else { return }
        isVoteMutationInFlight = true
        defer { isVoteMutationInFlight = false }
        do {
            let result = try await repository.setVote(requested, route: content.route)
            guard self.content?.route.contentID == content.route.contentID else { return }
            self.content = content.replacingVote(result.state, count: result.voteUpCount)
            if let updated = self.content { answerPreloader?.cacheUpdatedAnswer(updated) }
        } catch {
            if error.isNativeRequestCancellation { return }
            message = QAUserMessage(text: "投票失败：\(error.localizedDescription)")
        }
    }

    func loadCollections(force: Bool = false) async {
        guard let content,
              collectionsState != .loading,
              activeCollectionID == nil,
              force || collectionsState != .loaded
        else { return }
        collectionsState = .loading
        do {
            let loaded = try await repository.fetchCollections(route: content.route)
            guard self.content?.route.contentID == content.route.contentID else { return }
            collections = loaded.items
            self.content = content.replacingFavorite(loaded.favoriteState, count: content.favoriteCount)
            if let updated = self.content { answerPreloader?.cacheUpdatedAnswer(updated) }
            collectionsState = .loaded
        } catch {
            if error.isNativeRequestCancellation {
                collectionsState = collections.isEmpty ? .idle : .loaded
                return
            }
            collectionsState = .failed(error.localizedDescription)
        }
    }

    func setCollection(_ collection: QACollectionDTO, selected: Bool) async {
        guard let content,
              activeCollectionID == nil,
              collectionsState != .loading,
              collection.isFavorited != selected
        else { return }
        activeCollectionID = collection.id
        defer { activeCollectionID = nil }
        do {
            try await repository.setCollection(
                selected,
                collectionID: collection.id,
                route: content.route
            )
            guard self.content?.route.contentID == content.route.contentID else { return }
            collections = collections.map {
                $0.id == collection.id
                    ? QACollectionDTO(id: $0.id, title: $0.title, isFavorited: selected)
                    : $0
            }
            let wasAnyFavorite = collections.contains(where: { $0.id != collection.id && $0.isFavorited })
            let isAnyFavorite = wasAnyFavorite || selected
            let delta = selected ? 1 : -1
            self.content = content.replacingFavorite(
                isAnyFavorite ? .favorited : .notFavorited,
                count: content.favoriteCount + delta
            )
            if let updated = self.content { answerPreloader?.cacheUpdatedAnswer(updated) }
            message = QAUserMessage(text: selected ? "收藏成功" : "已取消收藏")
        } catch {
            if error.isNativeRequestCancellation { return }
            message = QAUserMessage(text: "收藏操作失败：\(error.localizedDescription)")
        }
    }

    func dismissMessage() { message = nil }
}

protocol AnswerOpenedHistory: Sendable {
    func openedAnswerIDs(questionID: Int64) async -> Set<Int64>
    func markOpened(answerID: Int64, questionID: Int64) async
}

actor UserDefaultsAnswerOpenedHistory: AnswerOpenedHistory {
    private let defaults: UserDefaults
    private let key = "nativeAnswerOpenedHistory.v1"
    private let maximumPerQuestion = 500

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func openedAnswerIDs(questionID: Int64) -> Set<Int64> {
        Set((storage()[String(questionID)] ?? []).compactMap(Int64.init))
    }

    func markOpened(answerID: Int64, questionID: Int64) {
        var value = storage()
        let questionKey = String(questionID)
        var answers = value[questionKey] ?? []
        answers.removeAll { $0 == String(answerID) }
        answers.append(String(answerID))
        value[questionKey] = Array(answers.suffix(maximumPerQuestion))
        defaults.set(value, forKey: key)
    }

    private func storage() -> [String: [String]] {
        defaults.dictionary(forKey: key)?.reduce(into: [:]) { result, pair in
            if let values = pair.value as? [String] { result[pair.key] = values }
        } ?? [:]
    }
}

@MainActor
final class AnswerStreamStore: ObservableObject {
    enum PaginationState: Equatable {
        case idle
        case loading(showsIndicator: Bool)
        case end
        case failed(String)
    }

    @Published private(set) var answers: [AnswerStore]
    @Published private(set) var currentAnswerID: Int64
    @Published private(set) var paginationState: PaginationState

    private let repository: QuestionAnswerRepository
    private let answerPreloader: NativeFeedAnswerPreloader?
    private let commentPreloader: NativeCommentPreloader?
    private let openedHistory: AnswerOpenedHistory
    private let diagnostics: PerformanceDiagnosticsClient
    private let commentPrefetchDelayNanoseconds: UInt64
    private let initialPaginationDelayNanoseconds: UInt64
    private let paginationTimeoutNanoseconds: UInt64
    private let followingAnswerPrefetchDelayNanoseconds: UInt64
    private let sourceOrder: QuestionAnswerSort
    private let questionID: Int64?
    private var routes: [AnswerRouteDTO]
    private var previews: [Int64: AnswerPreviewDTO]
    private var nextURL: URL?
    private var seenContinuations: Set<URL> = []
    private var scheduledCommentSubjects: Set<CommentSubjectDTO> = []
    private var pendingCommentSubject: CommentSubjectDTO?
    private var commentPrefetchTask: Task<Void, Never>?
    private var pendingFollowingAnswerID: Int64?
    private var followingAnswerPrefetchTask: Task<Void, Never>?
    private var scheduledFollowingAnswerIDs: Set<Int64> = []

    var current: AnswerStore {
        answers.first(where: { $0.id == currentAnswerID }) ?? answers[0]
    }

    init(
        route: AnswerRouteDTO,
        repository: QuestionAnswerRepository,
        answerPreloader: NativeFeedAnswerPreloader? = nil,
        commentPreloader: NativeCommentPreloader? = nil,
        commentPrefetchDelayNanoseconds: UInt64 = 1_500_000_000,
        initialPaginationDelayNanoseconds: UInt64 = 0,
        paginationTimeoutNanoseconds: UInt64 = 15_000_000_000,
        followingAnswerPrefetchDelayNanoseconds: UInt64 = 650_000_000,
        openedHistory: AnswerOpenedHistory = UserDefaultsAnswerOpenedHistory(),
        diagnostics: PerformanceDiagnosticsClient = .disabled
    ) {
        self.repository = repository
        self.answerPreloader = answerPreloader
        self.commentPreloader = commentPreloader
        self.commentPrefetchDelayNanoseconds = commentPrefetchDelayNanoseconds
        self.initialPaginationDelayNanoseconds = initialPaginationDelayNanoseconds
        self.paginationTimeoutNanoseconds = paginationTimeoutNanoseconds
        self.followingAnswerPrefetchDelayNanoseconds = followingAnswerPrefetchDelayNanoseconds
        self.openedHistory = openedHistory
        self.diagnostics = diagnostics

        let normalizedInitialRoute = AnswerRouteDTO(
            contentID: route.contentID,
            kind: route.kind,
            questionID: route.questionID ?? route.source?.questionID,
            provisionalTitle: route.provisionalTitle,
            source: nil
        )
        var orderedRoutes = [normalizedInitialRoute]
        var previewMap: [Int64: AnswerPreviewDTO] = [:]

        if let source = route.source, route.kind == .answer {
            for preview in source.orderedAnswers {
                previewMap[preview.answerID] = preview
                guard preview.answerID != route.contentID else { continue }
                orderedRoutes.append(AnswerRouteDTO(
                    contentID: preview.answerID,
                    kind: .answer,
                    questionID: preview.questionID,
                    provisionalTitle: preview.questionTitle
                ))
            }
            sourceOrder = source.order
            questionID = source.questionID
            nextURL = source.nextURL
            paginationState = source.nextURL == nil ? .end : .idle
        } else {
            sourceOrder = .default
            questionID = route.questionID
            nextURL = nil
            paginationState = route.kind == .article || route.questionID == nil ? .end : .idle
        }

        routes = orderedRoutes
        previews = previewMap
        currentAnswerID = route.contentID
        answers = orderedRoutes.map { candidate in
            AnswerStore(
                route: candidate,
                repository: repository,
                preloadedContent: answerPreloader?.cachedAnswer(for: candidate),
                initialPreview: answerPreloader?.cachedPreview(for: candidate)
                    ?? previewMap[candidate.contentID].map(NativeFeedAnswerPreview.init),
                answerPreloader: answerPreloader
            )
        }
    }

    func prepare() async {
        guard let answer = answers.first(where: { $0.id == currentAnswerID }) else { return }
        await prepareContent(for: answer)
        if initialPaginationDelayNanoseconds > 0 {
            do {
                try await Task.sleep(nanoseconds: initialPaginationDelayNanoseconds)
            } catch {
                return
            }
        }
        // Initial pagination belongs to the cancellable lifetime of the reading
        // screen, not to a non-critical comment prefetch.
        await loadMoreIfNeeded(showsLoadingIndicator: false)
    }

    func prepareAnswer(id: Int64) async {
        guard let index = answers.firstIndex(where: { $0.id == id }) else { return }
        let answer = answers[index]
        await prepareContent(for: answer)
    }

    func reachedEnd(of answerID: Int64) async {
        guard let index = answers.firstIndex(where: { $0.id == answerID }),
              index >= max(answers.count - 2, 0)
        else { return }
        await loadMoreIfNeeded(showsLoadingIndicator: true)
    }

    func focus(answerID: Int64) {
        guard answers.contains(where: { $0.id == answerID }) else { return }
        if currentAnswerID != answerID {
            cancelPendingCommentPrefetch()
            cancelPendingFollowingAnswerPrefetch()
        }
        currentAnswerID = answerID
        if let answer = answers.first(where: { $0.id == answerID }),
           let content = answer.content {
            scheduleCommentPrefetch(for: content)
        }
        scheduleFollowingAnswerPrefetch(after: answerID)
    }

    func cancelPendingCommentPrefetch() {
        // Once the bounded repository request has started, let the shared
        // preloader finish it into cache. Only the dwell timer is disposable.
        guard pendingCommentSubject != nil else { return }
        commentPrefetchTask?.cancel()
        commentPrefetchTask = nil
        pendingCommentSubject = nil
    }

    func cancelPendingReadingPrefetches() {
        cancelPendingCommentPrefetch()
        cancelPendingFollowingAnswerPrefetch()
    }

    func retryPagination() async {
        guard case .failed = paginationState else { return }
        paginationState = .idle
        await loadMoreIfNeeded()
    }

    func loadMoreIfNeeded(showsLoadingIndicator: Bool = true) async {
        if case let .loading(currentlyShowsIndicator) = paginationState {
            if showsLoadingIndicator, !currentlyShowsIndicator {
                paginationState = .loading(showsIndicator: true)
            }
            return
        }
        guard case .idle = paginationState,
              let questionID,
              routes.first?.kind == .answer
        else { return }

        paginationState = .loading(showsIndicator: showsLoadingIndicator)
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            var addedCount = 0
            var requestCount = 0
            repeat {
                try Task.checkCancellation()
                let requestedURL = nextURL
                if let requestedURL, seenContinuations.contains(requestedURL) {
                    throw QuestionAnswerRepositoryError.untrustedContinuation
                }
                let page = try await fetchAnswerPage(
                    questionID: questionID,
                    after: requestedURL
                )
                if let requestedURL { seenContinuations.insert(requestedURL) }
                let known = Set(routes.map(\.contentID))
                let candidates = page.items.filter { !known.contains($0.answerID) }
                previews.merge(
                    Dictionary(uniqueKeysWithValues: page.items.map { ($0.answerID, $0) }),
                    uniquingKeysWith: { _, new in new }
                )
                let newRoutes = candidates.map {
                    AnswerRouteDTO(
                        contentID: $0.answerID,
                        kind: .answer,
                        questionID: $0.questionID,
                        provisionalTitle: $0.questionTitle
                    )
                }
                routes.append(contentsOf: newRoutes)
                answers.append(contentsOf: newRoutes.map(makeStore))
                scheduleFollowingAnswerPrefetch(after: currentAnswerID)
                addedCount += newRoutes.count
                nextURL = page.nextURL
                let reachedEnd = page.isEnd || page.nextURL == nil
                paginationState = reachedEnd ? .end : .idle
                requestCount += 1
                if reachedEnd { break }
            } while addedCount == 0 && requestCount < 3

            if addedCount == 0, case .idle = paginationState {
                paginationState = .failed("暂时没有取得更多回答，请重试")
            }

            diagnostics.record(.init(
                durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
                category: "answer_stream",
                operation: "load_more",
                result: .success,
                itemCount: addedCount,
                pagingSource: paginationState == .end ? "end" : "next"
            ))
        } catch {
            if error.isNativeRequestCancellation {
                paginationState = .idle
                diagnostics.record(.init(
                    durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
                    category: "answer_stream",
                    operation: "load_more",
                    result: .cancelled,
                    errorKind: "cancelled"
                ))
                return
            }
            paginationState = .failed(paginationErrorMessage(for: error))
            diagnostics.record(.init(
                durationMilliseconds: PerformanceDiagnosticEvent.duration(since: startedAt),
                category: "answer_stream",
                operation: "load_more",
                result: .failure,
                errorKind: PerformanceDiagnosticEvent.sanitizedErrorKind(error)
            ))
        }
    }

    private func fetchAnswerPage(
        questionID: Int64,
        after nextURL: URL?
    ) async throws -> QuestionAnswerPageDTO {
        let repository = repository
        let sourceOrder = sourceOrder
        let timeout = paginationTimeoutNanoseconds
        return try await withThrowingTaskGroup(of: QuestionAnswerPageDTO.self) { group in
            group.addTask {
                try await repository.fetchQuestionAnswers(
                    questionID: questionID,
                    sort: sourceOrder,
                    after: nextURL
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeout)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw URLError(.unknown)
            }
            return result
        }
    }

    private func paginationErrorMessage(for error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return "加载更多回答超时，请重试"
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "加载更多回答失败，请重试" : message
    }

    private func makeStore(route: AnswerRouteDTO) -> AnswerStore {
        AnswerStore(
            route: route,
            repository: repository,
            preloadedContent: answerPreloader?.cachedAnswer(for: route),
            initialPreview: answerPreloader?.cachedPreview(for: route)
                ?? previews[route.contentID].map(NativeFeedAnswerPreview.init),
            answerPreloader: answerPreloader
        )
    }

    private func prepareContent(for answer: AnswerStore) async {
        await answer.loadIfNeeded()
        if let questionID = answer.content?.questionID ?? answer.initialRoute.questionID {
            await openedHistory.markOpened(answerID: answer.id, questionID: questionID)
        }
        if let content = answer.content, currentAnswerID == answer.id {
            scheduleCommentPrefetch(for: content)
            scheduleFollowingAnswerPrefetch(after: answer.id)
        }
    }

    private func scheduleFollowingAnswerPrefetch(after answerID: Int64) {
        guard let answerPreloader,
              let index = answers.firstIndex(where: { $0.id == answerID }),
              answers.indices.contains(index + 1)
        else { return }
        let following = answers[index + 1]
        guard following.content == nil,
              !scheduledFollowingAnswerIDs.contains(following.id),
              pendingFollowingAnswerID != following.id
        else { return }

        cancelPendingFollowingAnswerPrefetch()
        pendingFollowingAnswerID = following.id
        let delay = followingAnswerPrefetchDelayNanoseconds
        followingAnswerPrefetchTask = Task { [weak self, weak answerPreloader] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard let self,
                  !Task.isCancelled,
                  self.currentAnswerID == answerID,
                  self.pendingFollowingAnswerID == following.id
            else { return }
            self.pendingFollowingAnswerID = nil
            self.scheduledFollowingAnswerIDs.insert(following.id)
            await answerPreloader?.prefetchForReading(following.initialRoute)
            if self.pendingFollowingAnswerID == nil {
                self.followingAnswerPrefetchTask = nil
            }
        }
    }

    private func cancelPendingFollowingAnswerPrefetch() {
        guard pendingFollowingAnswerID != nil else { return }
        followingAnswerPrefetchTask?.cancel()
        followingAnswerPrefetchTask = nil
        pendingFollowingAnswerID = nil
    }

    private func scheduleCommentPrefetch(for content: AnswerDTO) {
        guard let commentPreloader else { return }
        let route = commentRoute(for: content)
        guard !scheduledCommentSubjects.contains(route.subject),
              pendingCommentSubject != route.subject
        else { return }

        if pendingCommentSubject != nil {
            commentPrefetchTask?.cancel()
        }
        pendingCommentSubject = route.subject
        let answerID = content.route.contentID
        let delay = commentPrefetchDelayNanoseconds

        // Require a short reading dwell before spending radio time on comments.
        // Rapidly opening and closing cards therefore fetches only their visible
        // answer, while a reader who stays gets the comments prepared in advance.
        commentPrefetchTask = Task { [weak self, weak commentPreloader] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard let self,
                  !Task.isCancelled,
                  self.currentAnswerID == answerID,
                  self.pendingCommentSubject == route.subject
            else { return }
            self.pendingCommentSubject = nil
            self.scheduledCommentSubjects.insert(route.subject)
            await commentPreloader?.prefetch(route)
            if self.pendingCommentSubject == nil {
                self.commentPrefetchTask = nil
            }
        }
    }

    private func commentRoute(for content: AnswerDTO) -> CommentThreadRouteDTO {
        let subject: CommentSubjectDTO = content.route.kind == .answer
            ? .answer(content.route.contentID)
            : .article(content.route.contentID)
        return CommentThreadRouteDTO(
            subject: subject,
            shareContext: CommentShareContextDTO(
                title: content.title,
                excerpt: nil,
                sourceURL: content.sourceURL
            )
        )
    }
}
