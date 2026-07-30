import SwiftUI
import UIKit

enum SideStoreUpdateSource {
    static let sourceURLString =
        "https://raw.githubusercontent.com/kangyun1994/zhihu-plus-plus-swift/main/sidestore-source.json"
    static let sourceURL = URL(string: sourceURLString)!
    static let addSourceURL: URL = {
        let unreservedCharacters = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-._~"))
        let encodedSourceURL = sourceURLString.addingPercentEncoding(
            withAllowedCharacters: unreservedCharacters
        )!
        return URL(string: "sidestore://source?url=\(encodedSourceURL)")!
    }()
}

@available(iOS 16.0, *)
struct NativeSettingsView: View {
    @ObservedObject var preferences: NativeShellPreferences
    @ObservedObject var notificationPreferences: NativeNotificationPreferences
    @ObservedObject var systemSettings: NativeSystemIntegrationSettings
    @ObservedObject var appLock: NativeAppLockCoordinator
    @ObservedObject var performanceDiagnostics: NativePerformanceDiagnosticsController
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    let setAppLock: (Bool) -> Void
    @AppStorage("pinAnswerDate") private var pinAnswerDate = false

    var body: some View {
        Form {
            Section("外观") {
                Picker("显示模式", selection: themeBinding) {
                    ForEach(NativeThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Section {
                settingSlider(
                    title: "正文字号",
                    value: fontSizeBinding,
                    range: 80 ... 150,
                    step: 5,
                    valueText: "\(preferences.contentFontSizePercent)%"
                )
                settingSlider(
                    title: "行间距",
                    value: lineHeightBinding,
                    range: 100 ... 300,
                    step: 10,
                    valueText: String(format: "%.1f 倍", Double(preferences.contentLineHeightPercent) / 100)
                )
                settingSlider(
                    title: "段落间距",
                    value: blockSpacingBinding,
                    range: 0 ... 300,
                    step: 10,
                    valueText: "\(preferences.contentBlockSpacingPercent)%"
                )
                Toggle("将回答发布时间显示在正文顶部", isOn: $pinAnswerDate)
            } header: {
                Text("阅读排版")
            } footer: {
                Text("字号会继续响应系统的动态字体；IP 属地始终显示在正文末尾。")
            }

            Section {
                Picker("推荐源", selection: recommendationSourceBinding) {
                    ForEach(HomeRecommendationSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                Stepper(
                    value: refreshTargetItemCountBinding,
                    in: HomeRecommendationRefreshConfiguration.targetItemRange
                ) {
                    LabeledContent(
                        "每次刷新",
                        value: "\(preferences.homeRefreshTargetItemCount) 条"
                    )
                }
                Picker("显示密度", selection: feedDensityBinding) {
                    ForEach(NativeFeedDensity.allCases) { density in
                        Text(density.title).tag(density)
                    }
                }
                Stepper(value: feedExcerptLinesBinding, in: 1 ... 5) {
                    LabeledContent("正文摘要", value: "\(preferences.feedExcerptLines) 行")
                }
                Toggle("显示缩略图", isOn: feedThumbnailsBinding)
                NavigationLink {
                    BlockedQuestionAuthorsView(store: questionAuthorBlocklist)
                } label: {
                    LabeledContent(
                        "已屏蔽的提问者",
                        value: "\(questionAuthorBlocklist.entries.count)"
                    )
                }
            } header: {
                Text("信息流")
            } footer: {
                Text("推荐页每次请求 10 条并自动补足目标数量；App 与 Web 推荐都会过滤带标记的推广内容。Web 推荐需要登录。")
            }

            Section("搜索") {
                Toggle("显示热搜", isOn: searchHotBinding)
                Toggle("保存并显示搜索历史", isOn: searchHistoryBinding)
            }

            Section {
                Toggle("再次点击当前标签回到顶部或刷新", isOn: topLevelReselectBinding)
                Toggle("触觉反馈", isOn: hapticsEnabledBinding)
                Picker("反馈力度", selection: hapticStrengthBinding) {
                    ForEach(NativeHapticStrength.allCases) { strength in
                        Text(strength.title).tag(strength)
                    }
                }
                .disabled(!preferences.hapticsEnabled)
                Picker("默认分享动作", selection: shareActionBinding) {
                    ForEach(NativeDefaultShareAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                Picker("外部页面打开方式", selection: externalPageOpeningModeBinding) {
                    ForEach(NativeExternalPageOpeningMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } header: {
                Text("交互")
            } footer: {
                Text("再次点击当前标签时：列表不在顶部则先回到顶部；已经在顶部或连续再次点击则刷新。")
            }

            Section("App 布局") {
                Picker("启动时打开", selection: startTabBinding) {
                    ForEach(NativeAppTab.fixedBottomBarTabs) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
            }

            Section("通知") {
                NavigationLink(value: NativeShellRoute.notificationSettings) {
                    Text("应用内通知")
                }
            }

            Section("更新") {
                Link(destination: SideStoreUpdateSource.addSourceURL) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("添加 SideStore 更新源")
                            .foregroundStyle(.primary)
                        Text("首次添加后可接收 GitHub Release 更新")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("将在 SideStore 中打开")
            }

            Section("系统") {
                if appLock.settingPresentation.isVisible {
                    Toggle("App 锁", isOn: Binding(
                        get: { systemSettings.appLock == true },
                        set: setAppLock
                    ))
                    .disabled(!appLock.settingPresentation.canEnable && systemSettings.appLock != true)
                }
                NavigationLink(value: NativeShellRoute.systemAndUpdate) {
                    Text("系统与更新")
                }
            }

            Section {
                Toggle("性能诊断日志", isOn: Binding(
                    get: { performanceDiagnostics.isEnabled },
                    set: performanceDiagnostics.setEnabled
                ))
                NavigationLink {
                    PerformanceDiagnosticsLogsView(controller: performanceDiagnostics)
                } label: {
                    if let latest = performanceDiagnostics.logs.first {
                        LabeledContent(
                            "诊断日志",
                            value: "\(latest.modifiedAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: latest.byteCount, countStyle: .file))"
                        )
                    } else {
                        LabeledContent("诊断日志", value: "暂无")
                    }
                }
            } header: {
                Text("诊断")
            } footer: {
                Text("仅记录脱敏后的性能元数据，不记录账号凭据、正文、评论或搜索词。每次启动或重新开启会创建新会话，单份最多 15 MB，保留最近 5 份。")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await performanceDiagnostics.refreshLogs() }
    }

    private var themeBinding: Binding<NativeThemeMode> {
        Binding(get: { preferences.themeMode }, set: preferences.setThemeMode)
    }

    private var startTabBinding: Binding<NativeAppTab> {
        Binding(get: { preferences.startTab }, set: preferences.setStartTab)
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { Double(preferences.contentFontSizePercent) },
            set: { preferences.setContentFontSizePercent(Int($0.rounded())) }
        )
    }

    private var lineHeightBinding: Binding<Double> {
        Binding(
            get: { Double(preferences.contentLineHeightPercent) },
            set: { preferences.setContentLineHeightPercent(Int($0.rounded())) }
        )
    }

    private var blockSpacingBinding: Binding<Double> {
        Binding(
            get: { Double(preferences.contentBlockSpacingPercent) },
            set: { preferences.setContentBlockSpacingPercent(Int($0.rounded())) }
        )
    }

    private var feedDensityBinding: Binding<NativeFeedDensity> {
        Binding(get: { preferences.feedDensity }, set: preferences.setFeedDensity)
    }

    private var recommendationSourceBinding: Binding<HomeRecommendationSource> {
        Binding(
            get: { preferences.homeRecommendationSource },
            set: preferences.setHomeRecommendationSource
        )
    }

    private var refreshTargetItemCountBinding: Binding<Int> {
        Binding(
            get: { preferences.homeRefreshTargetItemCount },
            set: preferences.setHomeRefreshTargetItemCount
        )
    }

    private var feedExcerptLinesBinding: Binding<Int> {
        Binding(get: { preferences.feedExcerptLines }, set: preferences.setFeedExcerptLines)
    }

    private var feedThumbnailsBinding: Binding<Bool> {
        Binding(get: { preferences.showsFeedThumbnails }, set: preferences.setShowsFeedThumbnails)
    }

    private var searchHotBinding: Binding<Bool> {
        Binding(get: { preferences.showsSearchHotSearch }, set: preferences.setShowsSearchHotSearch)
    }

    private var searchHistoryBinding: Binding<Bool> {
        Binding(get: { preferences.showsSearchHistory }, set: preferences.setShowsSearchHistory)
    }

    private var topLevelReselectBinding: Binding<Bool> {
        Binding(get: { preferences.topLevelReselectEnabled }, set: preferences.setTopLevelReselectEnabled)
    }

    private var hapticsEnabledBinding: Binding<Bool> {
        Binding(get: { preferences.hapticsEnabled }, set: preferences.setHapticsEnabled)
    }

    private var hapticStrengthBinding: Binding<NativeHapticStrength> {
        Binding(
            get: { preferences.hapticStrength },
            set: previewAndSetHapticStrength
        )
    }

    private func previewAndSetHapticStrength(_ strength: NativeHapticStrength) {
        guard NativeHapticStrengthSelectionPolicy.shouldPreview(
            current: preferences.hapticStrength,
            selected: strength,
            isHapticsEnabled: preferences.hapticsEnabled
        ) else { return }
        preferences.setHapticStrength(strength)
        hapticFeedback.previewStrength(strength)
    }

    private var shareActionBinding: Binding<NativeDefaultShareAction> {
        Binding(get: { preferences.defaultShareAction }, set: preferences.setDefaultShareAction)
    }

    private var externalPageOpeningModeBinding: Binding<NativeExternalPageOpeningMode> {
        Binding(
            get: { preferences.externalPageOpeningMode },
            set: preferences.setExternalPageOpeningMode
        )
    }

    private func settingSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(title, value: valueText)
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }
}

@available(iOS 16.0, *)
private struct PerformanceDiagnosticsLogsView: View {
    @ObservedObject var controller: NativePerformanceDiagnosticsController
    @State private var sharePresentation: PerformanceDiagnosticSharePresentation?
    @State private var confirmsDeleteAll = false

    var body: some View {
        List {
            if controller.logs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("暂无诊断日志")
                    Text("开启诊断后，新的性能会话会显示在这里。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(controller.logs) { log in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(log.modifiedAt.formatted(date: .abbreviated, time: .standard))
                            Text(ByteCountFormatter.string(fromByteCount: log.byteCount, countStyle: .file))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task {
                                guard let url = await controller.shareURL(for: log) else { return }
                                sharePresentation = .init(url: url)
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("导出诊断日志")
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await controller.delete(log) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !controller.logs.isEmpty {
                Button("全部删除", role: .destructive) { confirmsDeleteAll = true }
            }
        }
        .confirmationDialog("删除全部诊断日志？", isPresented: $confirmsDeleteAll) {
            Button("全部删除", role: .destructive) {
                Task { await controller.deleteAll() }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $sharePresentation) { presentation in
            PerformanceDiagnosticsShareSheet(items: [presentation.url])
        }
        .task { await controller.refreshLogs() }
    }
}

private struct PerformanceDiagnosticSharePresentation: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct PerformanceDiagnosticsShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct BlockedQuestionAuthorsView: View {
    @ObservedObject var store: QuestionAuthorBlocklistStore

    var body: some View {
        List {
            if store.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("暂无已屏蔽的提问者")
                        .foregroundStyle(.secondary)
                    Text("在首页、关注、热榜或搜索结果中长按内容，可屏蔽该问题的提问者。")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .listRowSeparator(.hidden)
            } else {
                ForEach(store.entries) { author in
                    HStack(spacing: 12) {
                        AsyncImage(url: author.avatarURL) { phase in
                            if case let .success(image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 3) {
                            Text(author.displayName)
                                .foregroundStyle(.primary)
                            Text("不再显示其提出的问题")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Button("解除") {
                            store.unblock(memberID: author.memberID)
                        }
                        .buttonStyle(.borderless)
                    }
                    .swipeActions {
                        Button("解除屏蔽") {
                            store.unblock(memberID: author.memberID)
                        }
                        .tint(.accentColor)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(author.displayName)，已屏蔽")
                    .accessibilityAction(named: "解除屏蔽") {
                        store.unblock(memberID: author.memberID)
                    }
                }
            }
        }
        .navigationTitle("已屏蔽的提问者")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NativeNotificationSettingsView: View {
    @ObservedObject var preferences: NativeNotificationPreferences

    var body: some View {
        Form {
            Section("应用内通知行为") {
                Toggle("打开通知后自动已读", isOn: autoReadBinding)
                Toggle("显示未读标记", isOn: unreadBadgeBinding)
            }

            Section {
                ForEach(NativeNotificationType.allCases) { type in
                    Toggle(type.title, isOn: displayBinding(for: type))
                }
            } header: {
                Text("应用内通知显示")
            } footer: {
                Text("选择在应用内通知页面显示哪些通知。邀请回答默认关闭，其他未知类型仍会显示。")
            }
        }
        .navigationTitle("通知设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var autoReadBinding: Binding<Bool> {
        Binding(get: { preferences.autoMarkAsRead }, set: preferences.setAutoMarkAsRead)
    }

    private var unreadBadgeBinding: Binding<Bool> {
        Binding(get: { preferences.showsUnreadBadge }, set: preferences.setShowsUnreadBadge)
    }

    private func displayBinding(for type: NativeNotificationType) -> Binding<Bool> {
        Binding(
            get: { preferences.displayInApp[type] ?? type.defaultDisplayInApp },
            set: { preferences.setDisplayInApp($0, for: type) }
        )
    }
}
