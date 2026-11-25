import Foundation
import Testing
@testable import PPTReader

/// 按任务选择模型：回退规则，以及按任务取到的连接、Key、截图开关和上下文预算。
///
/// 每个测试用单独的 UserDefaults。注意：默认的第一个服务商沿用旧版的钥匙串条目 "api-key"，
/// 删除服务商会删掉它的钥匙串条目，所以测试里只删除测试自己添加的服务商。
@Suite("按任务选择模型")
@MainActor
struct TaskModelTests {
    private func withSettings(_ body: (AppSettings, UserDefaults) throws -> Void) rethrows {
        let name = "PPTReaderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.model = "deepseek-chat"
        try body(settings, defaults)
    }

    /// 添加一个服务商，但不切换过去（`addProvider` 会切换）。
    private func add(_ preset: ProviderPreset, to settings: AppSettings, model: String = "",
                     change: (inout APIProvider) -> Void = { _ in }) -> APIProvider {
        let active = settings.activeProviderID
        let provider = settings.addProvider(preset)!
        settings.activeProviderID = active
        settings.updateProvider(provider.id) {
            $0.model = model
            change(&$0)
        }
        return settings.providers.first { $0.id == provider.id }!
    }

    /// 跟随讲解与提问：连接相同，思考参数按任务的上限封顶（`AppSettings.capped`）。
    private func expectFollowsChat(_ settings: AppSettings, _ task: ModelTask, sourceLocation: SourceLocation = #_sourceLocation) {
        let config = settings.connection(for: task), chat = AppSettings.capped(settings.connection, for: task)
        #expect(config.providerID == chat.providerID && config.model == chat.model && config.baseURL == chat.baseURL
                && config.kind == chat.kind && config.thinking == chat.thinking && config.reasoningEffort == chat.reasoningEffort,
                sourceLocation: sourceLocation)
    }

    @Test("跟随讲解与提问时，后台任务的思考强度有上限：整理和判断最高“低”，补充要点最高“高”；单独选的模型不封顶")
    func followingTasksCapEffort() {
        withSettings { settings, _ in
            let kimi = settings.addProvider(.kimiCode)!
            settings.updateProvider(kimi.id) {
                $0.model = "k3.1-pro"
                $0.reasoningEffort = .max
            }
            #expect(settings.connection(for: .chat).reasoningEffort == .max)
            #expect(settings.connection(for: .autoExplain).reasoningEffort == .max)
            #expect(settings.connection(for: .roadmap).reasoningEffort == .max)
            #expect(settings.connection(for: .record).reasoningEffort == .low)
            #expect(settings.connection(for: .lectureDecks).reasoningEffort == .low)
            #expect(settings.connection(for: .lectureTranscript).reasoningEffort == .low)
            #expect(settings.connection(for: .lectureSupplements).reasoningEffort == .high)
            // “默认”交给模型时也封顶（推理模型默认往往很高）
            settings.updateProvider(kimi.id) { $0.reasoningEffort = .auto }
            #expect(settings.connection(for: .chat).reasoningEffort == .auto)
            #expect(settings.connection(for: .lectureSupplements).reasoningEffort == .high)
            // 本来就低的不会被提高
            settings.updateProvider(kimi.id) { $0.reasoningEffort = .low }
            #expect(settings.connection(for: .lectureSupplements).reasoningEffort == .low)
            // 单独选了模型的任务按用户的设置
            settings.updateProvider(kimi.id) { $0.reasoningEffort = .max }
            settings.setTaskModel(ModelRef(providerID: kimi.id, model: "k3.1-pro"), for: .lectureTranscript)
            #expect(settings.connection(for: .lectureTranscript).reasoningEffort == .max)
        }
    }

    @Test("上限是“低”的任务跟随时关掉 DeepSeek 的深度思考；讲解照常")
    func followingTasksDisableThinking() {
        withSettings { settings, _ in
            settings.thinking = true
            #expect(settings.connection(for: .chat).thinking)
            #expect(!settings.connection(for: .lectureTranscript).thinking)
            #expect(!settings.connection(for: .record).thinking)
            #expect(settings.connection(for: .lectureSupplements).thinking)
        }
    }

    @Test("封顶后落到服务商支持的档位；不支持调节的服务商原样返回")
    func cappedToSupportedLevel() {
        #expect(ReasoningEffort.capped(.max, at: .medium, supported: ProviderPreset.kimiCode.reasoningEfforts) == .low)
        #expect(ReasoningEffort.capped(.xhigh, at: .high, supported: ProviderPreset.openRouter.reasoningEfforts) == .high)
        #expect(ReasoningEffort.capped(.none, at: .low, supported: ProviderPreset.openRouter.reasoningEfforts) == .none)
        #expect(ReasoningEffort.capped(.max, at: .low, supported: []) == .max)
    }

    @Test("什么都不改时，所有任务都跟随讲解与提问")
    func defaultsFollowChat() {
        withSettings { settings, _ in
            _ = add(.openRouter, to: settings, model: "openai/gpt")
            #expect(settings.taskModels.isEmpty)
            for task in ModelTask.allCases { expectFollowsChat(settings, task) }
        }
    }

    @Test("单独选了模型的任务用那个服务商的地址、类型和模型，其他任务不受影响")
    func taskUsesItsProvider() {
        withSettings { settings, _ in
            let other = add(.openRouter, to: settings, model: "anthropic/claude")
            settings.setTaskModel(ModelRef(providerID: other.id, model: "google/gemini-flash"), for: .record)
            let config = settings.connection(for: .record)
            #expect(config.providerID == other.id)
            #expect(config.kind == .openRouter && config.baseURL == ProviderPreset.openRouter.baseURL)
            #expect(config.model == "google/gemini-flash")
            expectFollowsChat(settings, .autoExplain)
            expectFollowsChat(settings, .chat)
        }
    }

    @Test("思考参数可以按任务覆盖，没覆盖时跟随服务商")
    func thinkingOverrides() {
        withSettings { settings, _ in
            let other = add(.openRouter, to: settings, model: "m") { $0.reasoningEffort = .high }
            settings.setTaskModel(ModelRef(providerID: other.id, model: "m"), for: .record)
            #expect(settings.connection(for: .record).reasoningEffort == .high)
            settings.setTaskModel(ModelRef(providerID: other.id, model: "m", reasoningEffort: .low), for: .record)
            #expect(settings.connection(for: .record).reasoningEffort == .low)

            // 同一个 DeepSeek 服务商：讲解开着深度思考，自动讲解单独关掉
            settings.thinking = true
            settings.setTaskModel(ModelRef(providerID: settings.activeProviderID, model: "deepseek-chat", thinking: false), for: .autoExplain)
            #expect(settings.connection(for: .autoExplain).thinking == false)
            #expect(settings.connection.thinking == true)
        }
    }

    @Test("没填模型时跟随讲解与提问")
    func emptyModelFollowsChat() {
        withSettings { settings, _ in
            let other = add(.openRouter, to: settings)
            settings.setTaskModel(ModelRef(providerID: other.id, model: "  "), for: .record)
            expectFollowsChat(settings, .record)
        }
    }

    @Test("讲解与提问本身不能单独设置")
    func chatIsNotConfigurable() {
        withSettings { settings, _ in
            let other = add(.openRouter, to: settings, model: "m")
            settings.setTaskModel(ModelRef(providerID: other.id, model: "m"), for: .chat)
            #expect(settings.taskModels[.chat] == nil)
            expectFollowsChat(settings, .chat)
        }
    }

    @Test("删掉任务用的服务商后改回跟随，并记下原来的服务商名；重新选择后提示消失")
    func deletedProviderFallsBack() {
        withSettings { settings, _ in
            let other = add(.openRouter, to: settings, model: "m")
            settings.setTaskModel(ModelRef(providerID: other.id, model: "m"), for: .record)
            settings.setTaskModel(ModelRef(providerID: settings.activeProviderID, model: "deepseek-chat"), for: .autoExplain)
            settings.removeProvider(other.id)
            #expect(settings.taskModels[.record] == nil)
            #expect(settings.taskFallbacks[.record] == other.name)
            // 用别的服务商的任务不受影响
            #expect(settings.taskModels[.autoExplain] != nil && settings.taskFallbacks[.autoExplain] == nil)
            expectFollowsChat(settings, .record)

            settings.setTaskModel(nil, for: .record)
            #expect(settings.taskFallbacks[.record] == nil)
        }
    }

    @Test("保存后重新读取仍在；认不出的任务和不存在的服务商跳过")
    func persists() throws {
        try withSettings { settings, defaults in
            let other = add(.openRouter, to: settings, model: "m")
            let ref = ModelRef(providerID: other.id, model: "small", reasoningEffort: .low)
            settings.setTaskModel(ref, for: .record)
            #expect(AppSettings(defaults: defaults).taskModels == [.record: ref])

            let stored: [String: ModelRef] = [
                "record": ref,
                "someFutureTask": ref,
                "autoExplain": ModelRef(providerID: UUID(), model: "gone"),
            ]
            defaults.set(try JSONEncoder().encode(stored), forKey: "api.taskModels")
            #expect(AppSettings(defaults: defaults).taskModels == [.record: ref])
        }
    }

    @Test("上下文预算按任务用的服务商和模型计算")
    func contextBudgetPerProvider() {
        withSettings { settings, _ in
            let other = add(.openRouter, to: settings, model: "small") { $0.contextWindow = 32_000 }
            settings.contextBudgetPercent = 0.5
            #expect(settings.contextTokenBudget(other.id, "small") == 16_000)
            #expect(settings.contextTokenBudget == AppSettings.defaultContextWindow / 2)
        }
    }

    @Test("截图按模型判断：拒绝过图片的、模型列表说不支持图片的都不发")
    func imagesPerModel() {
        withSettings { settings, _ in
            let chat = settings.activeProviderID
            settings.sendPageImage = true
            settings.markNoVision("text-only")
            #expect(!settings.sendsImages(chat, "text-only"))
            #expect(settings.sendsImages(chat, "deepseek-chat"))

            let router = add(.openRouter, to: settings, model: "m") {
                $0.modelInfo = ["deepseek/deepseek-v4": ModelInfo(acceptsImages: false), "openai/gpt": ModelInfo(acceptsImages: true)]
            }
            #expect(!settings.sendsImages(router.id, "deepseek/deepseek-v4"))
            #expect(settings.sendsImages(router.id, "openai/gpt"))
            // 列表里没有的模型照常发，出错时再记下
            #expect(settings.sendsImages(router.id, "unknown/model"))

            settings.sendPageImage = false
            #expect(!settings.sendsImages(chat, "deepseek-chat"))
        }
    }

    @Test("max_tokens 不超过模型列表报告的上限")
    func outputCap() {
        withSettings { settings, _ in
            let router = add(.openRouter, to: settings, model: "m") { $0.modelInfo = ["small": ModelInfo(maxOutput: 4_096)] }
            #expect(settings.outputCap(router.id, "small", limit: 32_768) == 4_096)
            #expect(settings.outputCap(router.id, "small", limit: 2_000) == 2_000)
            #expect(settings.outputCap(router.id, "other", limit: 32_768) == 32_768)
        }
    }

    @Test("连接带上服务商的隐私设置")
    func privacyInConnection() {
        withSettings { settings, _ in
            let router = add(.openRouter, to: settings, model: "m") { $0.privacy = .zeroRetention }
            settings.setTaskModel(ModelRef(providerID: router.id, model: "m"), for: .record)
            #expect(settings.connection(for: .record).privacy == .zeroRetention)
            #expect(settings.connection.privacy == .any)
        }
    }

    @Test("能不能发请求，看任务用的服务商有没有 Key")
    func keyPerTask() {
        withSettings { settings, _ in
            let local = add(.custom, to: settings, model: "llama") { $0.baseURL = "http://localhost:11434/v1" }
            settings.setTaskModel(ModelRef(providerID: local.id, model: "llama"), for: .record)
            #expect(settings.canRequest(.record))
            // 没有通过环境变量提供 Key 时，远程服务商没有 Key 就不能发请求
            guard ProcessInfo.processInfo.environment["PPTREADER_API_KEY"] == nil else { return }
            let remote = add(.openRouter, to: settings, model: "m")
            settings.setTaskModel(ModelRef(providerID: remote.id, model: "m"), for: .autoExplain)
            #expect(!settings.canRequest(.autoExplain))
            #expect(!settings.hasKey(for: remote.id))
        }
    }

    @Test("从菜单给任务选模型，记进那个服务商的最近使用")
    func chooseTaskModel() {
        withSettings { settings, _ in
            let other = add(.openRouter, to: settings, model: "m")
            settings.setTaskModel(ModelRef(providerID: other.id, model: "m"), for: .record)
            settings.chooseTaskModel("google/gemini-flash", for: .record)
            #expect(settings.taskModels[.record]?.model == "google/gemini-flash")
            #expect(settings.providers.first { $0.id == other.id }?.recentModels.first == "google/gemini-flash")
            #expect(settings.activeProvider.recentModels.isEmpty)
        }
    }
}

/// 统计按任务记用量。
@Suite("按任务统计")
struct TaskStatsTests {
    @Test("后台任务只计用量，不算提问次数；模型和任务的用量都记上")
    func addReply() {
        var log = StatsLog()
        let date = Date()
        log.addReply(deck: "/a.pdf", page: nil, model: "small", kind: .housekeeping, task: .record,
                     usage: TokenUsage(prompt: 900, completion: 100), at: date)
        log.addReply(deck: "/a.pdf", page: 3, model: "big", kind: .explain, task: .autoExplain,
                     usage: TokenUsage(prompt: 5_000, completion: 800), at: date)
        let day = log.days[StatsLog.key(for: date)]!
        #expect(day.decks["/a.pdf"]?.explains == 1 && day.decks["/a.pdf"]?.questions == 0)
        #expect(day.tasks["record"]?.requests == 1 && day.tasks["record"]?.total == 1_000)
        #expect(day.tasks["autoExplain"]?.prompt == 5_000)
        #expect(day.models["small"]?.total == 1_000)
    }

    @Test("旧的统计文件没有任务用量，照样能读出")
    func decodesOldDay() throws {
        let json = #"{"decks":{},"models":{"m":{"requests":2,"prompt":10,"completion":5}}}"#
        let day = try JSONDecoder().decode(StatsDay.self, from: Data(json.utf8))
        #expect(day.tasks.isEmpty)
        #expect(day.models["m"]?.requests == 2)
    }

    @Test("汇总按任务列出用量；范围里有 1.9 之前的用量时标出不完整")
    func summary() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        var log = StatsLog()
        log.addReply(deck: "/a.pdf", page: 1, model: "big", kind: .question, task: .chat,
                     usage: TokenUsage(prompt: 100, completion: 10), at: now)
        log.addReply(deck: "/a.pdf", page: nil, model: "small", kind: .housekeeping, task: .record,
                     usage: TokenUsage(prompt: 50, completion: 5), at: now)
        let complete = StatsSummary(log: log, period: .week, now: now, calendar: calendar)
        #expect(complete.tasks.map(\.task) == [.chat, .record])
        #expect(complete.tasks.first?.tally.total == 110)
        #expect(!complete.tasksPartial)

        // 前一天是 1.9 之前记的：有模型用量，没有任务用量
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        var old = StatsDay()
        old.models["big"] = StatsLog.tally(TokenUsage(prompt: 1, completion: 1))
        log.days[StatsLog.key(for: yesterday, calendar: calendar)] = old
        #expect(StatsSummary(log: log, period: .week, now: now, calendar: calendar).tasksPartial)
    }
}

/// 整理学习记录换了模型时，请求里不带课件全文。
@Suite("整理请求")
struct RecordRequestTests {
    private let context: PromptBuilder.Context = {
        var context = PromptBuilder.Context(title: "Signals", pageCount: 2, currentPage: 1,
                                            text: DocumentText(pages: ["傅里叶变换 PAGE-ONE-TEXT", "PAGE-TWO-TEXT"]), latestText: nil,
                                            charLimit: 50_000, historyLimit: 20, tokenBudget: 64_000, pageImageJPEG: nil)
        context.record = "OLD-RECORD-TEXT"
        return context
    }()

    private var past: [ChatMessage] {
        var question = PromptBuilder.userMessage(for: .question("什么是频谱？", selection: nil), page: 1)
        question.sentText = PromptBuilder.composeText(question, context: context)
        return [question, ChatMessage(role: .assistant, content: "频谱是……")]
    }

    @Test("不带课件全文：保留课件标题、旧记录和对话")
    func withoutCourseware() throws {
        let request = PromptBuilder.recordRequest(past: past, context: context, includeCourseware: false)
        let system = try #require(request.messages.first?["content"] as? String)
        #expect(system.contains("Signals") && system.contains("OLD-RECORD-TEXT"))
        #expect(!system.contains("PAGE-ONE-TEXT") && !system.contains("PAGE-TWO-TEXT"))
        #expect(request.messages.count == 4)
        #expect(request.messages[2]["content"] as? String == "频谱是……")
        #expect(request.messages.last?["role"] as? String == "user")
    }

    @Test("同一个模型时照旧带课件全文，和聊天请求共用前缀")
    func withCourseware() throws {
        let full = PromptBuilder.recordRequest(past: past, context: context)
        let slim = PromptBuilder.recordRequest(past: past, context: context, includeCourseware: false)
        let system = try #require(full.messages.first?["content"] as? String)
        #expect(system == PromptBuilder.systemPrompt(context))
        #expect(system.contains("PAGE-ONE-TEXT"))
        // 对话和整理指令两种请求相同
        #expect(full.messages.dropFirst().map { $0["content"] as? String } == slim.messages.dropFirst().map { $0["content"] as? String })
        #expect(full.estimatedTokens > slim.estimatedTokens)
    }
}
