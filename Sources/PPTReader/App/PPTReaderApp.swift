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
}

struct AppCommands: Commands {
    let model: AppModel
    @AppStorage("ui.showsChat") private var showsChat = true
    @AppStorage("ui.showsSidebar") private var showsSidebar = true

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(tr("设置…", "Settings…")) { SettingsWindow.show() }
                .keyboardShortcut(",")
        }

        CommandGroup(before: .toolbar) {
            Button(showsSidebar ? tr("隐藏侧边栏", "Hide Sidebar") : tr("显示侧边栏", "Show Sidebar")) {
                withAnimation(Motion.panel) { showsSidebar.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            Button(showsChat ? tr("隐藏 AI 面板", "Hide AI Panel") : tr("显示 AI 面板", "Show AI Panel")) {
                withAnimation(Motion.panel) { showsChat.toggle() }
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            Divider()
        }

        CommandGroup(replacing: .newItem) {
            Button(tr("打开课程文件夹…", "Open Course Folder…")) { model.chooseFolder() }
                .keyboardShortcut("o")
            Menu(tr("最近打开", "Open Recent")) {
                ForEach(model.library.recentFolders, id: \.self) { url in
                    Button(url.lastPathComponent) { model.openFolder(url) }
                }
            }
            .disabled(model.library.recentFolders.isEmpty)
            Divider()
            Button(tr("刷新文件列表", "Refresh File List")) { model.library.refresh() }
                .keyboardShortcut("r")
                .disabled(model.library.rootURL == nil)
        }

        CommandMenu(tr("阅读", "Read")) {
            Button(tr("上一页", "Previous Page")) { model.reader?.pdf.previous() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button(tr("下一页", "Next Page")) { model.reader?.pdf.next() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button(tr("放大", "Zoom In")) { model.reader?.pdf.zoomIn() }
                .keyboardShortcut("=")
            Button(tr("缩小", "Zoom Out")) { model.reader?.pdf.zoomOut() }
                .keyboardShortcut("-")
            Button(tr("适合窗口", "Fit to Window")) { model.reader?.pdf.fitToWindow() }
                .keyboardShortcut("0")
            Divider()
            Button(tr("讲解本页", "Explain Page")) { model.chat.perform(.explainPage(auto: false)) }
                .keyboardShortcut("e")
                .disabled(model.reader == nil || model.chat.isStreaming)
            Button(tr("停止生成", "Stop")) { model.chat.stop() }
                .keyboardShortcut(".")
                .disabled(!model.chat.isStreaming)
        }
    }
}
