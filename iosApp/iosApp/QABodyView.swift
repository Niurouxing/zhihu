import AVKit
import SwiftUI

struct QABodyView: View {
    let blocks: [QABodyBlock]
    let segmentSubject: CommentSubjectDTO?
    let onNavigate: (QANavigationIntent) -> Void
    @Environment(\.nativeContentPresentation) private var presentation
    @ScaledMetric(relativeTo: .body) private var bodyPointSize: CGFloat = 17
    @ScaledMetric(relativeTo: .callout) private var calloutPointSize: CGFloat = 16

    init(
        blocks: [QABodyBlock],
        segmentSubject: CommentSubjectDTO? = nil,
        onNavigate: @escaping (QANavigationIntent) -> Void
    ) {
        self.blocks = blocks
        self.segmentSubject = segmentSubject
        self.onNavigate = onNavigate
    }

    private var galleryImages: [QAImageDTO] {
        blocks.compactMap { block in
            guard case let .image(image) = block else { return nil }
            return image
        }
    }

    private var galleryURLs: [URL] { galleryImages.map(\.url) }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: presentation.blockSpacing()) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            guard let destination = QABodyLinkResolver.resolve(url) else { return .discarded }
            onNavigate(.link(destination))
            return .handled
        })
    }

    @ViewBuilder
    private func blockView(_ block: QABodyBlock) -> some View {
        switch block {
        case let .paragraph(_, runs):
            Text(attributed(runs))
                .font(bodyFont)
                .lineSpacing(bodyLineSpacing)
                .tint(.accentColor)
                .textSelection(.enabled)
        case let .heading(_, level, runs):
            Text(attributed(runs))
                .font(headingFont(level))
                .fontWeight(.bold)
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 8 : 2)
        case let .quote(_, runs):
            HStack(alignment: .top, spacing: 12) {
                Capsule().fill(.secondary.opacity(0.38)).frame(width: 3)
                Text(attributed(runs))
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
                    .lineSpacing(bodyLineSpacing)
                    .tint(.accentColor)
                    .textSelection(.enabled)
            }
        case let .list(_, kind, items):
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(kind == .ordered ? "\(index + 1)." : "•")
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        Text(attributed(item.runs))
                            .font(bodyFont)
                            .lineSpacing(bodyLineSpacing)
                            .tint(.accentColor)
                            .textSelection(.enabled)
                    }
                }
            }
        case let .code(_, language, text):
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 7) {
                    if let language, !language.isEmpty {
                        Text(language.uppercased())
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text(text)
                        .font(.system(size: calloutPointSize * presentation.fontScale, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(14)
            }
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        case let .formula(_, latex):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(latex)
                    .font(.system(size: bodyPointSize * presentation.fontScale, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("公式 \(latex)")
        case let .image(image):
            Button {
                let index = galleryImages.firstIndex { $0.id == image.id } ?? 0
                onNavigate(.images(urls: galleryURLs, initialIndex: index))
            } label: {
                VStack(spacing: 7) {
                    AsyncImage(url: image.url) { phase in
                        switch phase {
                        case let .success(value):
                            value.resizable().scaledToFit()
                        case .failure:
                            VStack(spacing: 8) {
                                Image(systemName: "photo.badge.exclamationmark")
                                Text("图片加载失败").font(.caption)
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                        case .empty:
                            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    if let caption = image.caption ?? image.altText, !caption.isEmpty {
                        Text(caption).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(image.altText ?? image.caption ?? "查看图片")
        case let .segment(_, segmentID, runs):
            if let segmentSubject,
               let subject = segmentCommentSubject(segmentSubject, segmentID: segmentID) {
                HStack(alignment: .bottom, spacing: 7) {
                    Text(attributed(runs))
                        .font(bodyFont)
                        .lineSpacing(bodyLineSpacing)
                        .tint(.accentColor)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                    Button {
                        onNavigate(.segmentComments(CommentThreadRouteDTO(subject: subject)))
                    } label: {
                        Image(systemName: "text.bubble")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看本段评论")
                }
            } else {
                HStack(alignment: .bottom, spacing: 7) {
                    Text(attributed(runs))
                        .font(bodyFont)
                        .lineSpacing(bodyLineSpacing)
                        .tint(.accentColor)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                }
            }
        case let .video(_, video):
            if video.playbackURL != nil {
                QANativeVideoPlayer(video: video)
            } else {
                QAVideoAttachmentView(video: video) {
                    if let destinationURL = video.destinationURL {
                        onNavigate(.videoPage(destinationURL))
                    }
                }
            }
        case .divider:
            Divider()
        }
    }

    private func attributed(_ runs: [QAInlineRun]) -> AttributedString {
        runs.reduce(into: AttributedString()) { value, run in
            var part = AttributedString(run.text)
            var presentation: InlinePresentationIntent = []
            if run.style.contains(.strong) { presentation.insert(.stronglyEmphasized) }
            if run.style.contains(.emphasis) { presentation.insert(.emphasized) }
            if !presentation.isEmpty { part.inlinePresentationIntent = presentation }
            if run.style.contains(.strikethrough) { part.strikethroughStyle = .single }
            if run.style.contains(.code) {
                part.font = .body.monospaced()
                part.backgroundColor = Color(uiColor: .secondarySystemBackground)
            }
            if let link = run.link {
                part.link = QABodyLinkResolver.url(link)
                part.foregroundColor = .accentColor
                part.underlineStyle = .single
            }
            value.append(part)
        }
    }

    private var bodyFont: Font {
        .system(size: bodyPointSize * presentation.fontScale)
    }

    private var bodyLineSpacing: CGFloat {
        presentation.extraLineSpacing(for: bodyPointSize * presentation.fontScale)
    }

    private func headingFont(_ level: Int) -> Font {
        let scale = presentation.fontScale
        switch level {
        case 1: return .system(size: 22 * scale, weight: .bold)
        case 2: return .system(size: 20 * scale, weight: .bold)
        case 3: return .system(size: 17 * scale, weight: .semibold)
        default: return .system(size: bodyPointSize * scale, weight: .semibold)
        }
    }

    private func segmentCommentSubject(
        _ subject: CommentSubjectDTO,
        segmentID: String
    ) -> CommentSubjectDTO? {
        switch subject {
        case let .answer(id): return .segment(contentID: String(id), contentTypeRaw: "answer", segmentID: segmentID)
        case let .article(id): return .segment(contentID: String(id), contentTypeRaw: "article", segmentID: segmentID)
        case let .question(id): return .segment(contentID: String(id), contentTypeRaw: "question", segmentID: segmentID)
        case let .pin(id): return .segment(contentID: String(id), contentTypeRaw: "pin", segmentID: segmentID)
        case .segment: return nil
        }
    }
}

private struct QANativeVideoPlayer: View {
    let video: QAAttachmentVideoDTO
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
            } else if let thumbnailURL = video.thumbnailURL {
                AsyncImage(url: thumbnailURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView().tint(.white)
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear {
            guard player == nil, let playbackURL = video.playbackURL else { return }
            player = AVPlayer(url: playbackURL)
        }
        .onDisappear { player?.pause() }
        .accessibilityLabel("视频播放器")
    }
}

private struct QAVideoAttachmentView: View {
    let video: QAAttachmentVideoDTO
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                AsyncImage(url: video.thumbnailURL) { phase in
                    switch phase {
                    case let .success(image): image.resizable().scaledToFill()
                    case .failure:
                        Color(uiColor: .secondarySystemBackground)
                            .overlay(Image(systemName: "video.slash").foregroundStyle(.secondary))
                    case .empty:
                        Color(uiColor: .secondarySystemBackground)
                            .overlay(ProgressView())
                    @unknown default:
                        Color(uiColor: .secondarySystemBackground)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white, .black.opacity(0.34))
                    .shadow(radius: 8)
                VStack {
                    Spacer()
                    HStack {
                        Label("视频", systemImage: "play.rectangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(10)
                    .background(.black.opacity(0.38))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(video.destinationURL == nil)
        .accessibilityLabel("播放视频")
    }
}

enum QABodyLinkResolver {
    static func url(_ destination: QALinkDestination) -> URL? {
        switch destination {
        case let .answer(id): return URL(string: "zhihu://answers/\(id)")
        case let .article(id): return URL(string: "zhihu://articles/\(id)")
        case let .question(id): return URL(string: "zhihu://questions/\(id)")
        case let .person(token): return URL(string: "zhihu://people/\(token)")
        case let .external(url): return url
        }
    }

    static func resolve(_ url: URL) -> QALinkDestination? {
        if url.scheme?.lowercased() == "zhihu" {
            let value = url.path.split(separator: "/").first.map(String.init)
            switch url.host?.lowercased() {
            case "answers": return value.flatMap(Int64.init).map(QALinkDestination.answer)
            case "articles": return value.flatMap(Int64.init).map(QALinkDestination.article)
            case "questions": return value.flatMap(Int64.init).map(QALinkDestination.question)
            case "people": return value.map(QALinkDestination.person)
            default: return nil
            }
        }
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { return nil }
        return .external(url)
    }
}
