import SwiftUI

struct FeedItemRow: View {
    let item: FeedItemDTO
    let showsThumbnail: Bool
    let onOpen: (FeedItemRoute) -> Void
    @Environment(\.nativeContentPresentation) private var presentation
    @ScaledMetric(relativeTo: .subheadline) private var summaryPointSize: CGFloat = 15

    var body: some View {
        Button {
            onOpen(item.route)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let summary = item.summary, !summary.isEmpty {
                        let renderedPointSize = summaryPointSize * presentation.fontScale
                        Text(summary)
                            .font(.system(size: renderedPointSize))
                            .foregroundStyle(.secondary)
                            .lineSpacing(presentation.extraLineSpacing(for: renderedPointSize) * 0.45)
                            .lineLimit(presentation.feedExcerptLines)
                    }

                    if let author = item.author {
                        HStack(spacing: 6) {
                            if let avatarURL = author.avatarURL {
                                AsyncImage(url: avatarURL) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Color.secondary.opacity(0.12)
                                }
                                .frame(width: 24, height: 24)
                                .clipShape(Circle())
                            }
                            Text(author.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(item.details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showsThumbnail, presentation.showsFeedThumbnails, let thumbnailURL = item.thumbnailURL {
                    AsyncImage(url: thumbnailURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.secondary.opacity(0.12)
                    }
                    .frame(width: 84, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, presentation.feedDensity.rowVerticalPadding)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title)，\(item.details)")
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}
