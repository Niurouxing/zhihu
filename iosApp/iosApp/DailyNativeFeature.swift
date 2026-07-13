import Foundation
import SwiftUI

struct DailyStoryDTO: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let sourceURL: URL
    let hint: String
    let imageURL: URL?
}

struct DailySectionDTO: Identifiable, Hashable, Sendable {
    let date: String
    let stories: [DailyStoryDTO]
    var id: String { date }
}

enum DailyStoryDestination: Hashable, Sendable {
    case feed(FeedItemRoute)
    case external(URL)
}

protocol DailyRepository: Sendable {
    func fetchLatest() async throws -> DailySectionDTO
    func fetchBefore(_ date: String) async throws -> DailySectionDTO
    func resolveDestination(for story: DailyStoryDTO) async -> DailyStoryDestination
}

actor URLSessionDailyRepository: DailyRepository {
    private static let primaryBase = "https://news-at.zhihu.com/api/4/stories"
    private static let fallbackBase = "https://daily.zhihu.com/api/4/stories"
    private let client: ZhihuAPIClient

    init(client: ZhihuAPIClient) {
        self.client = client
    }

    func fetchLatest() async throws -> DailySectionDTO {
        try await fetch(path: "/latest")
    }

    func fetchBefore(_ date: String) async throws -> DailySectionDTO {
        guard date.range(of: #"^\d{8}$"#, options: .regularExpression) != nil else {
            throw ZhihuAPIError.malformedPayload
        }
        return try await fetch(path: "/before/\(date)")
    }

    func resolveDestination(for story: DailyStoryDTO) async -> DailyStoryDestination {
        guard let detailURL = URL(string: "https://daily.zhihu.com/api/7/story/\(story.id)"),
              let data = try? await client.data(for: detailURL, authentication: .guest),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["body"] as? String,
              let originURL = DailyHTMLOriginParser.originURL(in: body)
        else { return .external(story.sourceURL) }
        return DailyRouteResolver.destination(url: originURL, fallbackTitle: story.title)
    }

    private func fetch(path: String) async throws -> DailySectionDTO {
        let primary = URL(string: Self.primaryBase + path)!
        do {
            let data = try await client.data(for: primary, authentication: .guest)
            return try Self.decode(data)
        } catch let error as URLError where Self.isHostResolutionFailure(error) {
            let fallback = URL(string: Self.fallbackBase + path)!
            let data = try await client.data(for: fallback, authentication: .guest)
            return try Self.decode(data)
        }
    }

    private static func decode(_ data: Data) throws -> DailySectionDTO {
        guard let response = try? JSONDecoder().decode(DailyAPIResponse.self, from: data) else {
            throw ZhihuAPIError.malformedPayload
        }
        let stories = response.stories.compactMap { story -> DailyStoryDTO? in
            guard let source = secureURL(story.url) else { return nil }
            return DailyStoryDTO(
                id: story.id,
                title: story.title,
                sourceURL: source,
                hint: story.hint,
                imageURL: story.images.first.flatMap(secureDailyMediaURL)
            )
        }
        return DailySectionDTO(date: response.date, stories: stories)
    }

    private static func isHostResolutionFailure(_ error: URLError) -> Bool {
        error.code == .cannotFindHost || error.code == .dnsLookupFailed
    }
}

private struct DailyAPIResponse: Decodable {
    let date: String
    let stories: [DailyAPIStory]
}

private struct DailyAPIStory: Decodable {
    let id: Int64
    let title: String
    let url: String
    let hint: String
    let images: [String]
}

enum DailyHTMLOriginParser {
    static func originURL(in html: String) -> URL? {
        let candidates = [
            #"<a[^>]*class=[\"'][^\"']*originUrl[^\"']*[\"'][^>]*href=[\"']([^\"']+)[\"']"#,
            #"<a[^>]*href=[\"']([^\"']+)[\"'][^>]*class=[\"'][^\"']*originUrl[^\"']*[\"']"#,
            #"<div[^>]*class=[\"'][^\"']*view-more[^\"']*[\"'][^>]*>[\s\S]*?<a[^>]*href=[\"']([^\"']+)[\"']"#,
        ]
        for pattern in candidates {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html),
                  let url = secureURL(String(html[range]).replacingOccurrences(of: "&amp;", with: "&"))
            else { continue }
            return url
        }
        return nil
    }
}

enum DailyRouteResolver {
    static func destination(url: URL, fallbackTitle: String) -> DailyStoryDestination {
        let parts = url.pathComponents.filter { $0 != "/" }
        if let questionIndex = parts.firstIndex(of: "question"), parts.indices.contains(questionIndex + 1),
           let questionID = Int64(parts[questionIndex + 1]) {
            if parts.indices.contains(questionIndex + 3), parts[questionIndex + 2] == "answer",
               let answerID = Int64(parts[questionIndex + 3]) {
                return .feed(.answer(answerID: answerID, questionID: questionID, questionTitle: fallbackTitle))
            }
            return .feed(.question(questionID: questionID, title: fallbackTitle))
        }
        if let index = parts.firstIndex(of: "p"), parts.indices.contains(index + 1), let id = Int64(parts[index + 1]) {
            return .feed(.article(articleID: id, title: fallbackTitle))
        }
        if let index = parts.firstIndex(of: "pin"), parts.indices.contains(index + 1), let id = Int64(parts[index + 1]) {
            return .feed(.pin(pinID: id))
        }
        if let index = parts.firstIndex(of: "zvideo"), parts.indices.contains(index + 1), let id = Int64(parts[index + 1]) {
            return .feed(.video(videoID: id))
        }
        return .external(url)
    }
}

@MainActor
final class DailyNativeStore: ObservableObject {
    @Published private(set) var sections: [DailySectionDTO] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?

    private let repository: DailyRepository
    private var nextDate: String?
    private var hasLoaded = false
    private var generation: UInt64 = 0

    init(repository: DailyRepository) {
        self.repository = repository
    }

    func loadInitialIfNeeded() async {
        guard !hasLoaded else { return }
        await loadLatest()
    }

    func loadLatest() async {
        await replace { try await repository.fetchLatest() }
    }

    func load(date: Date, calendar: Calendar = .current) async {
        guard let requestDate = calendar.date(byAdding: .day, value: 1, to: date) else { return }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let value = formatter.string(from: requestDate)
        await replace { try await repository.fetchBefore(value) }
    }

    func loadMore() async {
        guard !isLoadingMore, let nextDate else { return }
        isLoadingMore = true
        do {
            let section = try await repository.fetchBefore(nextDate)
            if !section.stories.isEmpty, !sections.contains(where: { $0.id == section.id }) {
                sections.append(section)
            }
            self.nextDate = section.date
        } catch is CancellationError {
            isLoadingMore = false
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingMore = false
    }

    func destination(for story: DailyStoryDTO) async -> DailyStoryDestination {
        await repository.resolveDestination(for: story)
    }

    private func replace(operation: () async throws -> DailySectionDTO) async {
        generation &+= 1
        let current = generation
        isLoading = true
        errorMessage = nil
        do {
            let section = try await operation()
            guard current == generation else { return }
            sections = section.stories.isEmpty ? [] : [section]
            nextDate = section.date
            hasLoaded = true
        } catch is CancellationError {
            if current == generation { isLoading = false }
            return
        } catch {
            guard current == generation else { return }
            errorMessage = error.localizedDescription
        }
        if current == generation { isLoading = false }
    }
}

struct DailyNativeView: View {
    @StateObject private var store: DailyNativeStore
    @State private var selectedDate = Date()
    @State private var showsDatePicker = false
    let onOpen: (DailyStoryDestination) -> Void

    init(repository: DailyRepository, onOpen: @escaping (DailyStoryDestination) -> Void) {
        _store = StateObject(wrappedValue: DailyNativeStore(repository: repository))
        self.onOpen = onOpen
    }

    var body: some View {
        List {
            if store.sections.isEmpty, store.isLoading {
                HStack { Spacer(); ProgressView("正在加载日报"); Spacer() }
                    .listRowSeparator(.hidden)
            }
            ForEach(store.sections) { section in
                Section(formatted(section.date)) {
                    ForEach(section.stories) { story in
                        Button {
                            Task { onOpen(await store.destination(for: story)) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(story.title).font(.headline).foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(story.hint).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if let imageURL = story.imageURL {
                                    AsyncImage(url: imageURL) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Color.secondary.opacity(0.12)
                                    }
                                    .frame(width: 92, height: 68)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let error = store.errorMessage {
                FeedRetryRow(message: error) { Task { await store.loadLatest() } }
            } else if !store.sections.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
                    .task { await store.loadMore() }
            } else if !store.isLoading {
                Text("暂无日报内容").foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .navigationTitle("知乎日报")
        .refreshable { await store.loadLatest() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showsDatePicker = true } label: {
                    Label("选择日期", systemImage: "calendar")
                }
            }
        }
        .sheet(isPresented: $showsDatePicker) {
            NavigationView {
                DatePicker("日期", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding()
                    .navigationTitle("选择日期")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showsDatePicker = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("查看") {
                                showsDatePicker = false
                                Task { await store.load(date: selectedDate) }
                            }
                        }
                    }
            }
        }
        .task { await store.loadInitialIfNeeded() }
        .accessibilityIdentifier("daily_native")
    }

    private func formatted(_ date: String) -> String {
        guard date.count == 8 else { return date }
        return "\(date.prefix(4)) 年 \(date.dropFirst(4).prefix(2)) 月 \(date.suffix(2)) 日"
    }
}

private func secureURL(_ value: String) -> URL? {
    guard var components = URLComponents(string: value) else { return nil }
    if components.scheme?.lowercased() == "http" { components.scheme = "https" }
    guard let url = components.url, ZhihuAPIURLPolicy.allows(url) else { return nil }
    return url
}

private func secureDailyMediaURL(_ value: String) -> URL? {
    guard let url = URL(string: value), url.scheme?.lowercased() == "https" else { return nil }
    return url
}
