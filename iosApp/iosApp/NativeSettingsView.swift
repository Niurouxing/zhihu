import SwiftUI

@available(iOS 16.0, *)
struct NativeSettingsView: View {
    @ObservedObject var preferences: NativeShellPreferences
    @ObservedObject var notificationPreferences: NativeNotificationPreferences
    @ObservedObject var systemSettings: NativeSystemIntegrationSettings
    @ObservedObject var appLock: NativeAppLockCoordinator
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

            Section("信息流") {
                Picker("显示密度", selection: feedDensityBinding) {
                    ForEach(NativeFeedDensity.allCases) { density in
                        Text(density.title).tag(density)
                    }
                }
                Stepper(value: feedExcerptLinesBinding, in: 1 ... 5) {
                    LabeledContent("正文摘要", value: "\(preferences.feedExcerptLines) 行")
                }
                Toggle("显示缩略图", isOn: feedThumbnailsBinding)
            }

            Section("搜索") {
                Toggle("显示热搜", isOn: searchHotBinding)
                Toggle("保存并显示搜索历史", isOn: searchHistoryBinding)
            }

            Section {
                Toggle("左右滑动切换回答", isOn: answerSwitchBinding)
                Toggle("再次点击当前标签回到顶部或刷新", isOn: topLevelReselectBinding)
                Picker("默认分享动作", selection: shareActionBinding) {
                    ForEach(NativeDefaultShareAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
            } header: {
                Text("交互")
            } footer: {
                Text("再次点击当前标签时：列表不在顶部则先回到顶部；已经在顶部或连续再次点击则刷新。")
            }

            Section {
                NavigationLink {
                    NativeTabConfigurationView(preferences: preferences)
                } label: {
                    LabeledContent("底部标签", value: "\(preferences.selectedTabs.count) 个")
                }
                Picker("启动时打开", selection: startTabBinding) {
                    ForEach(preferences.selectedTabs) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                if #available(iOS 26.0, *) {
                    Toggle("滚动时自动收起标签栏", isOn: autoHideBinding)
                }
            } header: {
                Text("App 布局")
            } footer: {
                Text("每个标签保留各自的浏览位置与返回记录。账号入口位于主页头像时，底部不会保留空的账号标签。")
            }

            Section("通知") {
                NavigationLink(value: NativeShellRoute.notificationSettings) {
                    Label("应用内通知", systemImage: "bell.badge")
                }
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
                    Label("系统与更新", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var themeBinding: Binding<NativeThemeMode> {
        Binding(get: { preferences.themeMode }, set: preferences.setThemeMode)
    }

    private var startTabBinding: Binding<NativeAppTab> {
        Binding(get: { preferences.startTab }, set: preferences.setStartTab)
    }

    private var autoHideBinding: Binding<Bool> {
        Binding(get: { preferences.autoHideTabBar }, set: preferences.setAutoHideTabBar)
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

    private var answerSwitchBinding: Binding<Bool> {
        Binding(get: { preferences.answerSwitchEnabled }, set: preferences.setAnswerSwitchEnabled)
    }

    private var topLevelReselectBinding: Binding<Bool> {
        Binding(get: { preferences.topLevelReselectEnabled }, set: preferences.setTopLevelReselectEnabled)
    }

    private var shareActionBinding: Binding<NativeDefaultShareAction> {
        Binding(get: { preferences.defaultShareAction }, set: preferences.setDefaultShareAction)
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

struct NativeTabConfigurationView: View {
    @ObservedObject var preferences: NativeShellPreferences

    var body: some View {
        List {
            Section {
                ForEach(availableTabs) { tab in
                    Button {
                        preferences.setTabEnabled(tab, enabled: !preferences.selectedTabs.contains(tab))
                    } label: {
                        HStack {
                            Label(tab.title, systemImage: tab.systemImage).foregroundStyle(.primary)
                            Spacer()
                            if preferences.selectedTabs.contains(tab) {
                                Image(systemName: "checkmark").foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(preferences.selectedTabs.contains(tab) && preferences.selectedTabs.count <= 3)
                }
            } header: {
                Text("显示的标签")
            } footer: {
                Text("至少保留三个标签。主页头像承担账号入口时，账号标签会从底部实际移除。")
            }

            Section("排列顺序") {
                ForEach(preferences.selectedTabs) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                }
                .onMove(perform: preferences.moveTabs)
            }
        }
        .navigationTitle("底部标签")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private var availableTabs: [NativeAppTab] {
        if preferences.accountInHome, preferences.selectedTabs.contains(.home) {
            return NativeAppTab.allCases.filter { $0 != .account }
        }
        return NativeAppTab.allCases
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
