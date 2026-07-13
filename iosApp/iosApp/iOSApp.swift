import SwiftUI

@main
@MainActor
struct ZhihuPlusPlusApp: App {
    @StateObject private var hostModel = HostModel()

    var body: some Scene {
        WindowGroup { AppHostView(hostModel: hostModel) }
    }
}
