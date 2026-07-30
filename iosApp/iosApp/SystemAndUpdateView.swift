import SwiftUI

enum SystemExternalLink: String, CaseIterable, Identifiable {
    case discord
    case telegramHydrogen
    case githubIssues
    case sourceCode
    case openSourceLicense

    static let projectLinks: [Self] = [.sourceCode, .openSourceLicense]
    static let communityLinks: [Self] = [.discord, .telegramHydrogen, .githubIssues]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discord:
            return "Discord 频道"
        case .telegramHydrogen:
            return "Telegram 群组 (Hydrogen)"
        case .githubIssues:
            return "GitHub Issues"
        case .sourceCode:
            return "项目源码"
        case .openSourceLicense:
            return "开源许可"
        }
    }

    var detail: String {
        switch self {
        case .discord:
            return "请在 my-other-apps/zhihu-plus-plus 频道讨论"
        case .telegramHydrogen:
            return "另一个知乎客户端 Hydrogen 的群组，也可以在里面讨论知乎++哦"
        case .githubIssues:
            return "欢迎提交 issue 讨论功能和反馈问题"
        case .sourceCode:
            return "查看 Zhihu++ Swift 的完整对应源码"
        case .openSourceLicense:
            return "GNU AGPL v3；本软件不提供任何担保"
        }
    }

    var destination: String {
        switch self {
        case .discord:
            return "https://discord.gg/YCPFZV5XSA"
        case .telegramHydrogen:
            return "https://t.me/+_A1Yto6EpyIyODA1"
        case .githubIssues:
            return "https://github.com/kangyun1994/zhihu-plus-plus-swift/issues"
        case .sourceCode:
            return "https://github.com/kangyun1994/zhihu-plus-plus-swift"
        case .openSourceLicense:
            return "https://github.com/kangyun1994/zhihu-plus-plus-swift/blob/main/LICENSE"
        }
    }

    var validatedURL: URL? {
        ExternalWebURLPolicy.validatedURL(from: destination)
    }
}

struct SystemAndUpdateView: View {
    let openExternalLink: (SystemExternalLink) -> Void

    var body: some View {
        List {
            Section {
                ForEach(SystemExternalLink.projectLinks, content: linkButton)
            } header: {
                Text("项目与许可")
            } footer: {
                Text("本项目基于 zly2006/zhihu-plus-plus 修改，并继续采用 GNU AGPL v3 开源。")
            }

            Section {
                ForEach(SystemExternalLink.communityLinks, content: linkButton)
            } header: {
                Text("交流 & 闲聊")
            } footer: {
                Text("代码和功能反馈请前往GitHub。上边的频道用于用户交流和闲聊，开发者不一定会在线回答问题。")
            }
        }
        .navigationTitle("系统与更新")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(false)
    }

    private func linkButton(_ link: SystemExternalLink) -> some View {
        Button {
            openExternalLink(link)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(link.title)
                        .foregroundStyle(.primary)
                    Text(link.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("将按设置的外部页面打开方式打开")
    }
}
