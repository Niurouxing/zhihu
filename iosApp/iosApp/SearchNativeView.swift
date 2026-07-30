import SwiftUI

struct SearchNativeView: View {
    @StateObject private var store: SearchStore
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @FocusState private var isSearchFieldFocused: Bool
    @State private var lastConsumedFocusRequestToken: UInt = 0
    @Environment(\.nativeSearchPresentation) private var searchPresentation
    private let focusRequest: NativeSearchFocusRequest
    private let onOpen: (FeedItemRoute) -> Void

    init(
        route: SearchRouteDTO,
        repository: SearchRepository,
        historyPersistence: SearchHistoryPersistence = UserDefaultsSearchHistoryPersistence(),
        defaults: UserDefaults = .standard,
        focusRequest: NativeSearchFocusRequest = .inactive,
        onOpen: @escaping (FeedItemRoute) -> Void
    ) {
        _store = StateObject(
            wrappedValue: SearchStore(
                route: route,
                repository: repository,
                historyPersistence: historyPersistence,
                defaults: defaults
            )
        )
        self.focusRequest = focusRequest
        self.onOpen = onOpen
    }

    var body: some View {
        ZStack {
            List {
                if store.submittedQuery.isEmpty {
                    suggestionContent
                } else {
                    resultContent
                }
            }
            .listStyle(.plain)
            .refreshable {
                if store.submittedQuery.isEmpty {
                    await store.refreshSuggestions()
                } else {
                    await store.refreshResults()
                }
            }

            if visibleItems.isEmpty, store.isLoadingResults {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("正在搜索")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("正在搜索")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: store.queryText) { value in
            if value.isEmpty, !store.submittedQuery.isEmpty {
                store.clearQuery()
                if store.showsHotSearch {
                    Task { await store.refreshSuggestions() }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                searchField
            }
            ToolbarItem(placement: .primaryAction) {
                filterMenu
            }
        }
        .task { await store.loadInitialIfNeeded() }
        .task(id: focusRequest) { await consumeFocusRequest(focusRequest) }
        .task(id: searchPresentation) {
            await store.updateSuggestionVisibility(searchPresentation)
        }
        .background(SearchInteractivePopKeyboardBridge())
        .accessibilityIdentifier("search_screen")
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(searchPrompt, text: $store.queryText)
                .focused($isSearchFieldFocused)
                .accessibilityIdentifier("search_input")
                .submitLabel(.search)
                .onSubmit {
                    submitKeyboardQuery()
                }
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            if !store.queryText.isEmpty {
                Button {
                    store.queryText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索内容")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 240)
        .frame(minHeight: 34)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search_field")
    }

    private func submitKeyboardQuery() {
        let query = store.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearchFieldFocused = false
        Task { await store.submitQuery(query) }
    }

    @MainActor
    private func consumeFocusRequest(_ request: NativeSearchFocusRequest) async {
        guard NativeSearchFocusRequestPolicy.shouldConsume(
            request,
            lastConsumedToken: lastConsumedFocusRequestToken
        ) else { return }
        await Task.yield()
        guard !Task.isCancelled,
              focusRequest == request,
              NativeSearchFocusRequestPolicy.shouldConsume(
                  request,
                  lastConsumedToken: lastConsumedFocusRequestToken
              )
        else { return }
        lastConsumedFocusRequestToken = request.token
        isSearchFieldFocused = true
    }

    private var searchPrompt: String {
        store.route.isMemberRestricted
            ? "搜索 \(store.memberDisplayName) 的创作"
            : "搜索内容"
    }

    @ViewBuilder
    private var suggestionContent: some View {
        if store.showsHistory, !store.history.isEmpty {
            Section {
                ForEach(historyRows) { row in
                    Button {
                        Task { await store.submitQuery(row.query) }
                    } label: {
                        Label(row.query, systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text("搜索历史")
                    Spacer()
                    Button("清空") { store.clearHistory() }
                        .textCase(nil)
                }
            }
        }

        if store.showsHotSearch {
            Section {
                ForEach(Array(store.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    Button {
                        Task { await store.submitQuery(suggestion.query) }
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(index < 3 ? Color.accentColor : Color.secondary)
                                .frame(minWidth: 24, alignment: .trailing)
                            Text(suggestion.query)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let popularity = suggestion.popularityText {
                                Text(popularity)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if store.isRefreshingSuggestions {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let error = store.suggestionErrorMessage {
                    FeedRetryRow(message: error) {
                        Task { await store.refreshSuggestions() }
                    }
                }
            } header: {
                HStack {
                    Text("热搜")
                    Spacer()
                    Button {
                        Task { await store.refreshSuggestions() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(store.isRefreshingSuggestions)
                    .textCase(nil)
                    .accessibilityLabel("刷新热搜")
                }
            }
        }

        if !store.showsHistory, !store.showsHotSearch {
            Text(store.route.isMemberRestricted
                 ? "输入关键词搜索 \(store.memberDisplayName) 的创作"
                 : "请输入搜索内容")
                .foregroundStyle(.secondary)
        } else if store.showsHistory, store.history.isEmpty,
                  (!store.showsHotSearch || (!store.isRefreshingSuggestions && store.suggestions.isEmpty && store.suggestionErrorMessage == nil)) {
            Text("暂无搜索历史，输入关键词搜索后会保存在这里")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        if store.route.isMemberRestricted {
            Text("以下结果来自 \(store.memberDisplayName) 的创作")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        ForEach(visibleItems) { item in
            FeedItemRow(item: item, showsThumbnail: true, onOpen: onOpen)
        }

        if let error = store.resultErrorMessage {
            FeedRetryRow(message: error) {
                Task { await store.retryResults() }
            }
        } else if store.canLoadNextPage {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .listRowSeparator(.hidden)
            .task { await store.loadNextPage() }
        } else if visibleItems.isEmpty, !store.isLoadingResults {
            Text("没有找到相关内容")
                .foregroundStyle(.secondary)
        }
    }

    private var visibleItems: [FeedItemDTO] {
        FeedQuestionAuthorVisibilityPolicy.visibleItems(
            from: store.items,
            blockedMemberIDs: questionAuthorBlocklist.blockedMemberIDs
        )
    }

    private var filterMenu: some View {
        Menu {
            Picker("排序", selection: sortBinding) {
                ForEach(SearchSort.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            Picker("内容类型", selection: contentTypeBinding) {
                ForEach(SearchContentType.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            Picker("时间范围", selection: timeRangeBinding) {
                ForEach(SearchTimeRange.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
        } label: {
            Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
        }
        .disabled(store.submittedQuery.isEmpty)
    }

    private var historyRows: [SearchHistoryRow] {
        var occurrences: [String: Int] = [:]
        return store.history.map { query in
            let occurrence = occurrences[query, default: 0]
            occurrences[query] = occurrence + 1
            return SearchHistoryRow(query: query, occurrence: occurrence)
        }
    }

    private var sortBinding: Binding<SearchSort> {
        Binding(
            get: { store.sort },
            set: { value in Task { await store.updateSort(value) } }
        )
    }

    private var contentTypeBinding: Binding<SearchContentType> {
        Binding(
            get: { store.contentType },
            set: { value in Task { await store.updateContentType(value) } }
        )
    }

    private var timeRangeBinding: Binding<SearchTimeRange> {
        Binding(
            get: { store.timeRange },
            set: { value in Task { await store.updateTimeRange(value) } }
        )
    }
}

private struct SearchInteractivePopKeyboardBridge: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        SearchInteractivePopObserverController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

private final class SearchInteractivePopObserverController: UIViewController {
    private weak var observedGesture: UIGestureRecognizer?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard observedGesture == nil,
              let gesture = navigationController?.interactivePopGestureRecognizer
        else { return }
        gesture.addTarget(self, action: #selector(interactivePopChanged(_:)))
        observedGesture = gesture
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        observedGesture?.removeTarget(self, action: #selector(interactivePopChanged(_:)))
        observedGesture = nil
    }

    @objc private func interactivePopChanged(_ gesture: UIGestureRecognizer) {
        guard gesture.state == .began else { return }
        view.window?.endEditing(true)
    }
}

private struct SearchHistoryRow: Identifiable {
    struct ID: Hashable {
        let query: String
        let occurrence: Int
    }

    let query: String
    let occurrence: Int

    var id: ID { ID(query: query, occurrence: occurrence) }
}
