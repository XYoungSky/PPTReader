import AppKit
import SwiftUI

struct DataSettings: View {
    @Environment(AppModel.self) private var model
    @ViewState private var cacheSize = ""
    @ViewState private var cleared = false
    @ViewState private var statsCleared = false

    var body: some View {
        SettingsCard {
            SettingsRow(title: tr("对话记录", "Chat history")) {
                Button(tr("在访达中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.chats]) }
                    .buttonStyle(OutlineButtonStyle())
            }
            SettingsRow(title: tr("学习统计", "Statistics"), detail: statsCleared ? tr("已清除", "Cleared") : nil) {
                HStack(spacing: 8) {
                    Button(tr("查看", "View")) { StatsWindow.show() }
                        .buttonStyle(OutlineButtonStyle())
                    Button(tr("清除…", "Clear…")) { confirmClearStats() }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(model.stats.log.isEmpty)
                }
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

    /// 与清空对话一致：在鼠标位置弹出确认菜单。
    private func confirmClearStats() {
        let stats = model.stats
        PopMenu.shared.show([
            .header(tr("清除后无法恢复", "This can't be undone")),
            PopMenuItem(tr("清除学习统计", "Clear Statistics"), icon: "trash", destructive: true) {
                stats.clear()
                withAnimation(Motion.content) { statsCleared = true }
            },
            PopMenuItem(tr("取消", "Cancel"), icon: "xmark") {},
        ], placement: .at(NSEvent.mouseLocation), in: NSApp.keyWindow, minWidth: 180)
    }

    private func refreshSize() {
        let bytes = [AppPaths.convertedPDFs, AppPaths.extractedText].reduce(Int64(0)) { total, dir in
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return total + files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        cacheSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
