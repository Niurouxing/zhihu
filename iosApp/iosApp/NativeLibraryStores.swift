import Foundation

@MainActor
final class NativeCollectionsStore: ObservableObject {
    @Published private(set) var collections: [NativeLibraryCollection] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isEnd = false
    @Published private(set) var errorMessage: String?

    private let userToken: String
    private let repository: NativeLibraryRepository
    private var next: URL?
    private var revision = UUID()

    init(userToken: String, repository: NativeLibraryRepository) {
        self.userToken = userToken
        self.repository = repository
    }

    func refresh() async {
        guard !isLoading else { return }
        let current = UUID()
        revision = current
        isLoading = true
        errorMessage = nil
        defer { if revision == current { isLoading = false } }
        do {
            let page = try await repository.fetchCollections(userToken, nil)
            guard revision == current else { return }
            collections = page.items
            next = page.paging.next
            isEnd = page.paging.isEnd
        } catch is CancellationError {
            return
        } catch {
            guard revision == current else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard !isLoading, !isEnd, !collections.isEmpty else { return }
        let current = revision
        isLoading = true
        defer { if revision == current { isLoading = false } }
        do {
            let page = try await repository.fetchCollections(userToken, next)
            guard revision == current else { return }
            let existing = Set(collections.map(\.id))
            collections.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            next = page.paging.next
            isEnd = page.paging.isEnd
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard revision == current else { return }
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class NativeCollectionContentStore: ObservableObject {
    @Published private(set) var collection: NativeLibraryCollection?
    @Published private(set) var items: [NativeLibraryItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isEnd = false
    @Published private(set) var errorMessage: String?

    private let collectionID: String
    private let repository: NativeLibraryRepository
    private var next: URL?
    private var revision = UUID()

    init(collectionID: String, repository: NativeLibraryRepository) {
        self.collectionID = collectionID
        self.repository = repository
    }

    func refresh() async {
        guard !isLoading else { return }
        let current = UUID()
        revision = current
        isLoading = true
        errorMessage = nil
        defer { if revision == current { isLoading = false } }
        async let metadata = repository.fetchCollection(collectionID)
        async let page = repository.fetchCollectionItems(collectionID, nil)
        do {
            let (loadedCollection, loadedPage) = try await (metadata, page)
            guard revision == current else { return }
            collection = loadedCollection
            items = loadedPage.items
            next = loadedPage.paging.next
            isEnd = loadedPage.paging.isEnd
        } catch is CancellationError {
            return
        } catch {
            guard revision == current else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard !isLoading, !isEnd, !items.isEmpty else { return }
        let current = revision
        isLoading = true
        defer { if revision == current { isLoading = false } }
        do {
            let page = try await repository.fetchCollectionItems(collectionID, next)
            guard revision == current else { return }
            let existing = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            next = page.paging.next
            isEnd = page.paging.isEnd
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard revision == current else { return }
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class NativeHistoryStore: ObservableObject {
    @Published private(set) var items: [NativeHistoryItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isClearing = false
    @Published private(set) var isEnd = false
    @Published private(set) var errorMessage: String?

    private let repository: NativeLibraryRepository
    private var next: URL?
    private var revision = UUID()

    init(repository: NativeLibraryRepository) {
        self.repository = repository
    }

    func refresh() async {
        guard !isLoading, !isClearing else { return }
        let current = UUID()
        revision = current
        isLoading = true
        errorMessage = nil
        defer { if revision == current { isLoading = false } }
        do {
            let page = try await repository.fetchHistory(nil)
            guard revision == current else { return }
            items = page.items
            next = page.paging.next
            isEnd = page.paging.isEnd
        } catch is CancellationError {
            return
        } catch {
            guard revision == current else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard !isLoading, !isClearing, !isEnd, !items.isEmpty else { return }
        let current = revision
        isLoading = true
        defer { if revision == current { isLoading = false } }
        do {
            let page = try await repository.fetchHistory(next)
            guard revision == current else { return }
            let existing = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            next = page.paging.next
            isEnd = page.paging.isEnd
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard revision == current else { return }
            errorMessage = error.localizedDescription
        }
    }

    func clear() async -> Bool {
        guard !isLoading, !isClearing else { return false }
        let current = UUID()
        revision = current
        isClearing = true
        errorMessage = nil
        do {
            try await repository.clearHistory()
            guard revision == current else { return false }
            items = []
            next = nil
            isEnd = true
            isClearing = false
            return true
        } catch is CancellationError {
            isClearing = false
            return false
        } catch {
            guard revision == current else { return false }
            errorMessage = error.localizedDescription
            isClearing = false
            return false
        }
    }
}
