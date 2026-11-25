import SwiftUI

@main
struct PPTReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var model: AppModel

    init() {
        let model = AppModel()
        _model = ViewState(initialValue: model)
        SettingsWindow.model = model
    }

    var body: some Scene {
        Window("PPTReader", id: "main") {
            ContentView()
                .environment(model)
                .environment(model.settings)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands { AppCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 直接运行可执行文件（swift run）时也作为普通前台应用出现
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 正在录音时先确认；停止会把当前分段写完、存好清单，再退出。
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let lectures = SettingsWindow.model?.lectures, lectures.isRecording else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = tr("正在录音", "Recording in progress")
        alert.informativeText = tr("退出前会停止录音并保存已经录下的部分。", "Quitting stops the recording and saves what has been recorded.")
        alert.addButton(withTitle: tr("停止录音并退出", "Stop and Quit"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        lectures.stop()
        return .terminateNow
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @AppStorage(PanelKeys.showsChat) private var showsChat = true
    @AppStorage(PanelKeys.showsSidebar) private var showsSidebar = true
    /// 快捷键修改后让菜单重新计算。
    @AppStorage(ShortcutStore.defaultsKey) private var shortcutsJSON = ""

    private func key(_ action: ShortcutAction) -> KeyboardShortcut? {
        _ = shortcutsJSON
        return ShortcutStore.shared.keyboardShortcut(for: action)
    }

    var body: some Commands {
        let reader = model.reader
        let chat = model.chat
        let settings = model.settings
        let canAsk = reader != nil && !chat.isStreaming

        CommandGroup(replacing: .appSettings) {
            Button(tr("设置…", "Settings…")) { SettingsWindow.show() }
                .keyboardShortcut(",")
        }

        CommandGroup(before: .toolbar) {
            Button(showsSidebar ? tr("隐藏侧边栏", "Hide Sidebar") : tr("显示侧边栏", "Show Sidebar")) {
                withAnimation(Motion.panel) { showsSidebar.toggle() }
            }
            .keyboardShortcut(key(.toggleSidebar))
            Button(showsChat ? tr("隐藏 AI 面板", "Hide AI Panel") : tr("显示 AI 面板", "Show AI Panel")) {
                withAnimation(Motion.panel) { showsChat.toggle() }
            }
            .keyboardShortcut(key(.toggleChat))
            Divider()
        }

        CommandGroup(before: .windowList) {
            Button(tr("学习统计", "Statistics")) { StatsWindow.show() }
                .keyboardShortcut(key(.statistics))
            Button(tr("学习路线图", "Study Roadmap")) { RoadmapWindow.shared.show() }
                .keyboardShortcut(key(.roadmap))
                .disabled(reader == nil)
            Divider()
        }

        CommandGroup(replacing: .newItem) {
            Button(tr("打开课程文件夹…", "Open Course Folder…")) { model.chooseFolder() }
                .keyboardShortcut(key(.openFolder))
            Menu(tr("最近打开", "Open Recent")) {
                ForEach(model.library.recentFolders, id: \.self) { url in
                    Button(url.lastPathComponent) { model.openFolder(url) }
                }
            }
            .disabled(model.library.recentFolders.isEmpty)
            Divider()
            Button(tr("刷新文件列表", "Refresh File List")) { model.library.refresh() }
                .keyboardShortcut(key(.refreshFiles))
                .disabled(model.library.rootURL == nil)
        }

        CommandMenu(tr("阅读", "Read")) {
            Button(tr("上一页", "Previous Page")) { reader?.pdf.previous() }
                .keyboardShortcut(key(.previousPage))
                .disabled(reader == nil)
            Button(tr("下一页", "Next Page")) { reader?.pdf.next() }
                .keyboardShortcut(key(.nextPage))
                .disabled(reader == nil)
            Divider()
            Button(tr("放大", "Zoom In")) { reader?.pdf.zoomIn() }
                .keyboardShortcut(key(.zoomIn))
                .disabled(reader == nil)
            Button(tr("缩小", "Zoom Out")) { reader?.pdf.zoomOut() }
                .keyboardShortcut(key(.zoomOut))
                .disabled(reader == nil)
            Button(tr("适合窗口", "Fit to Window")) { reader?.pdf.fitToWindow() }
                .keyboardShortcut(key(.fitToWindow))
                .disabled(reader == nil)
            Divider()
            Toggle(tr("连续滚动", "Continuous Scrolling"), isOn: Binding(
                get: { reader?.continuousScroll ?? false },
                set: { value in
                    guard let reader else { return }
                    reader.continuousScroll = value
                    reader.pdf.setContinuous(value)
                }))
                .keyboardShortcut(key(.toggleLayout))
                .disabled(reader == nil)
        }

        CommandMenu(tr("录音", "Record")) {
            let lectures = model.lectures
            Button(lectures.isRecording ? tr("停止录音", "Stop Recording") : tr("开始录音", "Start Recording")) { lectures.toggle() }
                .keyboardShortcut(key(.record))
                .disabled(!LectureController.isSupported)
            Button(lectures.recorder.state == .paused ? tr("继续录音", "Resume Recording") : tr("暂停录音", "Pause Recording")) {
                lectures.recorder.state == .paused ? lectures.resume() : lectures.pause()
            }
            .disabled(!lectures.isRecording)
            Divider()
            Picker(tr("转写语言", "Transcription Language"), selection: Binding(
                get: { settings.recordingLocale }, set: { settings.recordingLocale = $0 })) {
                ForEach(LectureController.locales, id: \.id) { locale in
                    Text(locale.title).tag(locale.id)
                }
            }
            .disabled(!LectureController.isSupported || lectures.isRecording)
            Divider()
            Button(tr("课堂录音", "Lectures")) { RecordingsWindow.shared.show() }
                .keyboardShortcut(key(.recordings))
                .disabled(!LectureController.isSupported)
            if !LectureController.isSupported {
                Text(tr("课堂录音需要 macOS 26 或更新版本", "Lecture recording requires macOS 26 or later"))
            }
        }

        CommandMenu(tr("讲解", "Tutor")) {
            Button(tr("讲解本页", "Explain Page")) { chat.perform(.explainPage(auto: false)) }
                .keyboardShortcut(key(.explainPage))
                .disabled(!canAsk)
            Button(tr("提问…", "Ask…")) { askQuestion() }
                .keyboardShortcut(key(.askQuestion))
                .disabled(reader == nil)
            Divider()
            Button(QuickAction.summary.title) { chat.perform(.quick(.summary)) }
                .keyboardShortcut(key(.summarize))
                .disabled(!canAsk)
            Button(QuickAction.outline.title) { chat.perform(.quick(.outline)) }
                .keyboardShortcut(key(.conceptMap))
                .disabled(!canAsk)
            Button(QuickAction.quiz.title) { chat.perform(.quick(.quiz)) }
                .keyboardShortcut(key(.quiz))
                .disabled(!canAsk)
            Divider()
            Toggle(tr("翻页自动讲解", "Auto-explain on Page Turn"), isOn: Binding(
                get: { settings.autoExplain }, set: { settings.autoExplain = $0 }))
                .keyboardShortcut(key(.toggleAutoExplain))
            Toggle(tr("深度思考", "Deep Thinking"), isOn: Binding(
                get: { settings.thinking }, set: { settings.thinking = $0 }))
                .keyboardShortcut(key(.toggleThinking))
                .disabled(!settings.activeProvider.kind.hasThinkingToggle)
            Divider()
            Button(tr("停止生成", "Stop")) { chat.stop() }
                .keyboardShortcut(key(.stop))
                .disabled(!chat.isStreaming)
        }
    }

    /// 显示 AI 面板并聚焦输入框。
    private func askQuestion() {
        if !showsChat { withAnimation(Motion.panel) { showsChat = true } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { model.chat.requestFocus() }
    }
}
