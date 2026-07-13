import SwiftUI

struct PersonPageRow: View {
    let item: PersonPageItem
    let open: () -> Void

    var body: some View {
        if item.allowsNavigation {
            Button(action: open) { content }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case let .answer(value):
            textRow(
                title: value.questionTitle,
                summary: value.excerpt,
                metadata: "回答 · \(compact(value.voteUpCount)) 赞同 · \(compact(value.commentCount)) 评论",
                symbol: "text.bubble"
            )
        case let .article(value):
            textRow(
                title: value.title,
                summary: value.excerpt,
                metadata: "文章 · \(compact(value.voteUpCount)) 赞同 · \(compact(value.commentCount)) 评论",
                symbol: "doc.text"
            )
        case let .activity(value):
            textRow(title: value.title, summary: value.summary, metadata: value.details, symbol: "bolt.horizontal.circle")
        case let .collection(value):
            textRow(
                title: value.title,
                summary: nil,
                metadata: "\(compact(value.contentCount)) 内容 · \(compact(value.followerCount)) 关注",
                symbol: "rectangle.stack"
            )
        case let .question(value):
            textRow(
                title: value.title,
                summary: nil,
                metadata: "\(compact(value.answerCount)) 回答 · \(compact(value.followerCount)) 关注",
                symbol: "questionmark.bubble"
            )
        case let .pin(value):
            textRow(
                title: value.excerptPlainText.isEmpty ? "想法" : value.excerptPlainText,
                summary: nil,
                metadata: "\(compact(value.likeCount)) 赞 · \(compact(value.commentCount)) 评论",
                symbol: "quote.bubble"
            )
        case let .column(value):
            textRow(
                title: value.title,
                summary: value.description,
                metadata: "\(compact(value.articleCount)) 文章 · \(compact(value.followerCount)) 关注",
                symbol: "newspaper"
            )
        case let .person(value):
            personRow(value)
        case let .topic(value):
            personLikeRow(
                title: value.displayName,
                subtitle: nil,
                avatarURL: value.avatarURL,
                fallbackSymbol: "number.circle"
            )
        case let .followedQuestion(value):
            textRow(
                title: value.title,
                summary: value.questionID == nil ? "该问题暂时无法打开" : nil,
                metadata: "关注的问题",
                symbol: "questionmark.circle"
            )
        }
    }

    private func textRow(title: String, summary: String?, metadata: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.allowsNavigation {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
    }

    private func personRow(_ value: PersonListPersonItem) -> some View {
        personLikeRow(
            title: value.route.displayName,
            subtitle: [value.headline.nonBlank, "\(compact(value.answerCount)) 回答 · \(compact(value.articleCount)) 文章 · \(compact(value.followerCount)) 粉丝"]
                .compactMap { $0 }
                .joined(separator: "\n"),
            avatarURL: value.avatarURL,
            fallbackSymbol: "person.crop.circle"
        )
    }

    private func personLikeRow(
        title: String,
        subtitle: String?,
        avatarURL: URL?,
        fallbackSymbol: String
    ) -> some View {
        HStack(spacing: 12) {
            Group {
                if let avatarURL {
                    AsyncImage(url: avatarURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: fallbackSymbol)
                    }
                } else {
                    Image(systemName: fallbackSymbol)
                }
            }
            .frame(width: 48, height: 48)
            .background(Color.secondary.opacity(0.08))
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.allowsNavigation {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
    }

    private func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}

private extension PersonPageItem {
    var allowsNavigation: Bool {
        switch self {
        case .answer, .article, .collection, .question, .pin, .person:
            return true
        case let .activity(value): return value.destination != nil
        case let .column(value): return value.destination != nil
        case let .topic(value): return value.destination != nil
        case let .followedQuestion(value): return value.questionID != nil
        }
    }
}

private extension String {
    var nonBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
