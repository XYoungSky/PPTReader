import AppKit
import SwiftUI

/// 设置窗口：自己管理 NSWindow，便于隐藏标题栏、统一外观。
@MainActor
enum SettingsWindow {
    static var model: AppModel?
    private static var window: NSWindow?

    /// - Parameter section: 打开后切换到的分区；为空时停留在上次的分区。
    static func show(_ section: SettingsSection? = nil) {
        if let section { SettingsRouter.shared.section = section }
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

/// 设置窗口当前显示的分区，放在窗口之外，便于从 AI 面板等处直接跳到某个分区。
@MainActor
@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()
    var section: SettingsSection = .model
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case model, explain, explanationStyle, notes, recording, appearance, shortcuts, data

    /// 课堂录音只在 macOS 26+ 提供。
    static var visible: [SettingsSection] { allCases.filter { $0 != .recording || LectureController.isSupported } }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .model: tr("模型", "Model")
        case .explain: tr("讲解", "Tutor")
        case .explanationStyle: tr("讲解风格", "Explanation style")
        case .notes: tr("学习档案", "Study notes")
        case .recording: tr("课堂录音", "Lectures")
        case .appearance: tr("外观", "Appearance")
        case .shortcuts: tr("快捷键", "Shortcuts")
        case .data: tr("数据", "Data")
        }
    }

    var icon: String {
        switch self {
        case .model: "cpu"
        case .explain: "sparkles"
        case .explanationStyle: "slider.horizontal.3"
        case .notes: "person.text.rectangle"
        case .recording: "mic"
        case .appearance: "paintbrush"
        case .shortcuts: "keyboard"
        case .data: "externaldrive"
        }
    }
}

struct SettingsView: View {
    private var router: SettingsRouter { SettingsRouter.shared }
    private var section: SettingsSection { router.section }

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
                        case .notes: NotesSettings()
                        case .recording: RecordingSettings()
                        case .appearance: AppearanceSettings()
                        case .shortcuts: ShortcutSettings()
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
        .onChange(of: section) { ShortcutStore.shared.endRecording() }
        .onDisappear { ShortcutStore.shared.endRecording() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 48)
            ForEach(SettingsSection.visible) { item in
                SectionButton(section: item, selected: section == item) {
                    withAnimation(Motion.content) { router.section = item }
                }
            }
            Spacer()
            Text("PPTReader \(AppInfo.version)")
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
