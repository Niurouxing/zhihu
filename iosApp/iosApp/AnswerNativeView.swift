import SwiftUI
import UIKit

struct NativeAnswerStream: View {
    @ObservedObject var store: AnswerStreamStore
    let pinAnswerDate: Bool
    let onNavigate: (QANavigationIntent) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let first = store.answers.first,
                   first.initialRoute.kind == .answer {
                    AnswerQuestionHeader(store: first, onNavigate: onNavigate)
                }

                ForEach(store.answers) { answer in
                    AnswerStreamSection(
                        store: answer,
                        pinAnswerDate: pinAnswerDate,
                        onNavigate: onNavigate,
                        onRetry: {
                            Task { await store.retryAnswer(id: answer.id) }
                        }
                    )
                    .id(answer.id)
                    // Loading belongs to the section's own visibility lifecycle.
                    // Boundary events below only track reading ownership and may
                    // legitimately be missed when pagination inserts a new row.
                    .onScrollVisibilityChange(threshold: 0.01) { isVisible in
                        guard isVisible else { return }
                        Task { await store.prepareAnswer(id: answer.id) }
                    }

                    Color.clear
                        .frame(height: 1)
                        .accessibilityHidden(true)
                        .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                            let update = store.answerBoundaryVisibilityChanged(
                                after: answer.id,
                                isVisible: isVisible
                            )
                            if let answerID = update.answerToPrepare {
                                Task { await store.prepareAnswer(id: answerID) }
                            }
                            if isVisible {
                                Task { await store.reachedEnd(of: answer.id) }
                            }
                        }

                    if answer.id != store.answers.last?.id {
                        Rectangle()
                            .fill(Color(uiColor: .separator).opacity(0.35))
                            .frame(height: 8)
                            .overlay(alignment: .top) { Divider() }
                            .overlay(alignment: .bottom) { Divider() }
                            .accessibilityHidden(true)
                    }
                }

                paginationFooter
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await store.prepare() }
        .onAppear { store.setViewportTrackingActive(true) }
        .onDisappear {
            store.setViewportTrackingActive(false)
            store.cancelPendingReadingPrefetches()
        }
        .accessibilityIdentifier("answer_stream")
    }

    @ViewBuilder
    private var paginationFooter: some View {
        switch store.paginationState {
        case .idle:
            Color.clear
                .frame(height: 1)
        case let .loading(showsIndicator):
            if showsIndicator {
                AnswerPaginationLoadingFooter()
            } else {
                Color.clear.frame(height: 1)
            }
        case .end:
            Text("没有更多回答了")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 64)
        case let .failed(message):
            QAErrorState(message: message, actionTitle: "重试") {
                Task { await store.retryPagination() }
            }
            .frame(maxWidth: .infinity, minHeight: 96)
        }
    }
}

private struct AnswerPaginationLoadingFooter: View {
    @State private var isVisible = false

    var body: some View {
        Group {
            if isVisible {
                ProgressView("正在加载更多回答")
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .foregroundStyle(.secondary)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .task {
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                isVisible = true
            } catch {
                return
            }
        }
    }
}

private struct AnswerQuestionHeader: View {
    @ObservedObject var store: AnswerStore
    let onNavigate: (QANavigationIntent) -> Void

    var body: some View {
        Button {
            guard let questionID = store.content?.questionID ?? store.initialRoute.questionID else {
                return
            }
            onNavigate(.question(QuestionRouteDTO(
                questionID: questionID,
                provisionalTitle: title
            )))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled((store.content?.questionID ?? store.initialRoute.questionID) == nil)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityAddTraits(.isHeader)
    }

    private var title: String {
        store.content?.title
            ?? store.initialPreview?.title
            ?? store.initialRoute.provisionalTitle
    }
}

struct AnswerStreamSection: View {
    @ObservedObject var store: AnswerStore
    let pinAnswerDate: Bool
    let onNavigate: (QANavigationIntent) -> Void
    let onRetry: () -> Void

    @State private var showsCollections = false

    var body: some View {
        Group {
            if let content = store.content {
                loaded(content)
            } else {
                switch store.loadState {
                case let .failed(message):
                    QAErrorState(message: message, actionTitle: "重试", action: onRetry)
                case .idle, .loading, .loaded:
                    if let preview = store.initialPreview {
                        loadingPreview(preview)
                    } else {
                        AnswerBodyLoadingPlaceholder()
                            .padding(.horizontal, 18)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity, minHeight: 220, alignment: .top)
                    }
                }
            }
        }
        .sheet(isPresented: $showsCollections) {
            QACollectionsSheet(store: store)
        }
        .alert(item: messageBinding) { message in
            Alert(
                title: Text("操作结果"),
                message: Text(message.text),
                dismissButton: .default(Text("知道了")) { store.dismissMessage() }
            )
        }
    }

    private func loadingPreview(_ preview: NativeFeedAnswerPreview) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if store.initialRoute.kind == .article {
                Text(preview.title)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

                if let author = preview.author {
                    HStack(spacing: 11) {
                        AsyncImage(url: author.avatarURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .foregroundStyle(.tertiary)
                        }
                        .frame(width: 42, height: 42)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(author.displayName).font(.headline)
                            if !author.headline.isEmpty {
                                Text(author.headline)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                if let summary = preview.summary {
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                AnswerBodyLoadingPlaceholder()
                    .padding(.top, 4)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func loaded(_ content: AnswerDTO) -> some View {
        let metadata = QAMetadataPlacement(pinAnswerDate: pinAnswerDate)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                if content.route.kind == .article {
                    Text(content.title)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                QAAuthorRow(author: content.author) {
                    if let intent = content.author.personIntent { onNavigate(intent) }
                }

                if !content.endorsements.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(content.endorsements) { endorsement in
                                if let url = endorsement.actionURL {
                                    Button {
                                        onNavigate(.endorsement(url))
                                    } label: {
                                        QAEndorsementLabel(endorsement: endorsement, isActionable: true)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    QAEndorsementLabel(endorsement: endorsement, isActionable: false)
                                }
                            }
                        }
                    }
                }

                if metadata.dateEdge == .leading {
                    QADateMetadata(content: content)
                }

                if let invitation = content.invitationPreface, !invitation.isEmpty {
                    Label(invitation, systemImage: "person.crop.circle.badge.questionmark")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                QABodyView(
                    blocks: content.blocks,
                    segmentSubject: content.route.kind == .answer
                        ? .answer(content.route.contentID)
                        : .article(content.route.contentID),
                    onNavigate: onNavigate
                )

                if let attachment = content.attachment {
                    QABodyView(
                        blocks: [.video(UUID(), attachment)],
                        segmentSubject: content.route.kind == .answer
                            ? .answer(content.route.contentID)
                            : .article(content.route.contentID),
                        onNavigate: onNavigate
                    )
                }

                VStack(alignment: .trailing, spacing: 5) {
                    if metadata.dateEdge == .trailing { QADateMetadata(content: content) }
                    if let ip = content.ipLocation, !ip.isEmpty {
                        Text("IP属地：\(ip)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 8)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            AnswerActionBar(
                content: content,
                voteInFlight: store.isVoteMutationInFlight,
                onVoteUp: {
                    let target: QAVoteState = content.voteState == .up ? .neutral : .up
                    Task { await store.setVote(target) }
                },
                onVoteDown: {
                    let target: QAVoteState = content.voteState == .down ? .neutral : .down
                    Task { await store.setVote(target) }
                },
                onFavorite: {
                    showsCollections = true
                    Task { await store.loadCollections() }
                },
                onComments: {
                    let subject: CommentSubjectDTO = content.route.kind == .answer
                        ? .answer(content.route.contentID)
                        : .article(content.route.contentID)
                    onNavigate(.comments(CommentThreadRouteDTO(
                        subject: subject,
                        shareContext: CommentShareContextDTO(
                            title: content.title,
                            excerpt: commentShareExcerpt(from: content.blocks),
                            sourceURL: content.sourceURL
                        )
                    )))
                }
            )
        }
    }

    private func commentShareExcerpt(from blocks: [QABodyBlock]) -> String? {
        let text = blocks
            .compactMap(commentShareText)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let limit = text.index(text.startIndex, offsetBy: min(160, text.count))
        return String(text[..<limit])
    }

    private func commentShareText(_ block: QABodyBlock) -> String? {
        switch block {
        case let .paragraph(_, runs),
             let .heading(_, _, runs),
             let .quote(_, runs),
             let .segment(_, _, runs):
            return runs.map(\.text).joined()
        case let .list(_, _, items):
            return items.flatMap { item in
                [item.runs.map(\.text).joined()] + item.nestedLists.flatMap(commentShareListText)
            }.joined(separator: " ")
        case let .code(_, _, text), let .formula(_, text):
            return text
        case .image, .video, .divider:
            return nil
        }
    }

    private func commentShareListText(_ list: QAListGroup) -> [String] {
        list.items.flatMap { item in
            [item.runs.map(\.text).joined()] + item.nestedLists.flatMap(commentShareListText)
        }
    }

    private var messageBinding: Binding<QAUserMessage?> {
        Binding(get: { store.message }, set: { _ in store.dismissMessage() })
    }
}

/// A geometry-stable, non-animated continuation of the feed preview. It keeps
/// the transition quiet and avoids spending CPU/GPU time on an indefinite
/// spinner while the foreground request completes.
private struct AnswerBodyLoadingPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            placeholderLine
            placeholderLine
            placeholderLine.frame(maxWidth: 210)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在载入完整内容")
    }

    private var placeholderLine: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.10))
            .frame(maxWidth: .infinity)
            .frame(height: 11)
    }
}

private struct QAAuthorRow: View {
    let author: QAAuthorDTO
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                AsyncImage(url: author.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
                }
                .frame(width: 42, height: 42)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(author.displayName).font(.headline)
                    if !author.headline.isEmpty {
                        Text(author.headline).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(author.personIntent == nil)
        .accessibilityHint(author.personIntent == nil ? "" : "打开作者主页")
    }
}

private struct QAEndorsementLabel: View {
    let endorsement: QAEndorsementDTO
    let isActionable: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.seal")
            Text(endorsement.text)
            if isActionable { Image(systemName: "chevron.right").font(.caption2) }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(isActionable ? Color.accentColor : Color(uiColor: .secondaryLabel))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary, in: Capsule())
    }
}

private struct QADateMetadata: View {
    let content: AnswerDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if content.createdTimeSeconds > 0 {
                Text("发布于 \(date(content.createdTimeSeconds))")
            }
            if content.updatedTimeSeconds > 0,
               content.updatedTimeSeconds != content.createdTimeSeconds {
                Text("编辑于 \(date(content.updatedTimeSeconds))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func date(_ seconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(
            .dateTime.year().month().day().hour().minute()
        )
    }
}

private struct AnswerActionBar: View {
    let content: AnswerDTO
    let voteInFlight: Bool
    let onVoteUp: () -> Void
    let onVoteDown: () -> Void
    let onFavorite: () -> Void
    let onComments: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                GlassEffectContainer(spacing: 8) {
                    actions
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
            } else {
                actions
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            action("hand.thumbsup", count: content.voteUpCount, selected: content.voteState == .up, action: onVoteUp)
                .disabled(voteInFlight)
            action("hand.thumbsdown", label: "反对", selected: content.voteState == .down, action: onVoteDown)
                .disabled(voteInFlight || content.route.kind == .article)
            action(
                content.favoriteState == .favorited ? "star.fill" : "star",
                count: content.favoriteCount,
                selected: content.favoriteState == .favorited,
                action: onFavorite
            )
            action("bubble.left", count: content.commentCount, selected: false, action: onComments)
        }
    }

    private func action(
        _ systemName: String,
        count: Int? = nil,
        label: String? = nil,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemName).font(.system(size: 20, weight: selected ? .semibold : .regular))
                Text(label ?? count.map(String.init) ?? "")
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color(uiColor: .label))
    }
}

private struct QACollectionsSheet: View {
    @ObservedObject var store: AnswerStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                if store.collections.isEmpty {
                    switch store.collectionsState {
                    case let .failed(message):
                        QAErrorState(message: message, actionTitle: "重试") {
                            Task { await store.loadCollections(force: true) }
                        }
                    case .idle, .loading, .loaded:
                        ProgressView("正在加载收藏夹")
                    }
                } else {
                    List(store.collections) { collection in
                        Button {
                            Task { await store.setCollection(collection, selected: !collection.isFavorited) }
                        } label: {
                            HStack {
                                Text(collection.title).foregroundStyle(.primary)
                                Spacer()
                                if store.activeCollectionID == collection.id {
                                    ProgressView()
                                } else if collection.isFavorited {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(store.activeCollectionID != nil)
                    }
                    .refreshable { await store.loadCollections(force: true) }
                }
            }
            .navigationTitle("收藏到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .modifier(QACollectionSheetPresentationModifier())
    }
}

private struct QACollectionSheetPresentationModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.presentationDetents([.medium, .large])
        } else {
            content
        }
    }
}
