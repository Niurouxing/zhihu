import Foundation

/// Projects Zhihu's HTML into the immutable block vocabulary consumed by SwiftUI.
/// Unknown tags retain their text instead of becoming tappable or being flattened into a WebView.
enum QARichContentParser {
    static func blocks(from html: String) -> [QABodyBlock] {
        var parser = Parser(html: html)
        let blocks = parser.parse()
        if !blocks.isEmpty { return blocks }
        let fallback = plainText(html)
        return fallback.isEmpty ? [] : [.paragraph(UUID(), [QAInlineRun(text: fallback)])]
    }

    static func plainText(_ html: String) -> String {
        html
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(
                of: "(?i)</(?:p|div|li|h[1-6]|blockquote|pre|figure)>",
                with: "\n",
                options: .regularExpression
            )
            .replacingOccurrences(of: "(?s)<[^>]*>", with: "", options: .regularExpression)
            .decodedHTMLEntities
            .replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Parser {
        let html: String
        var blocks: [QABodyBlock] = []
        var runs: [QAInlineRun] = []
        var style: QAInlineStyle = []
        var links: [QALinkDestination] = []
        var currentBlock: BlockContext = .paragraph
        var list: ListContext?
        var segmentID: String?
        var spanSegmentScopes: [Bool] = []
        var preformatted = false
        var preLanguage: String?
        var ignoreDepth = 0
        var figureImageIndex: Int?
        var caption = ""
        var capturingCaption = false
        var videoBox: VideoBoxContext?

        mutating func parse() -> [QABodyBlock] {
            let expression = try? NSRegularExpression(pattern: "(?s)<[^>]*>|[^<]+")
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in expression?.matches(in: html, range: range) ?? [] {
                guard let tokenRange = Range(match.range, in: html) else { continue }
                consume(String(html[tokenRange]))
            }
            finishList()
            flushBlock()
            return blocks
        }

        mutating func consume(_ token: String) {
            guard token.hasPrefix("<") else {
                guard ignoreDepth == 0 else { return }
                let value = decodeText(token, preserveWhitespace: preformatted)
                if capturingCaption { caption += value; return }
                appendText(value)
                return
            }
            let tag = HTMLTag(token)
            guard !tag.name.isEmpty else { return }
            if tag.name == "noscript" {
                ignoreDepth += tag.isClosing ? -1 : 1
                ignoreDepth = max(0, ignoreDepth)
                return
            }
            guard ignoreDepth == 0 else { return }
            tag.isClosing ? close(tag) : open(tag)
        }

        mutating func open(_ tag: HTMLTag) {
            switch tag.name {
            case "p": startBlock(.paragraph, segment: tag.segmentID)
            case "h1", "h2", "h3", "h4", "h5", "h6":
                startBlock(.heading(Int(tag.name.dropFirst()) ?? 2), segment: tag.segmentID)
            case "blockquote": startBlock(.quote, segment: tag.segmentID)
            case "pre":
                flushBlock()
                preformatted = true
                preLanguage = tag.attributes["data-language"]
                currentBlock = .code
            case "ul": startList(.unordered)
            case "ol": startList(.ordered)
            case "li": runs = []
            case "strong", "b": style.insert(.strong)
            case "em", "i": style.insert(.emphasis)
            case "s", "del": style.insert(.strikethrough)
            case "code":
                if preformatted {
                    preLanguage = preLanguage ?? tag.attributes["class"]?.replacingOccurrences(of: "language-", with: "")
                } else {
                    style.insert(.code)
                }
            case "a":
                if tag.attributes["class"]?.contains("video-box") == true,
                   let context = videoBoxContext(tag) {
                    flushBlock()
                    videoBox = context
                } else if let href = tag.attributes["href"], let destination = resolveLink(href) {
                    links.append(destination)
                }
            case "br": appendText("\n")
            case "hr":
                flushBlock()
                blocks.append(.divider(UUID()))
            case "figure":
                flushBlock()
                figureImageIndex = nil
                caption = ""
            case "figcaption": capturingCaption = true
            case "img": appendImageOrFormula(tag)
            case "span":
                if let segment = tag.segmentID {
                    flushBlock()
                    segmentID = segment
                    currentBlock = .paragraph
                    spanSegmentScopes.append(true)
                } else {
                    spanSegmentScopes.append(false)
                }
                if tag.attributes["class"]?.contains("ztext-math") == true,
                   let latex = tag.attributes["data-tex"] ?? tag.attributes["data-formula"] {
                    flushBlock()
                    blocks.append(.formula(UUID(), latex: decodeText(latex, preserveWhitespace: true)))
                }
            case "video":
                let source = tag.attributes["src"].flatMap(trustedRemoteURL)
                let poster = tag.attributes["poster"].flatMap(trustedRemoteURL)
                if let source {
                    flushBlock()
                    blocks.append(.video(UUID(), QAAttachmentVideoDTO(
                        videoID: 0,
                        thumbnailURL: poster,
                        destinationURL: nil,
                        playbackURL: source
                    )))
                }
            default: break
            }
        }

        mutating func close(_ tag: HTMLTag) {
            switch tag.name {
            case "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote":
                flushBlock()
                segmentID = nil
            case "pre":
                flushBlock()
                preformatted = false
                preLanguage = nil
                currentBlock = .paragraph
            case "ul", "ol": finishList()
            case "li":
                if let item = normalizedRuns(), !item.isEmpty { list?.items.append(QAListItem(runs: item)) }
                runs = []
            case "strong", "b": style.remove(.strong)
            case "em", "i": style.remove(.emphasis)
            case "s", "del": style.remove(.strikethrough)
            case "code": if !preformatted { style.remove(.code) }
            case "a":
                if let video = videoBox {
                    blocks.append(.video(UUID(), QAAttachmentVideoDTO(
                        videoID: video.videoID,
                        thumbnailURL: video.thumbnailURL,
                        destinationURL: video.destinationURL
                    )))
                    videoBox = nil
                } else if !links.isEmpty {
                    links.removeLast()
                }
            case "span":
                if spanSegmentScopes.popLast() == true {
                    flushBlock()
                    segmentID = nil
                }
            case "figcaption": capturingCaption = false
            case "figure": applyCaptionToFigureImage()
            default: break
            }
        }

        mutating func startBlock(_ block: BlockContext, segment: String?) {
            flushBlock()
            currentBlock = block
            segmentID = segment
        }

        mutating func startList(_ kind: QAListKind) {
            flushBlock()
            finishList()
            list = ListContext(kind: kind, items: [])
        }

        mutating func finishList() {
            guard list != nil else { return }
            if !runs.isEmpty, let item = normalizedRuns(), !item.isEmpty {
                self.list?.items.append(QAListItem(runs: item))
            }
            if let completed = self.list, !completed.items.isEmpty {
                blocks.append(.list(UUID(), kind: completed.kind, items: completed.items))
            }
            self.list = nil
            runs = []
        }

        mutating func appendText(_ value: String) {
            guard !value.isEmpty else { return }
            runs.append(QAInlineRun(text: value, style: style, link: links.last))
        }

        mutating func flushBlock() {
            guard let normalized = normalizedRuns(), !normalized.isEmpty else {
                runs = []
                return
            }
            let id = UUID()
            if let segmentID {
                blocks.append(.segment(id, segmentID: segmentID, runs: normalized))
            } else {
                switch currentBlock {
                case .paragraph: blocks.append(.paragraph(id, normalized))
                case let .heading(level): blocks.append(.heading(id, level: level, runs: normalized))
                case .quote: blocks.append(.quote(id, normalized))
                case .code:
                    blocks.append(.code(id, language: preLanguage?.nilIfBlank, text: normalized.map(\.text).joined()))
                }
            }
            runs = []
            currentBlock = .paragraph
        }

        func normalizedRuns() -> [QAInlineRun]? {
            guard !runs.isEmpty else { return nil }
            if preformatted { return runs }
            var result = runs
            while let first = result.first, first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.removeFirst()
            }
            while let last = result.last, last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.removeLast()
            }
            guard !result.isEmpty else { return nil }
            return result.enumerated().map { index, run in
                var text = run.text.replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
                if index == 0 { text = text.trimmingCharacters(in: .whitespaces) }
                if index == result.count - 1 { text = text.trimmingCharacters(in: .whitespaces) }
                return QAInlineRun(id: run.id, text: text, style: run.style, link: run.link)
            }.filter { !$0.text.isEmpty }
        }

        mutating func appendImageOrFormula(_ tag: HTMLTag) {
            let className = tag.attributes["class"] ?? ""
            if className.contains("ztext-math") || tag.attributes["data-formula"] != nil || tag.attributes["data-tex"] != nil {
                let latex = tag.attributes["data-formula"] ?? tag.attributes["data-tex"] ?? tag.attributes["alt"]
                if let latex = latex?.nilIfBlank {
                    flushBlock()
                    blocks.append(.formula(UUID(), latex: decodeText(latex, preserveWhitespace: true)))
                }
                return
            }
            let rawURL = tag.attributes["data-original"] ?? tag.attributes["data-actualsrc"] ?? tag.attributes["src"]
            guard let url = rawURL.flatMap(trustedRemoteURL) else { return }
            if videoBox != nil {
                videoBox?.thumbnailURL = url
                return
            }
            flushBlock()
            let image = QAImageDTO(url: url, altText: tag.attributes["alt"]?.nilIfBlank)
            blocks.append(.image(image))
            figureImageIndex = blocks.count - 1
        }

        mutating func applyCaptionToFigureImage() {
            guard let index = figureImageIndex,
                  blocks.indices.contains(index),
                  case let .image(image) = blocks[index]
            else { return }
            blocks[index] = .image(
                QAImageDTO(id: image.id, url: image.url, caption: caption.nilIfBlank, altText: image.altText)
            )
            figureImageIndex = nil
            caption = ""
        }

        private func videoBoxContext(_ tag: HTMLTag) -> VideoBoxContext? {
            let href = tag.attributes["href"]
            let linkedURL = href.flatMap(normalizedRemoteURL)
            let targetURL = linkedURL.flatMap(unwrappedZhihuTarget) ?? linkedURL
            let targetVideoID = targetURL.flatMap(videoID)
            guard let id = targetVideoID
                ?? tag.attributes["data-lens-id"].flatMap(Int64.init)
            else { return nil }
            return VideoBoxContext(
                videoID: id,
                thumbnailURL: nil,
                destinationURL: targetURL ?? URL(string: "https://www.zhihu.com/video/\(id)")!
            )
        }
    }

    private enum BlockContext {
        case paragraph
        case heading(Int)
        case quote
        case code
    }

    private struct ListContext {
        let kind: QAListKind
        var items: [QAListItem]
    }

    private struct VideoBoxContext {
        let videoID: Int64
        var thumbnailURL: URL?
        let destinationURL: URL
    }

    private struct HTMLTag {
        let name: String
        let attributes: [String: String]
        let isClosing: Bool

        init(_ raw: String) {
            let trimmed = raw.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
            isClosing = trimmed.hasPrefix("/")
            let content = isClosing ? trimmed.dropFirst().trimmingCharacters(in: .whitespaces) : trimmed
            name = content.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
            var parsed: [String: String] = [:]
            let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
            if let expression = try? NSRegularExpression(pattern: pattern) {
                let string = String(content)
                let range = NSRange(string.startIndex..<string.endIndex, in: string)
                for match in expression.matches(in: string, range: range) {
                    guard let keyRange = Range(match.range(at: 1), in: string) else { continue }
                    let value = (2...4).compactMap { index -> String? in
                        guard match.range(at: index).location != NSNotFound,
                              let range = Range(match.range(at: index), in: string) else { return nil }
                        return String(string[range])
                    }.first ?? ""
                    parsed[String(string[keyRange]).lowercased()] = decodeText(value, preserveWhitespace: true)
                }
            }
            attributes = parsed
        }

        var segmentID: String? {
            (attributes["data-segment-id"] ?? attributes["data-seg-id"])?.nilIfBlank
        }
    }

    private static func resolveLink(_ raw: String) -> QALinkDestination? {
        let normalized = raw.hasPrefix("//") ? "https:\(raw)" : raw
        let url = normalized.hasPrefix("/")
            ? URL(string: normalized, relativeTo: URL(string: "https://www.zhihu.com"))?.absoluteURL
            : URL(string: normalized)
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "zhihu" {
            let id = url.path.split(separator: "/").first.flatMap { Int64($0) }
            switch url.host?.lowercased() {
            case "answers": return id.map(QALinkDestination.answer)
            case "articles": return id.map(QALinkDestination.article)
            case "questions": return id.map(QALinkDestination.question)
            default: return nil
            }
        }
        guard scheme == "https", url.user == nil, url.password == nil else { return nil }
        let segments = url.path.split(separator: "/").map(String.init)
        if url.host?.lowercased() == "link.zhihu.com",
           let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "target" })?.value {
            return resolveLink(target)
        }
        if url.host?.lowercased() == "zhuanlan.zhihu.com", segments.count == 2,
           segments[0] == "p", let id = Int64(segments[1]) { return .article(id) }
        if segments.count == 4, segments[0] == "question", segments[2] == "answer",
           let id = Int64(segments[3]) { return .answer(id) }
        if segments.count == 2, segments[0] == "answer", let id = Int64(segments[1]) { return .answer(id) }
        if segments.count == 2, segments[0] == "question", let id = Int64(segments[1]) { return .question(id) }
        if segments.count == 3, segments[0] == "oia", segments[1] == "articles",
           let id = Int64(segments[2]) { return .article(id) }
        if segments.count == 2, segments[0] == "people" { return .person(urlToken: segments[1]) }
        return .external(url)
    }

    private static func trustedRemoteURL(_ raw: String) -> URL? {
        let value = raw.hasPrefix("//") ? "https:\(raw)" : raw
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil
        else { return nil }
        return url
    }

    private static func normalizedRemoteURL(_ raw: String) -> URL? {
        let value: String
        if raw.hasPrefix("//") {
            value = "https:\(raw)"
        } else if raw.hasPrefix("/") {
            value = "https://www.zhihu.com\(raw)"
        } else {
            value = raw
        }
        return trustedRemoteURL(value)
    }

    private static func unwrappedZhihuTarget(_ url: URL) -> URL? {
        guard url.host?.lowercased() == "link.zhihu.com" else { return url }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "target" })?
            .value
            .flatMap(normalizedRemoteURL)
    }

    private static func videoID(_ url: URL) -> Int64? {
        let segments = url.path.split(separator: "/")
        guard let marker = segments.firstIndex(where: { $0 == "video" || $0 == "zvideo" }),
              segments.indices.contains(marker + 1)
        else { return nil }
        return Int64(segments[marker + 1])
    }

    private static func decodeText(_ value: String, preserveWhitespace: Bool) -> String {
        let decoded = value.decodedHTMLEntities
        return preserveWhitespace ? decoded : decoded.replacingOccurrences(of: "\u{00a0}", with: " ")
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var decodedHTMLEntities: String {
        var value = self
            .replacingOccurrences(of: "&nbsp;", with: "\u{00a0}", options: .caseInsensitive)
            .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
        let expression = try? NSRegularExpression(pattern: "&#(?:x([0-9A-Fa-f]+)|([0-9]+));")
        let matches = expression?.matches(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value)
        ) ?? []
        for match in matches.reversed() {
            let radix = match.range(at: 1).location == NSNotFound ? 10 : 16
            let group = radix == 16 ? match.range(at: 1) : match.range(at: 2)
            guard let groupRange = Range(group, in: value),
                  let scalarValue = UInt32(value[groupRange], radix: radix),
                  let scalar = UnicodeScalar(scalarValue),
                  let matchRange = Range(match.range, in: value)
            else { continue }
            value.replaceSubrange(matchRange, with: String(Character(scalar)))
        }
        return value.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }
}
