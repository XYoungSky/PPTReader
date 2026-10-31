import AppKit
import SwiftUI

/// 设置窗口：自己管理 NSWindow，便于隐藏标题栏、统一外观。
@MainActor
enum SettingsWindow {
    static var model: AppModel?
    private static var window: NSWindow?

    static func show() {
        guard let model else { return }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView()
                .environment(model)
                .environment(model.settings))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = Theme.panelNSColor
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 760, height: 540))
            window.center()
            self.window = window
        }
        window?.title = tr("设置", "Settings")
        window?.makeKeyAndOrderFront(nil)
        // 不自动聚焦第一个输入框
        DispatchQueue.main.async { window?.makeFirstResponder(nil) }
        NSApp.activate()
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case model, explain, explanationStyle, appearance, data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .model: tr("模型", "Model")
        case .explain: tr("讲解", "Tutor")
        case .explanationStyle: tr("讲解风格", "Explanation style")
        case .appearance: tr("外观", "Appearance")
        case .data: tr("数据", "Data")
        }
    }

    var icon: String {
        switch self {
        case .model: "cpu"
        case .explain: "sparkles"
        case .explanationStyle: "slider.horizontal.3"
        case .appearance: "paintbrush"
        case .data: "externaldrive"
        }
    }
}

struct SettingsView: View {
    @ViewState private var section: SettingsSection = .model

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.border).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(section.title)
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .foregroundStyle(Theme.text)
                    Group {
                        switch section {
                        case .model: ModelSettings()
                        case .explain: ExplainSettings()
                        case .explanationStyle: ExplanationStyleSettings()
                        case .appearance: AppearanceSettings()
                        case .data: DataSettings()
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 44)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(section)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
            }
            .scrollIndicators(.never)
            .background(Theme.panel)
        }
        .frame(width: 760, height: 540)
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 48)
            ForEach(SettingsSection.allCases) { item in
                SectionButton(section: item, selected: section == item) {
                    withAnimation(Motion.content) { section = item }
                }
            }
            Spacer()
            Text("PPTReader 1.1")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .padding(.leading, 10)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(width: 190)
        .background(Theme.sidebar)
    }
}

private struct SectionButton: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? Theme.accent : Theme.text2)
                    .frame(width: 16)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Theme.selected : (hovering ? Theme.hover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.hover, value: selected)
    }
}

// MARK: - 模型

private struct ModelSettings: View {
    @Environment(AppSettings.self) private var settings
    @ViewState private var keyDraft = ""
    @ViewState private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle, testing, success(Int), failure(String)
    }

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(footer: tr("兼容 OpenAI 格式。Key 保存在系统钥匙串。", "OpenAI-compatible. The key is stored in the Keychain.")) {
                SettingsRow(title: tr("API 地址", "Base URL")) {
                    ThemedField(text: $settings.baseURL, placeholder: AppSettings.defaultBaseURL, monospaced: true)
                        .frame(width: 300)
                }
                SettingsRow(title: "API Key") {
                    ThemedField(text: $keyDraft, placeholder: "sk-…", secure: true, monospaced: true)
                        .frame(width: 300)
                        .onChange(of: keyDraft) { _, value in settings.setAPIKey(value) }
                }
                SettingsRow(title: tr("模型", "Model"), detail: modelDetail, divider: false) {
                    HStack(spacing: 6) {
                        ThemedField(text: $settings.model, placeholder: tr("输入或选择模型", "Enter or choose a model"), monospaced: true)
                        PopMenuButton(trailing: true, style: IconButtonStyle(size: 30)) {
                            settings.modelChoices.map { name in
                                PopMenuItem(name, checked: name == settings.effectiveModel) { settings.model = name }
                            }
                        } label: {
                            Label(tr("选择模型", "Choose model"), systemImage: "chevron.up.chevron.down")
                        }
                        .disabled(settings.modelChoices.isEmpty)
                    }
                    .frame(width: 300)
                }
            }

            SettingsCard {
                if OpenAIClient.isDeepSeek(settings.baseURL) {
                    SettingsRow(title: tr("深度思考", "Deep thinking"), detail: tr("更准确，但更慢", "More accurate, slower")) {
                        Toggle("", isOn: $settings.thinking)
                            .toggleStyle(AccentToggleStyle())
                            .labelsHidden()
                    }
                }
                SettingsRow(title: tr("测试连接", "Test connection"), detail: testDetail, divider: false) {
                    Button(testState == .testing ? tr("测试中…", "Testing…") : tr("测试", "Test")) { Task { await test() } }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(testState == .testing)
                }
            }
        }
        .onAppear { keyDraft = settings.apiKey }
    }

    private var modelDetail: String? {
        switch settings.effectiveModel {
        case "deepseek-flash": tr("快速，支持识图", "Fast, sees images")
        case "deepseek-v4-pro": tr("更强，不支持识图", "Stronger, text only")
        default: nil
        }
    }

    private var testDetail: String? {
        switch testState {
        case .idle: nil
        case .testing: nil
        case .success(let count): tr("✓ 可用，\(count) 个模型", "✓ Connected, \(count) models")
        case .failure(let message): "✕ \(message)"
        }
    }

    private func test() async {
        settings.setAPIKey(keyDraft)
        withAnimation(Motion.content) { testState = .testing }
        do {
            let models = try await OpenAIClient.listModels(config: settings.connection)
            settings.fetchedModels = models
            withAnimation(Motion.content) { testState = .success(models.count) }
        } catch {
            withAnimation(Motion.content) { testState = .failure(error.localizedDescription) }
        }
    }
}

// MARK: - 讲解

private struct ExplainSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                SettingsRow(title: tr("翻页自动讲解", "Auto-explain on page turn")) {
                    Toggle("", isOn: $settings.autoExplain)
                        .toggleStyle(AccentToggleStyle())
                        .labelsHidden()
                }
                SettingsRow(title: tr("停留多久后讲解", "Delay"), divider: false) {
                    SegmentedPicker(selection: $settings.autoExplainDelay, options: [(1.0, "1s"), (1.5, "1.5s"), (3.0, "3s"), (5.0, "5s")])
                }
            }

            SettingsCard(title: tr("上下文", "Context")) {
                SettingsRow(title: tr("附带当前页截图", "Attach page screenshot"),
                            detail: tr("让模型看到图片与公式", "Lets the model see figures and formulas")) {
                    Toggle("", isOn: $settings.sendPageImage)
                        .toggleStyle(AccentToggleStyle())
                        .labelsHidden()
                }
                SettingsRow(title: tr("课件文字上限", "Deck text limit")) {
                    SegmentedPicker(selection: $settings.contextCharLimit, options: [
                        (120_000, tr("12 万字", "120K")),
                        (400_000, tr("40 万字", "400K")),
                        (1_000_000, tr("100 万字", "1M")),
                    ])
                }
                SettingsRow(title: tr("携带历史消息", "Chat history"), divider: false) {
                    SegmentedPicker(selection: $settings.historyLimit, options: [(8, "8"), (16, "16"), (32, "32")])
                }
            }
        }
    }
}

// MARK: - 讲解风格

private struct ExplanationStyleSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(footer: tr("控制回答的篇幅与展开程度。简洁模式保留重点，详细模式展开推导与步骤。",
                                    "Choose how much detail to include, from key points to step-by-step explanations.")) {
                SettingsRow(title: tr("回答详略", "Answer detail"), divider: false) {
                    SegmentedPicker(selection: $settings.explanationStyle.detail,
                                    options: ExplanationStyle.Detail.allCases.map { ($0, $0.title) })
                        .accessibilityLabel(tr("回答详略", "Answer detail"))
                }
            }
            SettingsCard(footer: tr("选择图表的使用频率。多用 SVG 时，会优先用图示解释关系、流程与结构。",
                                    "Choose how often to use visuals. More SVG favors diagrams for relationships, processes and structures.")) {
                SettingsRow(title: tr("图表使用", "Diagrams"), divider: false) {
                    SegmentedPicker(selection: $settings.explanationStyle.diagrams,
                                    options: ExplanationStyle.Diagrams.allCases.map { ($0, $0.title) })
                        .accessibilityLabel(tr("图表使用", "Diagrams"))
                }
            }
            SettingsCard(footer: tr("选择是否补充例题。每个知识点模式会附上题目、解题步骤与答案。",
                                    "Choose when to add worked examples, including the question, solution steps and answer.")) {
                SettingsRow(title: tr("例题数量", "Examples"), divider: false) {
                    SegmentedPicker(selection: $settings.explanationStyle.examples,
                                    options: ExplanationStyle.Examples.allCases.map { ($0, $0.title) })
                        .accessibilityLabel(tr("例题数量", "Examples"))
                }
            }
            Text(tr("自动保存，从下一次回答起生效。你在提问中的明确要求优先。",
                    "Saved automatically. Applies to the next answer; explicit requests in your question take priority."))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }
}

// MARK: - 外观

private struct AppearanceSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        @Bindable var localizer = Localizer.shared
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                SettingsRow(title: tr("语言", "Language")) {
                    SegmentedPicker(selection: $localizer.language, options: [
                        (.system, tr("跟随系统", "System")),
                        (.zh, "中文"),
                        (.en, "English"),
                    ])
                }
                SettingsRow(title: tr("讲解字号", "Text size")) {
                    SegmentedPicker(selection: $settings.chatFontSize, options: [
                        (14.0, "14"), (15.0, "15"), (16.0, "16"), (17.0, "17"), (18.0, "18"),
                    ])
                }
                SettingsRow(title: tr("讲解字体", "Font"), divider: false) {
                    SegmentedPicker(selection: $settings.chatSerif, options: [(false, tr("无衬线", "Sans")), (true, tr("衬线", "Serif"))])
                }
            }
            Text(tr("傅里叶变换把信号从时域转换到频域：任何周期信号都可以分解为一组正弦波的叠加。",
                    "The Fourier transform moves a signal from time to frequency: any periodic signal is a sum of sine waves."))
                .font(.system(size: settings.chatFontSize, design: settings.chatSerif ? .serif : .default))
                .foregroundStyle(Theme.text)
                .lineSpacing(settings.chatFontSize * 0.6)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
                .animation(Motion.content, value: settings.chatFontSize)
                .animation(Motion.content, value: settings.chatSerif)
        }
    }
}

// MARK: - 数据

private struct DataSettings: View {
    @ViewState private var cacheSize = ""
    @ViewState private var cleared = false

    var body: some View {
        SettingsCard(footer: tr("课程文件夹始终只读。", "Course folders are never modified.")) {
            SettingsRow(title: tr("对话记录", "Chat history")) {
                Button(tr("在访达中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.chats]) }
                    .buttonStyle(OutlineButtonStyle())
            }
            SettingsRow(title: tr("转换与文字缓存", "Cache"), detail: cleared ? tr("已清除", "Cleared") : cacheSize, divider: false) {
                Button(tr("清除", "Clear")) {
                    try? FileManager.default.removeItem(at: AppPaths.convertedPDFs)
                    try? FileManager.default.removeItem(at: AppPaths.extractedText)
                    refreshSize()
                    withAnimation(Motion.content) { cleared = true }
                }
                .buttonStyle(OutlineButtonStyle())
            }
        }
        .onAppear(perform: refreshSize)
    }

    private func refreshSize() {
        let bytes = [AppPaths.convertedPDFs, AppPaths.extractedText].reduce(Int64(0)) { total, dir in
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return total + files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        cacheSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
