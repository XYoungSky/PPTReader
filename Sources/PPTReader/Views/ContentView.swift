import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @AppStorage(PanelKeys.showsChat) private var showsChat = true
    @AppStorage(PanelKeys.showsSidebar) private var showsSidebar = true

    var body: some View {
        MainSplitView(model: model, showsSidebar: showsSidebar, showsChat: showsChat && model.reader != nil)
            .background(WindowChrome())
            .ignoresSafeArea()
            .onChange(of: settings.hasAPIKey) { model.chat.pushMeta() }
            .onChange(of: settings.chatFontSize) { model.chat.pushMeta() }
            .onChange(of: settings.chatSerif) { model.chat.pushMeta() }
            .onChange(of: Localizer.shared.code) { model.chat.pushAll() }
            .onChange(of: settings.autoExplain) { model.chat.autoExplainToggled() }
    }
}

/// 中间的阅读区：顶栏 + 课件。
struct ReaderColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ReaderHeader()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(Motion.content, value: phaseID)
        }
        .background(Theme.canvas)
    }

    /// 用于驱动状态切换动画的标识。
    private var phaseID: String {
        switch model.phase {
        case .empty: "empty"
        case .loading(let name): "loading:\(name)"
        case .converting(let name, _): "converting:\(name)"
        case .failed(let name, _): "failed:\(name)"
        case .ready(let reader): "ready:\(ObjectIdentifier(reader).hashValue)"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .empty:
            WelcomeView()
        case .loading(let name):
            StatusView(title: tr("正在打开", "Opening"), detail: name, showsProgress: true)
        case .converting(let name, let app):
            StatusView(title: tr("正在转换 \(name)", "Converting \(name)"),
                       detail: tr("首次打开需用 \(app) 转换，之后秒开", "First open only — converting with \(app)"),
                       showsProgress: true)
        case .failed(let name, let message):
            StatusView(title: tr("无法打开 \(name)", "Can't open \(name)"), detail: message, showsProgress: false) {
                HStack(spacing: 8) {
                    Button(tr("重试", "Retry")) { model.reloadCurrent() }
                        .buttonStyle(AccentButtonStyle())
                    Button(tr("用默认应用打开", "Open in Default App")) { model.openInDefaultApp() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        case .ready(let reader):
            ReaderPane(reader: reader)
                .id(ObjectIdentifier(reader))
        }
    }
}

private struct StatusView<Actions: View>: View {
    let title: String
    let detail: String
    let showsProgress: Bool
    @ViewBuilder var actions: Actions

    init(title: String, detail: String, showsProgress: Bool, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.showsProgress = showsProgress
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 12) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .padding(.bottom, 4)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            actions
                .padding(.top, 8)
        }
        .padding(40)
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Theme.accent.opacity(0.1)))
                .padding(.bottom, 4)
            Text(model.library.rootURL == nil ? tr("打开课程文件夹", "Open a course folder") : tr("选择一个课件", "Pick a file to start"))
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.text)
            if model.library.rootURL == nil {
                Text("PDF · PPT · Word")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
                Button(tr("打开文件夹…", "Open Folder…")) { model.chooseFolder() }
                    .buttonStyle(AccentButtonStyle())
                    .padding(.top, 10)
                Text(tr("或拖到这里", "or drop it here"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.openFolder(url)
            return true
        }
    }
}
