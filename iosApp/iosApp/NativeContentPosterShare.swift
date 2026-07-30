import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import SwiftUI
import UIKit

enum NativeContentPosterTextStyle {
    case body
    case heading
    case quote
    case code
    case caption
}

enum NativeContentPosterBlock {
    case text(String, style: NativeContentPosterTextStyle)
    case image(URL, caption: String?)
    case divider
}

struct NativeContentPosterDocument: Identifiable {
    let title: String
    let authorName: String
    let authorHeadline: String
    let authorAvatarURL: URL?
    let sourceURL: URL
    let metadata: String
    let blocks: [NativeContentPosterBlock]

    var id: String { sourceURL.absoluteString }

    init(
        title: String,
        authorName: String,
        authorHeadline: String = "",
        authorAvatarURL: URL? = nil,
        sourceURL: URL,
        metadata: String,
        blocks: [NativeContentPosterBlock]
    ) {
        self.title = title
        self.authorName = authorName
        self.authorHeadline = authorHeadline
        self.authorAvatarURL = authorAvatarURL
        self.sourceURL = sourceURL
        self.metadata = metadata
        self.blocks = blocks
    }

    init(answer: AnswerDTO) {
        title = answer.title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? (answer.route.kind == .answer ? "知乎回答" : "知乎文章")
        authorName = answer.author.displayName.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "匿名用户"
        authorHeadline = answer.author.headline
        authorAvatarURL = answer.author.avatarURL
        sourceURL = answer.sourceURL
        metadata = [
            "\(answer.voteUpCount) 赞同",
            "\(answer.commentCount) 评论",
        ].joined(separator: " · ")
        var posterBlocks = answer.blocks.flatMap(Self.answerBlocks)
        if let attachment = answer.attachment {
            posterBlocks.append(contentsOf: Self.answerBlocks(.video(UUID(), attachment)))
        }
        blocks = posterBlocks
    }

    init(pin: PinDetailDTO) {
        title = "\(pin.author.displayName)的想法"
        authorName = pin.author.displayName
        authorHeadline = pin.author.headline
        authorAvatarURL = pin.author.avatarURL
        sourceURL = pin.sourceURL
        metadata = "\(pin.likeCount) 赞 · \(pin.commentCount) 评论"
        var posterBlocks = pin.blocks.flatMap(Self.pinBlocks)
        if let poll = pin.poll {
            posterBlocks.append(.text("投票：\(poll.title)", style: .heading))
            posterBlocks.append(contentsOf: poll.options.map {
                .text("• \($0.title)（\($0.voteCount) 票）", style: .body)
            })
        }
        if !pin.topics.isEmpty {
            posterBlocks.append(.text(pin.topics.map { "#\($0)" }.joined(separator: "  "), style: .caption))
        }
        blocks = posterBlocks
    }

    var imageURLs: [URL] {
        var known = Set<URL>()
        let contentURLs: [URL] = blocks.compactMap { block in
            guard case let .image(url, _) = block, known.insert(url).inserted else { return nil }
            return url
        }
        guard let authorAvatarURL, known.insert(authorAvatarURL).inserted else {
            return contentURLs
        }
        return [authorAvatarURL] + contentURLs
    }

    private static func answerBlocks(_ block: QABodyBlock) -> [NativeContentPosterBlock] {
        switch block {
        case let .paragraph(_, runs), let .segment(_, _, runs):
            return textBlock(runs, style: .body)
        case let .heading(_, _, runs):
            return textBlock(runs, style: .heading)
        case let .quote(_, runs):
            return textBlock(runs, style: .quote)
        case let .list(_, kind, items):
            let value = posterList(QAListGroup(kind: kind, items: items), depth: 0)
            return value.isEmpty ? [] : [.text(value, style: .body)]
        case let .code(_, language, text):
            let label = language?.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = [label?.isEmpty == false ? label?.uppercased() : nil, text]
                .compactMap { $0 }
                .joined(separator: "\n")
            return value.isEmpty ? [] : [.text(value, style: .code)]
        case let .formula(_, latex):
            return latex.isEmpty ? [] : [.text(latex, style: .code)]
        case let .image(image):
            return [.image(image.url, caption: image.caption ?? image.altText)]
        case let .video(_, video):
            if let thumbnailURL = video.thumbnailURL {
                return [.image(thumbnailURL, caption: "视频")]
            }
            return [.text("视频", style: .caption)]
        case .divider:
            return [.divider]
        }
    }

    private static func pinBlocks(_ block: PinContentBlockDTO) -> [NativeContentPosterBlock] {
        switch block {
        case let .text(_, text, _):
            return text.isEmpty ? [] : [.text(text, style: .body)]
        case let .image(_, url, originalURL):
            return [.image(originalURL ?? url, caption: nil)]
        case let .link(_, title, _):
            return [.text("链接：\(title)", style: .caption)]
        }
    }

    private static func textBlock(
        _ runs: [QAInlineRun],
        style: NativeContentPosterTextStyle
    ) -> [NativeContentPosterBlock] {
        let value = runs.map(\.text).joined()
        return value.isEmpty ? [] : [.text(value, style: style)]
    }

    private static func posterList(_ group: QAListGroup, depth: Int) -> String {
        group.items.enumerated().flatMap { index, item -> [String] in
            let number = item.ordinal ?? group.startIndex + index
            let marker = group.kind == .ordered ? "\(number)." : "•"
            let indentation = String(repeating: "  ", count: depth)
            let value = item.runs.map(\.text).joined()
            return ["\(indentation)\(marker) \(value)"] + item.nestedLists.map {
                posterList($0, depth: depth + 1)
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

private struct NativeContentPosterPreparedDocument {
    let document: NativeContentPosterDocument
    let images: [URL: UIImage]
    let qrCode: UIImage
    let appIcon: UIImage?
}

@MainActor
enum NativeContentPosterRenderer {
    static func render(_ document: NativeContentPosterDocument) async throws -> UIImage {
        var images: [URL: UIImage] = [:]
        for url in document.imageURLs {
            try Task.checkCancellation()
            if let image = try? await NativeContentPosterImageLoader.load(url) {
                images[url] = image
            }
        }
        guard let qrCode = NativeContentPosterQRCode.image(for: document.sourceURL) else {
            throw NativeContentPosterError.qrCodeFailed
        }
        let prepared = NativeContentPosterPreparedDocument(
            document: document,
            images: images,
            qrCode: qrCode,
            appIcon: NativeContentPosterBranding.appIcon()
        )
        let content = NativeContentPosterView(prepared: prepared)
            .frame(width: 390)
            .fixedSize(horizontal: false, vertical: true)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: 390, height: nil)
        renderer.scale = 2
        guard let image = renderer.uiImage else {
            throw NativeContentPosterError.renderFailed
        }
        return image
    }
}

private enum NativeContentPosterImageLoader {
    static let maximumBytes = 25 * 1_024 * 1_024
    static let maximumPixelSize = 1_600

    static func load(_ url: URL) async throws -> UIImage {
        guard url.scheme?.lowercased() == "https" else {
            throw URLError(.unsupportedURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .returnCacheDataElseLoad
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else {
            throw URLError(.cannotDecodeContentData)
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw URLError(.cannotDecodeContentData)
        }
        return UIImage(cgImage: cgImage)
    }
}

enum NativeContentPosterBranding {
    static let zhihuBlue = Color(red: 23 / 255, green: 114 / 255, blue: 246 / 255)
    static let headerBackground = Color(red: 242 / 255, green: 248 / 255, blue: 255 / 255)
    static let primaryText = Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255)
    static let secondaryText = Color(red: 100 / 255, green: 100 / 255, blue: 100 / 255)
    static let tertiaryText = Color(red: 133 / 255, green: 144 / 255, blue: 166 / 255)

    static func appIcon(bundle: Bundle = .main) -> UIImage? {
        let icons = bundle.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primaryIcon = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let iconFiles = primaryIcon?["CFBundleIconFiles"] as? [String] ?? []

        for iconName in iconFiles.reversed() {
            if let image = UIImage(named: iconName, in: bundle, compatibleWith: nil) {
                return image
            }
        }
        return UIImage(named: "AppIcon", in: bundle, compatibleWith: nil)
    }
}

enum NativeContentPosterQRCode {
    static func image(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext(options: nil).createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private enum NativeContentPosterError: LocalizedError {
    case qrCodeFailed
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .qrCodeFailed: return "二维码生成失败"
        case .renderFailed: return "长图生成失败，内容可能过长"
        }
    }
}

private struct NativeContentPosterView: View {
    let prepared: NativeContentPosterPreparedDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader

            VStack(alignment: .leading, spacing: 18) {
                Text(prepared.document.title)
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(NativeContentPosterBranding.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .center, spacing: 12) {
                    authorAvatar

                    VStack(alignment: .leading, spacing: 4) {
                        Text(prepared.document.authorName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(NativeContentPosterBranding.primaryText)
                        if !prepared.document.authorHeadline.isEmpty {
                            Text(prepared.document.authorHeadline)
                                .font(.system(size: 13))
                                .foregroundStyle(NativeContentPosterBranding.secondaryText)
                                .lineLimit(2)
                        }
                        Text(prepared.document.metadata)
                            .font(.system(size: 13))
                            .foregroundStyle(NativeContentPosterBranding.tertiaryText)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 15) {
                    ForEach(Array(prepared.document.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
            }
            .padding(24)
        }
        .background(.white)
        .environment(\.colorScheme, .light)
    }

    private var brandHeader: some View {
        HStack(spacing: 12) {
            Group {
                if let appIcon = prepared.appIcon {
                    Image(uiImage: appIcon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(NativeContentPosterBranding.zhihuBlue)
                }
            }
            .frame(width: 52, height: 52)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text("知乎++")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(NativeContentPosterBranding.primaryText)
                Text("扫码查看原文")
                    .font(.system(size: 13))
                    .foregroundStyle(NativeContentPosterBranding.secondaryText)
            }

            Spacer(minLength: 12)

            Image(uiImage: prepared.qrCode)
                .interpolation(.none)
                .resizable()
                .frame(width: 64, height: 64)
                .padding(5)
                .background(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(NativeContentPosterBranding.headerBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NativeContentPosterBranding.zhihuBlue)
                .frame(height: 2)
        }
    }

    @ViewBuilder
    private var authorAvatar: some View {
        if let avatarURL = prepared.document.authorAvatarURL,
           let avatarImage = prepared.images[avatarURL] {
            Image(uiImage: avatarImage)
                .resizable()
                .scaledToFill()
                .frame(width: 50, height: 50)
                .clipShape(Circle())
        } else {
            Text(prepared.document.authorName.prefix(1))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(NativeContentPosterBranding.zhihuBlue)
                .frame(width: 50, height: 50)
                .background(NativeContentPosterBranding.headerBackground, in: Circle())
        }
    }

    @ViewBuilder
    private func blockView(_ block: NativeContentPosterBlock) -> some View {
        switch block {
        case let .text(value, style):
            Text(value)
                .font(font(style))
                .foregroundStyle(foreground(style))
                .lineSpacing(style == .body || style == .quote ? 5 : 2)
                .padding(.leading, style == .quote ? 12 : 0)
                .overlay(alignment: .leading) {
                    if style == .quote {
                        Capsule()
                            .fill(NativeContentPosterBranding.zhihuBlue)
                            .frame(width: 3)
                    }
                }
                .padding(style == .code ? 12 : 0)
                .background(
                    style == .code
                        ? Color(uiColor: .secondarySystemBackground)
                        : .clear,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .fixedSize(horizontal: false, vertical: true)
        case let .image(url, caption):
            VStack(spacing: 7) {
                if let image = prepared.images[url] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Label("图片暂未载入", systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .background(Color(uiColor: .secondarySystemBackground))
                }
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
        case .divider:
            Divider()
        }
    }

    private func font(_ style: NativeContentPosterTextStyle) -> Font {
        switch style {
        case .body: return .system(size: 17)
        case .heading: return .system(size: 20, weight: .bold)
        case .quote: return .system(size: 16)
        case .code: return .system(size: 14, design: .monospaced)
        case .caption: return .system(size: 13)
        }
    }

    private func foreground(_ style: NativeContentPosterTextStyle) -> Color {
        style == .quote || style == .caption
            ? NativeContentPosterBranding.secondaryText
            : NativeContentPosterBranding.primaryText
    }
}

struct NativeContentPosterShareView: View {
    let document: NativeContentPosterDocument

    @Environment(\.dismiss) private var dismiss
    @State private var renderedImage: UIImage?
    @State private var activity: NativeContentPosterActivity?
    @State private var errorMessage: String?
    @State private var isRendering = true

    var body: some View {
        NavigationStack {
            Group {
                if let renderedImage {
                    ScrollView {
                        Image(uiImage: renderedImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .padding(14)
                    }
                    .background(Color(uiColor: .secondarySystemBackground))
                } else if isRendering {
                    ProgressView("正在生成分享长图")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(errorMessage ?? "分享长图生成失败")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") { Task { await render() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                }
            }
            .navigationTitle("分享预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("分享") {
                        guard let renderedImage else { return }
                        activity = NativeContentPosterActivity(
                            items: [renderedImage]
                        )
                    }
                    .disabled(renderedImage == nil)
                }
            }
        }
        .task(id: document.id) { await render() }
        .sheet(item: $activity) { activity in
            NativeContentPosterActivityView(items: activity.items)
        }
    }

    @MainActor
    private func render() async {
        isRendering = true
        errorMessage = nil
        renderedImage = nil
        do {
            renderedImage = try await NativeContentPosterRenderer.render(document)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isRendering = false
    }
}

private struct NativeContentPosterActivity: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct NativeContentPosterActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
