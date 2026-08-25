import SwiftUI

struct FeedItemRow: View {
    let item: FeedItemDTO
    let showsThumbnail: Bool
    let rank: Int?
    let onOpen: (FeedItemRoute) -> Void
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @Environment(\.nativeContentPresentation) private var presentation
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var summaryPointSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var wideThumbnailHeight: CGFloat = 96

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
        rowButton
            .questionAuthorContextMenu(
                author: item.questionAuthor,
                block: blockQuestionAuthor
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityLabel(accessibilityDescription)
    }

    private var rowButton: some View {
        Button {
            onOpen(item.route)
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 12) {
                    if let rank {
                        Text("\(rank)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(rank <= 3 ? Color.accentColor : Color.secondary)
                            .frame(minWidth: 22, alignment: .trailing)
                            .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineSpacing(1)
                            .lineLimit(2)

                        if let summary = item.summary, !summary.isEmpty {
                            let renderedPointSize = summaryPointSize * presentation.fontScale
                            Text(summary)
                                .font(.system(size: renderedPointSize))
                                .foregroundStyle(.secondary)
                                .lineSpacing(presentation.extraLineSpacing(for: renderedPointSize) * 0.45)
                                .lineLimit(presentation.feedExcerptLines)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if showsThumbnail, presentation.showsFeedThumbnails, item.media.isEmpty,
                       showsTrailingThumbnail,
                       let thumbnailURL = item.thumbnailURL {
                        FeedSingleThumbnail(
                            url: thumbnailURL,
                            cropAnchor: thumbnailPlacement.cropAnchor
                        )
                            .frame(width: 84, height: 62)
                            .clipped()
                    }
                }

                if showsThumbnail,
                   presentation.showsFeedThumbnails,
                   item.media.isEmpty,
                   showsInlineThumbnail,
                   let thumbnailURL = item.thumbnailURL {
                    FeedSingleThumbnail(
                        url: thumbnailURL,
                        cropAnchor: thumbnailPlacement.cropAnchor
                    )
                        .frame(maxWidth: .infinity)
                        .frame(height: wideThumbnailHeight)
                        .clipped()
                }

                if showsThumbnail, presentation.showsFeedThumbnails, !item.media.isEmpty {
                    FeedMediaPreview(media: item.media)
                }

                FeedItemMetadataRow(item: item)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, cardVerticalPadding)
            .background {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            }
            .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(FeedCardButtonStyle())
    }

    private var cardVerticalPadding: CGFloat {
        max(5, presentation.feedDensity.rowVerticalPadding)
    }

    private var accessibilityDescription: String {
        var components: [String] = []
        if let rank { components.append("第 \(rank) 名") }
        components.append(item.title)
        if let summary = item.summary, !summary.isEmpty {
            components.append(summary)
        }
        if let author = item.author {
            components.append(author.displayName)
        }
        let metrics = FeedItemMetadataFormatter.metricsText(
            kind: item.kind,
            details: item.details
        )
        if !metrics.isEmpty { components.append(metrics) }
        return components.joined(separator: "，")
    }

    private var showsTrailingThumbnail: Bool {
        thumbnailPlacement == .trailing && !dynamicTypeSize.isAccessibilitySize
    }

    private var showsInlineThumbnail: Bool {
        thumbnailPlacement == .wideInline
            || (thumbnailPlacement == .trailing && dynamicTypeSize.isAccessibilitySize)
    }

    private var thumbnailPlacement: FeedThumbnailPlacement {
        FeedThumbnailPresentationPolicy.placement(
            pixelWidth: item.thumbnailPixelWidth,
            pixelHeight: item.thumbnailPixelHeight
        )
    }

    private func blockQuestionAuthor(_ author: FeedAuthorDTO) {
        hapticFeedback(.commit)
        questionAuthorBlocklist.block(author)
    }
}

private struct FeedCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct FeedSingleThumbnail: View {
    let url: URL
    let cropAnchor: FeedThumbnailCropAnchor

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: cropAnchor.alignment
                    )
            default:
                Color.secondary.opacity(0.12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}

private extension FeedThumbnailCropAnchor {
    var alignment: Alignment {
        switch self {
        case .center: return .center
        case .top: return .top
        }
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

private struct FeedItemMetadataRow: View {
    let item: FeedItemDTO
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
                    if let author = item.author {
                        FeedItemAuthorLabel(author: author)
                    }
                    if !metrics.isEmpty {
                        metricsLabel
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    if let author = item.author {
                        FeedItemAuthorLabel(author: author)
                    }

                    if !metrics.isEmpty {
                        if item.author != nil {
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

    private var metrics: String {
        FeedItemMetadataFormatter.metricsText(
            kind: item.kind,
            details: item.details
        )
    }

    private var metricsLabel: some View {
        Text(metrics)
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

private struct FeedItemAuthorLabel: View {
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

private struct FeedMediaPreview: View {
    let media: [FeedMediaDTO]
    private let spacing: CGFloat = 6
    private let height: CGFloat = 88

    private var visibleMedia: ArraySlice<FeedMediaDTO> {
        FeedMediaPreviewPolicy.visibleMedia(from: media)
    }

    var body: some View {
        GeometryReader { geometry in
            let itemWidth = width(
                availableWidth: geometry.size.width,
                itemCount: visibleMedia.count
            )
            HStack(spacing: spacing) {
                ForEach(visibleMedia) { item in
                    FeedMediaThumbnail(
                        media: item,
                        overflowCount: item.id == visibleMedia.last?.id
                            ? max(0, media.count - visibleMedia.count)
                            : 0
                    )
                    .frame(width: itemWidth, height: height)
                }
            }
            .frame(width: geometry.size.width, height: height, alignment: .leading)
            .clipped()
        }
        .frame(height: height)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("想法包含 \(media.count) 张图片")
    }

    private func width(availableWidth: CGFloat, itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        let totalSpacing = spacing * CGFloat(itemCount - 1)
        return max(0, (availableWidth - totalSpacing) / CGFloat(itemCount))
    }
}

private struct FeedMediaThumbnail: View {
    let media: FeedMediaDTO
    let overflowCount: Int

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
        .overlay {
            if overflowCount > 0 {
                ZStack {
                    Color.black.opacity(0.52)
                    Text("+\(overflowCount)")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
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
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}
