import Foundation
import SwiftUI

@MainActor
final class PersonHostModel: ObservableObject, Identifiable {
    let id: String
    let routeEntry: PersonRouteEntry
    let store: PersonStore

    private(set) var isDisposed = false

    init(
        routeEntry: PersonRouteEntry,
        accountStore: AccountJSONStore,
        repository: PersonRepository? = nil,
        diagnostics: PerformanceDiagnosticsClient = .disabled,
        onNavigate: @escaping (PersonNavigationIntent) -> Void
    ) {
        id = routeEntry.key.routeInstanceID.uuidString
        self.routeEntry = routeEntry
        store = PersonStore(
            routeEntry: routeEntry,
            repository: repository ?? URLSessionPersonRepository(accountStore: accountStore),
            diagnostics: diagnostics,
            onNavigate: onNavigate
        )
    }

    var navigationTitle: String { store.navigationTitle }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        store.dispose()
    }
}

struct PersonHostView: View {
    @ObservedObject var model: PersonHostModel

    var body: some View {
        PersonNativeView(model: model)
    }
}
