import SwiftUI

struct SearchNativeView: View {
    @StateObject private var store: SearchStore
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @State private var isSearchFieldFocused = false
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
        .task {
            await store.loadInitialIfNeeded()
        }
        .task(id: focusRequest) { await consumeFocusRequest(focusRequest) }
        .task(id: searchPresentation) {
            await store.updateSuggestionVisibility(searchPresentation)
        }
        .background(
            SearchInteractivePopKeyboardBridge {
                isSearchFieldFocused = false
            }
        )
        .accessibilityIdentifier("search_screen")
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            NativeSearchTextField(
                text: $store.queryText,
                prompt: searchPrompt,
                wantsFocus: $isSearchFieldFocused,
                onSubmit: submitKeyboardQuery
            )
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
        submitSuggestion(query)
    }

    private func submitSuggestion(_ query: String) {
        isSearchFieldFocused = false
        Task { await store.submitQuery(query) }
    }

    @MainActor
    private func consumeFocusRequest(_ request: NativeSearchFocusRequest) async {
        guard NativeSearchFocusRequestPolicy.shouldConsume(
            request,
            lastConsumedToken: lastConsumedFocusRequestToken
        ) else { return }

        guard store.submittedQuery.isEmpty, store.queryText.isEmpty else { return }
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
                        submitSuggestion(row.query)
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
                        submitSuggestion(suggestion.query)
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

private struct NativeSearchTextField: UIViewRepresentable {
    @Binding var text: String
    let prompt: String
    @Binding var wantsFocus: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> FocusAwareSearchTextField {
        let textField = FocusAwareSearchTextField()
        textField.delegate = context.coordinator
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        textField.borderStyle = .none
        textField.backgroundColor = .clear
        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.textColor = .label
        textField.tintColor = .tintColor
        textField.returnKeyType = .search
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.smartQuotesType = .no
        textField.smartDashesType = .no
        textField.clearButtonMode = .never
        textField.accessibilityIdentifier = "search_input"
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateUIView(_ textField: FocusAwareSearchTextField, context: Context) {
        context.coordinator.parent = self
        if textField.text != text {
            textField.text = text
        }
        textField.placeholder = prompt
        textField.wantsFirstResponder = wantsFocus
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NativeSearchTextField

        init(parent: NativeSearchTextField) {
            self.parent = parent
        }

        @objc func textDidChange(_ textField: UITextField) {
            let value = textField.text ?? ""
            if parent.text != value {
                parent.text = value
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.wantsFocus {
                parent.wantsFocus = true
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.wantsFocus {
                parent.wantsFocus = false
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            textField.resignFirstResponder()
            return false
        }
    }
}

private final class FocusAwareSearchTextField: UITextField {
    var wantsFirstResponder = false {
        didSet { applyRequestedFocus() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyRequestedFocus()
    }

    private func applyRequestedFocus() {
        guard window != nil else { return }
        if wantsFirstResponder {
            guard !isFirstResponder else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.wantsFirstResponder else { return }
                self.becomeFirstResponder()
            }
        } else if isFirstResponder {
            resignFirstResponder()
        }
    }
}

private struct SearchInteractivePopKeyboardBridge: UIViewControllerRepresentable {
    let onPopBegan: () -> Void

    func makeUIViewController(context: Context) -> SearchInteractivePopObserverController {
        let controller = SearchInteractivePopObserverController()
        controller.onPopBegan = onPopBegan
        return controller
    }

    func updateUIViewController(
        _ uiViewController: SearchInteractivePopObserverController,
        context: Context
    ) {
        uiViewController.onPopBegan = onPopBegan
    }

    static func dismantleUIViewController(
        _ uiViewController: SearchInteractivePopObserverController,
        coordinator: ()
    ) {
        uiViewController.stopObservingInteractivePop()
    }
}

private final class SearchInteractivePopObserverController: UIViewController {
    private weak var observedGesture: UIGestureRecognizer?
    var onPopBegan: (() -> Void)?

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
        stopObservingInteractivePop()
    }

    func stopObservingInteractivePop() {
        observedGesture?.removeTarget(self, action: #selector(interactivePopChanged(_:)))
        observedGesture = nil
    }

    @objc private func interactivePopChanged(_ gesture: UIGestureRecognizer) {
        guard gesture.state == .began else { return }
        onPopBegan?()
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
