import Foundation
import Testing
@testable import PPTReader

@Suite("服务商配置")
struct ProviderTests {
    @Test("旧版本保存的配置能读出，新字段取默认值")
    func decodeOldProvider() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","name":"OR","baseURL":"https://openrouter.ai/api/v1","model":"a/b","reasoningEffort":"high"}
        """
        let provider = try JSONDecoder().decode(APIProvider.self, from: Data(json.utf8))
        #expect(provider.id == id)
        #expect(provider.kind == .openRouter, "没有保存类型时按地址推断")
        #expect(provider.reasoningEffort == .high)
        #expect(provider.recentModels.isEmpty)
        #expect(provider.longCache)
    }

    @Test("认不出的思考强度回退为默认，不让整个配置读不出来")
    func unknownEffort() throws {
        let json = #"{"id":"\#(UUID().uuidString)","reasoningEffort":"ultra"}"#
        let provider = try JSONDecoder().decode(APIProvider.self, from: Data(json.utf8))
        #expect(provider.reasoningEffort == .auto)
    }

    @Test("编码再解码保持不变")
    func roundTrip() throws {
        var provider = APIProvider(name: "OR", baseURL: "https://openrouter.ai/api/v1", model: "x/y")
        provider.recentModels = ["x/y", "a/b"]
        provider.reasoningEffort = .xhigh
        let decoded = try JSONDecoder().decode(APIProvider.self, from: JSONEncoder().encode(provider))
        #expect(decoded == provider)
    }

    @Test("按地址推断接口类型", arguments: [
        ("https://api.deepseek.com", ProviderPreset.deepSeek),
        ("https://api.kimi.com/coding/v1", .kimiCode),
        ("https://api.moonshot.cn/v1", .kimiPlatform),
        ("https://openrouter.ai/api/v1", .openRouter),
        ("https://OpenRouter.ai/api/v1", .openRouter),
        ("http://localhost:11434/v1", .custom),
    ])
    func detect(_ url: String, _ kind: ProviderPreset) {
        #expect(ProviderPreset.detect(url) == kind)
    }

    @Test("每种类型可选的思考强度都以“默认”开头")
    func effortOptions() {
        for kind in ProviderPreset.allCases where kind.hasReasoningEffort {
            #expect(kind.reasoningEfforts.first == .auto)
        }
        #expect(!ProviderPreset.openRouter.reasoningEfforts.contains(.minimal))
        #expect(ProviderPreset.kimiCode.reasoningEfforts == [.auto, .low, .high, .max])
        #expect(!ProviderPreset.deepSeek.hasReasoningEffort)
    }
}

@MainActor
@Suite("可搜索菜单")
struct PopMenuModelTests {
    private func models(_ count: Int) -> [PopMenuItem] {
        (0..<count).map { PopMenuItem("vendor/model-\($0)", filterable: true) {} }
    }

    private func titles(_ model: PopMenuModel) -> [String] {
        model.items.filter { $0.kind == .action }.map(\.title)
    }

    private func notes(_ model: PopMenuModel) -> [PopMenuItem] {
        model.items.filter { $0.kind == .note }
    }

    @Test("可过滤项不多于上限时不可搜索，原样显示")
    func notSearchable() {
        let model = PopMenuModel(items: models(12), anchor: .topLeading, limit: 12)
        #expect(!model.searchable)
        #expect(model.items.count == 12)
        model.setQuery("model-1")
        #expect(model.query.isEmpty, "不可搜索的菜单忽略输入")
    }

    @Test("超过上限：只显示上限这么多，并提示还有几项")
    func truncated() {
        let model = PopMenuModel(items: models(30), anchor: .topLeading, limit: 12)
        #expect(model.searchable)
        #expect(titles(model).count == 12)
        #expect(notes(model).count == 1)
        #expect(notes(model).first?.title.contains("18") == true)
    }

    @Test("按空格分开的每个词过滤，不分大小写")
    func filter() {
        let items = models(20) + [PopMenuItem("anthropic/claude-x", filterable: true) {},
                                  PopMenuItem("openai/gpt-x", filterable: true) {}]
        let model = PopMenuModel(items: items, anchor: .topLeading, limit: 12)
        model.setQuery("ANTHROPIC x")
        #expect(titles(model) == ["anthropic/claude-x"])
        #expect(notes(model).isEmpty)
        #expect(model.highlighted == model.items.first(where: { $0.title == "anthropic/claude-x" })?.id, "有输入时高亮第一个匹配项")
    }

    @Test("没有匹配时显示说明，不可过滤的项照常显示")
    func noMatches() {
        let items = [PopMenuItem.header("Provider"), PopMenuItem("DeepSeek") {}, .separator,
                     .header("Model")] + models(20) + [.separator, PopMenuItem("Settings…") {}]
        let model = PopMenuModel(items: items, anchor: .topLeading, limit: 12)
        model.setQuery("zzz")
        #expect(titles(model) == ["DeepSeek", "Settings…"])
        #expect(notes(model).count == 1)
        // 说明紧跟在“模型”标题后面，标题不会因为没有模型而被去掉
        let kinds = model.items.map(\.kind)
        #expect(kinds == [.header, .action, .separator, .header, .note, .separator, .action])
    }

    @Test("清空搜索后恢复，并去掉失效的高亮")
    func clearQuery() {
        let model = PopMenuModel(items: models(30), anchor: .topLeading, limit: 12)
        model.setQuery("model-29")
        #expect(titles(model) == ["vendor/model-29"])
        model.setQuery("")
        #expect(titles(model).count == 12)
        #expect(model.highlighted == nil, "高亮的 model-29 已不在显示范围内")
    }

    @Test("方向键在可选项之间循环，跳过说明")
    func move() {
        let model = PopMenuModel(items: models(14), anchor: .topLeading, limit: 12)
        model.move(-1)
        #expect(model.highlighted == model.items.last(where: \.isSelectable)?.id)
        model.move(1)
        #expect(model.highlighted == model.items.first(where: \.isSelectable)?.id)
    }
}
