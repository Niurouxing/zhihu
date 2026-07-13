import Foundation
import SwiftUI

struct WriteAnswerRouteDTO: Hashable, Sendable {
    let questionID: Int64
    let questionTitle: String
}

struct ExistingAnswerDraftDTO: Equatable, Sendable {
    let answerID: Int64
    let text: String
    let originalHTML: String
    let tableOfContentsEnabled: Bool
}

enum CreationSystemIntent: Equatable, Sendable {
    case loginRequired
    case riskControlRequired(URL)
}

enum CreationError: LocalizedError, Equatable {
    case loginRequired
    case riskControlRequired
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .loginRequired: return "请先登录后再继续创作"
        case .riskControlRequired: return "需要先完成知乎安全验证"
        case .invalidResponse: return "发布结果无法识别，请刷新内容确认是否成功"
        case let .requestFailed(message): return message
        }
    }

    var systemIntent: CreationSystemIntent? {
        switch self {
        case .loginRequired:
            return .loginRequired
        case .riskControlRequired:
            return .riskControlRequired(URL(string: "https://www.zhihu.com/account/risk_control/")!)
        case .invalidResponse, .requestFailed:
            return nil
        }
    }
}

protocol CreationRepository: Sendable {
    func fetchExistingAnswer(questionID: Int64) async throws -> ExistingAnswerDraftDTO?
    func saveAnswerDraft(questionID: Int64, answerID: Int64?, html: String, tableOfContentsEnabled: Bool) async throws
    func publishAnswer(questionID: Int64, answerID: Int64?, html: String, tableOfContentsEnabled: Bool) async throws -> Int64
    func savePinDraft(title: String, text: String) async throws
    func publishPin(title: String, text: String) async throws -> Int64
}

actor URLSessionCreationRepository: CreationRepository {
    private static let publishURL = URL(string: "https://www.zhihu.com/api/v4/content/publish")!
    private static let pinDraftURL = URL(string: "https://api.zhihu.com/content/drafts")!
    private let client: ZhihuAPIClient

    init(client: ZhihuAPIClient) {
        self.client = client
    }

    func fetchExistingAnswer(questionID: Int64) async throws -> ExistingAnswerDraftDTO? {
        let relationshipURL = URL(
            string: "https://api.zhihu.com/questions/\(questionID)?include=relationship%2Crelationship.my_answer"
        )!
        let relationship = try await requestData(for: relationshipURL)
        guard let answerID = try CreationResponseMapper.myAnswerID(from: relationship) else { return nil }
        let include = "content,editable_content,settings.table_of_contents.enabled"
        let detailURL = URL(string: "https://www.zhihu.com/api/v4/answers/\(answerID)?include=\(include)")!
        let detail = try await requestData(for: detailURL)
        return try CreationResponseMapper.existingAnswer(from: detail, answerID: answerID)
    }

    func saveAnswerDraft(
        questionID: Int64,
        answerID: Int64?,
        html: String,
        tableOfContentsEnabled: Bool
    ) async throws {
        let url = URL(string: "https://www.zhihu.com/api/v4/questions/\(questionID)/draft")!
        let body: [String: Any] = [
            "content": html,
            "draft_type": "normal",
            "delta_time": 30,
            "settings": answerSettings(tableOfContentsEnabled: tableOfContentsEnabled),
        ]
        _ = try await requestData(
            for: url,
            method: "POST",
            json: body,
            referrer: "https://www.zhihu.com/question/\(questionID)/answer/\(answerID.map(String.init) ?? "")"
        )
    }

    func publishAnswer(
        questionID: Int64,
        answerID: Int64?,
        html: String,
        tableOfContentsEnabled: Bool
    ) async throws -> Int64 {
        try await saveAnswerDraft(
            questionID: questionID,
            answerID: answerID,
            html: html,
            tableOfContentsEnabled: tableOfContentsEnabled
        )
        let body: [String: Any] = [
            "action": "answer",
            "data": [
                "publish": ["traceId": publishTraceID()],
                "hybridInfo": [:],
                "draft": compactDictionary([
                    "disabled": 1,
                    "isPublished": answerID != nil,
                    "contentId": answerID.map(String.init),
                ]),
                "extra_info": [
                    "question_id": String(questionID),
                    "publisher": "pc",
                    "include": answerPublishInclude,
                    "pc_business_params": businessParameters(tableOfContentsEnabled),
                ],
                "hybrid": ["html": html],
                "reprint": ["reshipment_settings": "allowed"],
                "commentsPermission": ["comment_permission": "all"],
                "appreciate": ["can_reward": false],
                "publishSwitch": ["draft_type": "normal"],
                "creationStatement": ["disclaimer_status": "close", "disclaimer_type": "none"],
                "commercialReportInfo": ["isReport": 0],
                "toFollower": [:],
                "contentsTables": ["table_of_contents_enabled": tableOfContentsEnabled],
                "thanksInvitation": ["thank_inviter_status": "close", "thank_inviter": ""],
            ],
        ]
        let data = try await requestData(for: Self.publishURL, method: "POST", json: body)
        return try CreationResponseMapper.publishedID(from: data)
    }

    func savePinDraft(title: String, text: String) async throws {
        let body: [String: Any] = [
            "action": "pin",
            "data": pinPayload(title: title, text: text),
        ]
        _ = try await requestData(
            for: Self.pinDraftURL,
            method: "POST",
            json: body,
            referrer: "https://www.zhihu.com/"
        )
    }

    func publishPin(title: String, text: String) async throws -> Int64 {
        let body: [String: Any] = [
            "action": "pin",
            "data": pinPayload(title: title, text: text),
        ]
        let data = try await requestData(
            for: Self.publishURL,
            method: "POST",
            json: body,
            referrer: "https://www.zhihu.com/"
        )
        return try CreationResponseMapper.publishedID(from: data)
    }

    private func pinPayload(title: String, text: String) -> [String: Any] {
        let html = CreationHTMLCompiler.html(from: text)
        return compactDictionary([
            "publish": ["traceId": publishTraceID()],
            "commentsPermission": ["comment_permission": "all"],
            "extra_info": ["view_permission": "all", "publisher": "pc"],
            "draft": ["disabled": 1],
            "title": title.nonBlank.map { ["title": $0] },
            "hybrid": text.nonBlank.map { _ in
                ["html": html, "textLength": CreationHTMLCompiler.textLength(html)]
            },
        ])
    }

    private func requestData(
        for url: URL,
        method: String = "GET",
        json: [String: Any]? = nil,
        referrer: String? = nil
    ) async throws -> Data {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        var headers: [String: String] = [:]
        if body != nil { headers["Content-Type"] = "application/json" }
        if let referrer { headers["Referer"] = referrer }
        do {
            return try await client.data(
                for: url,
                method: method,
                body: body,
                additionalHeaders: headers,
                authentication: .accountRequired
            )
        } catch ZhihuAPIError.authenticationRequired {
            throw CreationError.loginRequired
        } catch ZhihuAPIError.accountUnavailable {
            throw CreationError.loginRequired
        } catch ZhihuAPIError.httpStatus(401) {
            throw CreationError.loginRequired
        } catch ZhihuAPIError.httpStatus(403) {
            throw CreationError.riskControlRequired
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CreationError.requestFailed(error.localizedDescription)
        }
    }

    private func answerSettings(tableOfContentsEnabled: Bool) -> [String: Any] {
        [
            "reshipment_settings": "allowed",
            "comment_permission": "all",
            "can_reward": false,
            "tagline": "",
            "disclaimer_status": "close",
            "disclaimer_type": "none",
            "commercial_report_info": ["is_report": true],
            "push_activity": false,
            "table_of_contents_enabled": tableOfContentsEnabled,
            "thank_inviter_status": "close",
            "thank_inviter": "",
        ]
    }

    private func businessParameters(_ tableOfContentsEnabled: Bool) -> String {
        let value: [String: Any] = [
            "reshipment_settings": "allowed",
            "comment_permission": "all",
            "reward_setting": ["can_reward": false],
            "disclaimer_status": "close",
            "disclaimer_type": "none",
            "commercial_report_info": ["is_report": false],
            "commercial_zhitask_bind_info": NSNull(),
            "is_report": false,
            "table_of_contents_enabled": tableOfContentsEnabled,
            "thank_inviter_status": "close",
            "thank_inviter": "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let result = String(data: data, encoding: .utf8)
        else { return "{}" }
        return result
    }

    private func publishTraceID() -> String {
        "\(Int64(Date().timeIntervalSince1970 * 1_000)),\(UUID().uuidString.lowercased())"
    }
}

enum CreationResponseMapper {
    static func myAnswerID(from data: Data) throws -> Int64? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CreationError.invalidResponse
        }
        let relationship = root["relationship"] as? [String: Any]
        let answer = relationship?["my_answer"] as? [String: Any]
            ?? relationship?["myAnswer"] as? [String: Any]
        guard let answer else { return nil }
        if answer["is_deleted"] as? Bool == true || answer["isDeleted"] as? Bool == true { return nil }
        let value = answer["answer_id"] ?? answer["answerId"]
        return (value as? String).flatMap(Int64.init) ?? (value as? NSNumber)?.int64Value
    }

    static func existingAnswer(from data: Data, answerID: Int64) throws -> ExistingAnswerDraftDTO {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CreationError.invalidResponse
        }
        let html = root["editable_content"] as? String ?? root["editableContent"] as? String ?? root["content"] as? String ?? ""
        let settings = root["settings"] as? [String: Any]
        let toc = settings?["table_of_contents"] as? [String: Any]
            ?? settings?["tableOfContents"] as? [String: Any]
        return ExistingAnswerDraftDTO(
            answerID: answerID,
            text: CreationHTMLCompiler.text(from: html),
            originalHTML: html,
            tableOfContentsEnabled: toc?["enabled"] as? Bool ?? false
        )
    }

    static func publishedID(from data: Data) throws -> Int64 {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CreationError.invalidResponse
        }
        guard root["message"] as? String == "success" else {
            throw CreationError.requestFailed(root["message"] as? String ?? "发布失败")
        }
        guard let payload = root["data"] as? [String: Any],
              let resultText = payload["result"] as? String,
              let resultData = resultText.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        else { throw CreationError.invalidResponse }
        let publish = result["publish"] as? [String: Any]
        let value = publish?["id"] ?? result["id"]
        if let string = value as? String, let id = Int64(string) { return id }
        if let number = value as? NSNumber { return number.int64Value }
        throw CreationError.invalidResponse
    }
}

enum CreationHTMLCompiler {
    static func html(from text: String) -> String {
        text
            .components(separatedBy: "\n\n")
            .map { paragraph in
                "<p>\(escape(paragraph).replacingOccurrences(of: "\n", with: "<br>"))</p>"
            }
            .joined()
    }

    static func text(from html: String) -> String {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.html],
                  documentAttributes: nil
              )
        else { return html }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func textLength(_ html: String) -> Int {
        text(from: html).count
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

@MainActor
final class WriteAnswerNativeStore: ObservableObject {
    @Published var text = ""
    @Published var tableOfContentsEnabled = false
    @Published private(set) var existingAnswerID: Int64?
    @Published private(set) var isLoadingExisting = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var systemIntent: CreationSystemIntent?

    let route: WriteAnswerRouteDTO
    private let repository: CreationRepository
    private var hasLoadedExisting = false
    private var originalDraft: ExistingAnswerDraftDTO?

    init(route: WriteAnswerRouteDTO, repository: CreationRepository) {
        self.route = route
        self.repository = repository
    }

    var canSubmit: Bool { text.nonBlank != nil && !isSubmitting && !isLoadingExisting }

    func loadExistingIfNeeded() async {
        guard !hasLoadedExisting else { return }
        hasLoadedExisting = true
        isLoadingExisting = true
        defer { isLoadingExisting = false }
        do {
            if let draft = try await repository.fetchExistingAnswer(questionID: route.questionID), text.isEmpty {
                existingAnswerID = draft.answerID
                originalDraft = draft
                text = draft.text
                tableOfContentsEnabled = draft.tableOfContentsEnabled
            }
        } catch is CancellationError {
            return
        } catch {
            handle(error)
        }
    }

    func saveDraft() async -> Bool {
        guard canSubmit else { return false }
        isSubmitting = true
        errorMessage = nil
        do {
            try await repository.saveAnswerDraft(
                questionID: route.questionID,
                answerID: existingAnswerID,
                html: contentHTML,
                tableOfContentsEnabled: tableOfContentsEnabled
            )
            isSubmitting = false
            return true
        } catch is CancellationError {
            isSubmitting = false
            return false
        } catch {
            handle(error)
            isSubmitting = false
            return false
        }
    }

    func publish() async -> Int64? {
        guard canSubmit else { return nil }
        isSubmitting = true
        errorMessage = nil
        do {
            let answerID = try await repository.publishAnswer(
                questionID: route.questionID,
                answerID: existingAnswerID,
                html: contentHTML,
                tableOfContentsEnabled: tableOfContentsEnabled
            )
            existingAnswerID = answerID
            isSubmitting = false
            return answerID
        } catch is CancellationError {
            isSubmitting = false
            return nil
        } catch {
            handle(error)
            isSubmitting = false
            return nil
        }
    }

    func consumeSystemIntent() { systemIntent = nil }
    func dismissError() { errorMessage = nil }

    private func handle(_ error: Error) {
        let failure = error as? CreationError ?? .requestFailed(error.localizedDescription)
        errorMessage = failure.localizedDescription
        systemIntent = failure.systemIntent
    }

    private var contentHTML: String {
        if let originalDraft, originalDraft.text == text {
            return originalDraft.originalHTML
        }
        return CreationHTMLCompiler.html(from: text)
    }
}

@MainActor
final class WritePinNativeStore: ObservableObject {
    @Published var title = ""
    @Published var text = ""
    @Published private(set) var isSubmitting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var systemIntent: CreationSystemIntent?

    private let repository: CreationRepository

    init(repository: CreationRepository) {
        self.repository = repository
    }

    var canSubmit: Bool { text.nonBlank != nil && !isSubmitting }

    func saveDraft() async -> Bool {
        guard canSubmit else { return false }
        isSubmitting = true
        errorMessage = nil
        do {
            try await repository.savePinDraft(title: title.trimmingCharacters(in: .whitespacesAndNewlines), text: text)
            isSubmitting = false
            return true
        } catch is CancellationError {
            isSubmitting = false
            return false
        } catch {
            handle(error)
            isSubmitting = false
            return false
        }
    }

    func publish() async -> Int64? {
        guard canSubmit else { return nil }
        isSubmitting = true
        errorMessage = nil
        do {
            let id = try await repository.publishPin(title: title.trimmingCharacters(in: .whitespacesAndNewlines), text: text)
            isSubmitting = false
            return id
        } catch is CancellationError {
            isSubmitting = false
            return nil
        } catch {
            handle(error)
            isSubmitting = false
            return nil
        }
    }

    func consumeSystemIntent() { systemIntent = nil }
    func dismissError() { errorMessage = nil }

    private func handle(_ error: Error) {
        let failure = error as? CreationError ?? .requestFailed(error.localizedDescription)
        errorMessage = failure.localizedDescription
        systemIntent = failure.systemIntent
    }
}

struct WriteAnswerNativeView: View {
    @StateObject private var store: WriteAnswerNativeStore
    @State private var showsSavedConfirmation = false
    let onSystemIntent: (CreationSystemIntent, @escaping () async -> Void) -> Void
    let onPublished: (Int64) -> Void

    init(
        route: WriteAnswerRouteDTO,
        repository: CreationRepository,
        onSystemIntent: @escaping (CreationSystemIntent, @escaping () async -> Void) -> Void,
        onPublished: @escaping (Int64) -> Void
    ) {
        _store = StateObject(wrappedValue: WriteAnswerNativeStore(route: route, repository: repository))
        self.onSystemIntent = onSystemIntent
        self.onPublished = onPublished
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.route.questionTitle).font(.headline).padding(.horizontal)
            TextEditor(text: $store.text)
                .overlay(alignment: .topLeading) {
                    if store.text.isEmpty { Text("请输入回答内容…").foregroundStyle(.secondary).padding(8) }
                }
                .padding(.horizontal, 8)
            Toggle("生成目录", isOn: $store.tableOfContentsEnabled)
                .padding(.horizontal)
        }
        .navigationTitle(store.existingAnswerID == nil ? "写回答" : "编辑回答")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("发布") {
                    Task { if let id = await store.publish() { onPublished(id) } }
                }
                .disabled(!store.canSubmit)
            }
            ToolbarItem(placement: .bottomBar) {
                Button { Task { showsSavedConfirmation = await store.saveDraft() } } label: {
                    Label("保存草稿", systemImage: "tray.and.arrow.down")
                }
                .disabled(!store.canSubmit)
            }
        }
        .overlay { if store.isLoadingExisting { ProgressView("正在加载已有回答") } }
        .alert("保存成功", isPresented: $showsSavedConfirmation) { Button("好") {} } message: { Text("草稿已保存") }
        .alert("操作失败", isPresented: errorBinding) { Button("好") {} } message: { Text(store.errorMessage ?? "未知错误") }
        .onChange(of: store.systemIntent) { intent in
            guard let intent else { return }
            onSystemIntent(intent) {
                if let id = await store.publish() { onPublished(id) }
            }
            store.consumeSystemIntent()
        }
        .task { await store.loadExistingIfNeeded() }
        .accessibilityIdentifier("write_answer_native")
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.dismissError() } }
        )
    }
}

struct WritePinNativeView: View {
    @StateObject private var store: WritePinNativeStore
    @State private var showsSavedConfirmation = false
    let onSystemIntent: (CreationSystemIntent, @escaping () async -> Void) -> Void
    let onPublished: (Int64) -> Void

    init(
        repository: CreationRepository,
        onSystemIntent: @escaping (CreationSystemIntent, @escaping () async -> Void) -> Void,
        onPublished: @escaping (Int64) -> Void
    ) {
        _store = StateObject(wrappedValue: WritePinNativeStore(repository: repository))
        self.onSystemIntent = onSystemIntent
        self.onPublished = onPublished
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("标题（可选）", text: $store.title)
                .font(.title2.bold())
                .textFieldStyle(.plain)
                .padding(.horizontal)
            Divider().padding(.horizontal)
            TextEditor(text: $store.text)
                .overlay(alignment: .topLeading) {
                    if store.text.isEmpty { Text("分享你此刻的想法…").foregroundStyle(.secondary).padding(8) }
                }
                .padding(.horizontal, 8)
        }
        .navigationTitle("发想法")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("发布") { Task { if let id = await store.publish() { onPublished(id) } } }
                    .disabled(!store.canSubmit)
            }
            ToolbarItem(placement: .bottomBar) {
                Button { Task { showsSavedConfirmation = await store.saveDraft() } } label: {
                    Label("保存草稿", systemImage: "tray.and.arrow.down")
                }
                .disabled(!store.canSubmit)
            }
        }
        .alert("保存成功", isPresented: $showsSavedConfirmation) { Button("好") {} } message: { Text("草稿已保存") }
        .alert("操作失败", isPresented: errorBinding) { Button("好") {} } message: { Text(store.errorMessage ?? "未知错误") }
        .onChange(of: store.systemIntent) { intent in
            guard let intent else { return }
            onSystemIntent(intent) {
                if let id = await store.publish() { onPublished(id) }
            }
            store.consumeSystemIntent()
        }
        .accessibilityIdentifier("write_pin_native")
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.dismissError() } }
        )
    }
}

private func compactDictionary(_ values: [String: Any?]) -> [String: Any] {
    values.reduce(into: [:]) { result, item in
        if let value = item.value { result[item.key] = value }
    }
}

private let answerPublishInclude =
    "is_visible,paid_info,paid_info_content,has_column,admin_closed_comment,reward_info,annotation_action,annotation_detail,collapse_reason,is_normal,is_sticky,collapsed_by,suggest_edit,comment_count,thanks_count,favlists_count,can_comment,content,editable_content,voteup_count,reshipment_settings,comment_permission,created_time,updated_time,review_info,relevant_info,question,excerpt,attachment,content_source,is_labeled,endorsements,reaction_instruction,ip_info,relationship.is_authorized,voting,is_thanked,is_author,is_nothelp,is_favorited;author.vip_info,kvip_info,badge[*].topics;settings.table_of_contents.enabled"

private extension String {
    var nonBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
