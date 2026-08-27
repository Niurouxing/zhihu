import SwiftUI

enum NativeFeedCardLayout {
    static let cornerRadius: CGFloat = 16
    static let horizontalInset: CGFloat = 16
    static let verticalInset: CGFloat = 3
    static let contentHorizontalPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 11
    static let textSpacing: CGFloat = 7
    static let mediaSpacing: CGFloat = 6
    static let mediaCarouselHeight: CGFloat = 148
}

extension View {
    /// Apply at the feed container boundary. Ordinary view padding keeps the
    /// layout deterministic in a LazyVStack; zero List row insets preserve the
    /// same geometry where a card is reused by a system List (such as search).
    func nativeFeedCardItemLayout() -> some View {
        padding(.horizontal, NativeFeedCardLayout.horizontalInset)
            .padding(.vertical, NativeFeedCardLayout.verticalInset)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

enum FeedCardLayoutStyle: Equatable, Sendable {
    case standard
    case ranked(Int)
}

struct FeedCardImagePresentation: Equatable, Sendable {
    let url: URL
    let pixelWidth: Int?
    let pixelHeight: Int?
    let isAnimated: Bool
}

enum FeedCardMediaPresentation: Equatable, Sendable {
    case none
    case single(FeedCardImagePresentation)
    case gallery([FeedMediaDTO])

    var isVisible: Bool {
        if case .none = self { return false }
        return true
    }
}

struct FeedCardMetadataPresentation: Equatable, Sendable {
    let author: FeedAuthorDTO?
    let metrics: String

    var isVisible: Bool {
        author != nil || !metrics.isEmpty
    }
}

/// A stable, testable description of one card. API DTO quirks and optional
/// branches are resolved here before SwiftUI participates in layout.
struct FeedCardPresentation: Equatable, Sendable {
    let style: FeedCardLayoutStyle
    let title: String
    let summary: String?
    let media: FeedCardMediaPresentation
    let metadata: FeedCardMetadataPresentation

    init(
        item: FeedItemDTO,
        rank: Int?,
        showsMedia: Bool
    ) {
        style = rank.map(FeedCardLayoutStyle.ranked) ?? .standard
        title = FeedTextPresentationPolicy.compact(item.title) ?? item.title
        summary = FeedTextPresentationPolicy.compact(item.summary)
        media = Self.mediaPresentation(item: item, showsMedia: showsMedia)
        metadata = FeedCardMetadataPresentation(
            author: item.author,
            metrics: FeedItemMetadataFormatter.metricsText(
                kind: item.kind,
                details: item.details
            )
        )
    }

    var accessibilityDescription: String {
        var components: [String] = []
        if case let .ranked(rank) = style {
            components.append("第 \(rank) 名")
        }
        components.append(title)
        if let summary { components.append(summary) }
        if let author = metadata.author { components.append(author.displayName) }
        if !metadata.metrics.isEmpty { components.append(metadata.metrics) }
        return components.joined(separator: "，")
    }

    private static func mediaPresentation(
        item: FeedItemDTO,
        showsMedia: Bool
    ) -> FeedCardMediaPresentation {
        guard showsMedia else { return .none }

        if item.media.count == 1, let media = item.media.first {
            return .single(FeedCardImagePresentation(
                url: media.previewURL,
                pixelWidth: media.pixelWidth,
                pixelHeight: media.pixelHeight,
                isAnimated: media.isAnimated
            ))
        }
        if item.media.count > 1 {
            return .gallery(item.media)
        }
        if let url = item.thumbnailURL {
            return .single(FeedCardImagePresentation(
                url: url,
                pixelWidth: item.thumbnailPixelWidth,
                pixelHeight: item.thumbnailPixelHeight,
                isAnimated: false
            ))
        }
        return .none
    }
}

struct FeedItemRow: View {
    let item: FeedItemDTO
    let showsThumbnail: Bool
    let rank: Int?
    let onOpen: (FeedItemRoute) -> Void
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @Environment(\.nativeContentPresentation) private var contentPresentation
    @Environment(\.nativeHapticFeedback) private var hapticFeedback

    init(
        item: FeedItemDTO,
        showsThumbnail: Bool,
        rank: Int? = nil,
        onOpen: @escaping (FeedItemRoute) -> Void
    ) {
        self.item = item
        self.showsThumbnail = showsThumbnail
        self.rank = rank
        self.onOpen = onOpen
    }

    var body: some View {
        Button {
            onOpen(item.route)
        } label: {
            NativeFeedCard(presentation: cardPresentation)
        }
        .buttonStyle(FeedCardButtonStyle())
        .questionAuthorContextMenu(
            author: item.questionAuthor,
            block: blockQuestionAuthor
        )
        .accessibilityLabel(cardPresentation.accessibilityDescription)
    }

    private var cardPresentation: FeedCardPresentation {
        FeedCardPresentation(
            item: item,
            rank: rank,
            showsMedia: showsThumbnail && contentPresentation.showsFeedThumbnails
        )
    }

    private func blockQuestionAuthor(_ author: FeedAuthorDTO) {
        hapticFeedback(.commit)
        questionAuthorBlocklist.block(author)
    }
}

struct NativeFeedCard: View {
    let presentation: FeedCardPresentation
    @Environment(\.nativeContentPresentation) private var contentPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedCardHeader(presentation: presentation)
            if presentation.media.isVisible {
                FeedCardMediaSection(media: presentation.media)
            }
            if presentation.metadata.isVisible {
                FeedCardMetadataRow(metadata: presentation.metadata)
                    .padding(.top, NativeFeedCardLayout.sectionSpacing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NativeFeedCardLayout.contentHorizontalPadding)
        .padding(.vertical, cardVerticalPadding)
        .background {
            RoundedRectangle(
                cornerRadius: NativeFeedCardLayout.cornerRadius,
                style: .continuous
            )
            .fill(Color(uiColor: .secondarySystemBackground))
        }
        .contentShape(RoundedRectangle(
            cornerRadius: NativeFeedCardLayout.cornerRadius,
            style: .continuous
        ))
    }

    private var cardVerticalPadding: CGFloat {
        max(5, contentPresentation.feedDensity.rowVerticalPadding)
    }
}

private struct FeedCardHeader: View {
    let presentation: FeedCardPresentation

    @ViewBuilder
    var body: some View {
        switch presentation.style {
        case .standard:
            FeedCardTextBlock(
                title: presentation.title,
                summary: presentation.summary
            )
        case let .ranked(rank):
            HStack(alignment: .top, spacing: NativeFeedCardLayout.contentHorizontalPadding) {
                Text("\(rank)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(rank <= 3 ? Color.accentColor : Color.secondary)
                    .frame(minWidth: 22, alignment: .trailing)
                    .accessibilityHidden(true)

                FeedCardTextBlock(
                    title: presentation.title,
                    summary: presentation.summary
                )
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FeedCardTextBlock: View {
    let title: String
    let summary: String?
    @Environment(\.nativeContentPresentation) private var contentPresentation
    @ScaledMetric(relativeTo: .subheadline) private var summaryPointSize: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: NativeFeedCardLayout.textSpacing) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineSpacing(1)
                .lineLimit(2)

            if let summary {
                let renderedPointSize = summaryPointSize * contentPresentation.fontScale
                Text(summary)
                    .font(.system(size: renderedPointSize))
                    .foregroundStyle(.primary)
                    .lineSpacing(contentPresentation.extraLineSpacing(for: renderedPointSize) * 0.45)
                    .lineLimit(contentPresentation.feedExcerptLines)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FeedCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct FeedCardMediaSection: View {
    let media: FeedCardMediaPresentation

    @ViewBuilder
    var body: some View {
        switch media {
        case .none:
            EmptyView()
        case let .single(image):
            FeedCardSingleImagePreview(image: image)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("内容包含 1 张图片")
        case let .gallery(items):
            FeedCardMediaCarousel(media: items)
                .padding(.top, NativeFeedCardLayout.sectionSpacing)
        }
    }
}

private struct FeedCardSingleImagePreview: View {
    let image: FeedCardImagePresentation

    var body: some View {
        AsyncImage(url: image.url) { phase in
            switch phase {
            case let .success(loadedImage):
                preview(loadedImage)
                .padding(.top, NativeFeedCardLayout.sectionSpacing)
            case .empty:
                // Some Zhihu image hosts can leave AsyncImage waiting for a
                // long time instead of returning a timely failure. Reserving
                // the final aspect-ratio box here creates a persistent blank
                // gap between the excerpt and metadata, so loading previews
                // deliberately take no part in card layout.
                EmptyView()
            case .failure:
                EmptyView()
            @unknown default:
                EmptyView()
            }
        }
        .accessibilityHidden(true)
    }

    private var layout: FeedSingleImageLayout {
        FeedSingleImagePresentationPolicy.layout(
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight
        )
    }

    @ViewBuilder
    private func preview(_ loadedImage: Image) -> some View {
        switch layout {
        case .fit:
            decoratedPreview {
                loadedImage
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .crop(containerAspectRatio):
            croppedPreview(
                loadedImage,
                containerAspectRatio: CGFloat(containerAspectRatio)
            )
        }
    }

    private func croppedPreview(
        _ loadedImage: Image,
        containerAspectRatio: CGFloat
    ) -> some View {
        decoratedPreview {
            Color.secondary.opacity(0.06)
                .aspectRatio(containerAspectRatio, contentMode: .fit)
                .overlay {
                    loadedImage
                        .resizable()
                        .scaledToFill()
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .clipped()
                }
        }
    }

    private func decoratedPreview<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .overlay(alignment: .topLeading) {
                if image.isAnimated {
                    Text("GIF")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(7)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct FeedItemMetadataFormatter {
    static func displayText(kind: FeedItemKind, details: String) -> String {
        metricTexts(kind: kind, details: details).joined(separator: " · ")
    }

    static func metricsText(kind: FeedItemKind, details: String) -> String {
        metricTexts(kind: kind, details: details).joined(separator: " · ")
    }

    private static func metricTexts(kind: FeedItemKind, details: String) -> [String] {
        details
            .components(separatedBy: " · ")
            .compactMap(metric)
            .filter { allowedMetricNames(for: kind).contains($0.name) }
            .map { formattedMetric(count: $0.count, name: $0.name) }
    }

    private static func metric(_ rawValue: String) -> (count: Int64, name: String)? {
        let parts = rawValue.split(
            maxSplits: 1,
            whereSeparator: \.isWhitespace
        )
        guard parts.count == 2,
              let count = Int64(parts[0].replacingOccurrences(of: ",", with: ""))
        else { return nil }

        return (max(0, count), String(parts[1]))
    }

    private static func allowedMetricNames(for kind: FeedItemKind) -> Set<String> {
        switch kind {
        case .answer:
            return ["赞同", "评论"]
        case .article, .pin, .video:
            return ["赞", "评论"]
        case .question:
            return ["关注", "回答"]
        }
    }

    private static func formattedMetric(count: Int64, name: String) -> String {
        let number = compactNumber(count)
        let separator = number.hasSuffix("万") || number.hasSuffix("亿") ? "" : " "
        return "\(number)\(separator)\(name)"
    }

    private static func compactNumber(_ count: Int64) -> String {
        switch count {
        case 100_000_000...:
            return compactUnit(count, divisor: 100_000_000, suffix: "亿")
        case 10_000...:
            return compactUnit(count, divisor: 10_000, suffix: "万")
        default:
            return count.formatted(.number.grouping(.automatic))
        }
    }

    private static func compactUnit(
        _ count: Int64,
        divisor: Int64,
        suffix: String
    ) -> String {
        let roundedTenths = ((count * 10) + (divisor / 2)) / divisor
        let whole = roundedTenths / 10
        let fraction = roundedTenths % 10
        return fraction == 0
            ? "\(whole) \(suffix)"
            : "\(whole).\(fraction) \(suffix)"
    }
}

private struct FeedCardMetadataRow: View {
    let metadata: FeedCardMetadataPresentation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
                    if let author = metadata.author {
                        FeedCardAuthorLabel(author: author)
                    }
                    if !metadata.metrics.isEmpty {
                        metricsLabel
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    if let author = metadata.author {
                        FeedCardAuthorLabel(author: author)
                    }

                    if !metadata.metrics.isEmpty {
                        if metadata.author != nil {
                            metadataSeparator
                        }
                        metricsLabel
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var metricsLabel: some View {
        Text(metadata.metrics)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.8)
    }

    private var metadataSeparator: some View {
        Text("·")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

private struct FeedCardAuthorLabel: View {
    let author: FeedAuthorDTO

    var body: some View {
        HStack(spacing: 6) {
            AsyncImage(url: author.avatarURL) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    ZStack {
                        Color.secondary.opacity(0.12)
                        Text(String(author.displayName.prefix(1)))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 24, height: 24)
            .clipShape(Circle())

            Text(author.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
        }
    }
}

private extension View {
    @ViewBuilder
    func questionAuthorContextMenu(
        author: FeedAuthorDTO?,
        block: @escaping (FeedAuthorDTO) -> Void
    ) -> some View {
        if let author {
            contextMenu {
                Button(role: .destructive) {
                    block(author)
                } label: {
                    Label("屏蔽该提问者", systemImage: "person.crop.circle.badge.xmark")
                }
            }
            .accessibilityHint("长按可屏蔽该问题的提问者")
        } else {
            self
        }
    }
}

private struct FeedCardMediaCarousel: View {
    let media: [FeedMediaDTO]
    private let spacing = NativeFeedCardLayout.mediaSpacing

    var body: some View {
        GeometryReader { geometry in
            let itemWidth = CGFloat(FeedMediaCarouselPresentationPolicy.itemWidth(
                availableWidth: Double(geometry.size.width),
                spacing: Double(spacing),
                totalItems: media.count
            ))

            ScrollView(.horizontal) {
                LazyHStack(spacing: spacing) {
                    ForEach(media) { item in
                        FeedCardMediaThumbnail(media: item)
                            .frame(
                                width: itemWidth,
                                height: NativeFeedCardLayout.mediaCarouselHeight
                            )
                    }
                    .scrollTargetLayout()
                }
                .frame(minWidth: geometry.size.width, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
        .frame(height: NativeFeedCardLayout.mediaCarouselHeight)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("内容包含 \(media.count) 张图片")
    }
}

private struct FeedCardMediaThumbnail: View {
    let media: FeedMediaDTO

    var body: some View {
        AsyncImage(url: media.previewURL) { phase in
            switch phase {
            case let .success(image):
                image.resizable().scaledToFill()
            default:
                Color.secondary.opacity(0.12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .clipped()
        .overlay(alignment: .topLeading) {
            if media.isAnimated {
                Text("GIF")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.62), in: Capsule())
                    .padding(5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct FeedRetryRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("重试", action: retry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(
                cornerRadius: NativeFeedCardLayout.cornerRadius,
                style: .continuous
            )
                .fill(Color(uiColor: .secondarySystemBackground))
        }
    }
}

#if DEBUG
private enum FeedCardPreviewFixtures {
    static let author = FeedAuthorDTO(
        memberID: "preview-author",
        urlToken: nil,
        displayName: "知乎用户",
        avatarURL: nil,
        headline: ""
    )

    static let standard = item(
        id: "standard",
        title: "普通信息流卡片应完全由内容决定高度",
        summary: "作者信息紧跟摘要，不应出现不可解释的空白区域。"
    )

    static let ranked = item(
        id: "ranked",
        title: "热榜排名使用独立的横向结构",
        summary: "普通信息流不会再经过这个布局容器。"
    )

    static let gallery = item(
        id: "gallery",
        title: "多图内容使用可横向浏览的媒体轨道",
        summary: "首屏同时展示两张与部分第三张，继续滑动可以浏览全部图片。",
        media: [
            media(id: "one", width: 700, height: 1_200),
            media(id: "two", width: 1_200, height: 700),
            media(id: "three", width: 900, height: 900),
            media(id: "four", width: 600, height: 1_400),
            media(id: "five", width: 1_600, height: 700),
        ]
    )

    private static func item(
        id: String,
        title: String,
        summary: String,
        media: [FeedMediaDTO] = []
    ) -> FeedItemDTO {
        FeedItemDTO(
            id: FeedItemID(kind: .answer, contentID: id),
            kind: .answer,
            title: title,
            summary: summary,
            details: "回答 · 12345 赞同 · 678 评论",
            sourceLabel: nil,
            author: author,
            thumbnailURL: nil,
            media: media,
            route: .answer(answerID: 1, questionID: 2, questionTitle: title)
        )
    }

    private static func media(id: String, width: Int, height: Int) -> FeedMediaDTO {
        FeedMediaDTO(
            id: id,
            kind: .image,
            sourceURL: URL(string: "https://picsum.photos/seed/zhihu-\(id)/\(width)/\(height)")!,
            thumbnailURL: nil,
            pixelWidth: width,
            pixelHeight: height
        )
    }
}

#Preview("Feed card variants") {
    ScrollView {
        LazyVStack(spacing: 0) {
            NativeFeedCard(presentation: FeedCardPresentation(
                item: FeedCardPreviewFixtures.standard,
                rank: nil,
                showsMedia: true
            ))
            .nativeFeedCardItemLayout()

            NativeFeedCard(presentation: FeedCardPresentation(
                item: FeedCardPreviewFixtures.ranked,
                rank: 2,
                showsMedia: false
            ))
            .nativeFeedCardItemLayout()

            NativeFeedCard(presentation: FeedCardPresentation(
                item: FeedCardPreviewFixtures.gallery,
                rank: nil,
                showsMedia: true
            ))
            .nativeFeedCardItemLayout()
        }
    }
    .background(Color(uiColor: .systemBackground))
}
#endif
