import AppKit
import SwiftUI

struct ShortcutSettings: View {
    var body: some View {
        let store = ShortcutStore.shared
        VStack(alignment: .leading, spacing: 22) {
            ForEach(ShortcutAction.Group.allCases.filter { $0 != .recording || LectureController.isSupported }) { group in
                let actions = ShortcutAction.allCases.filter { $0.group == group }
                SettingsCard(title: group.title) {
                    ForEach(actions) { action in
                        let feedback = store.feedback?.action == action ? store.feedback?.value : nil
                        SettingsRow(title: action.title, detail: feedback?.text,
                                    detailColor: feedback?.isError == true ? Theme.danger : Theme.text3,
                                    divider: action != actions.last) {
                            ShortcutRecorder(action: action)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(tr("全部恢复默认", "Restore Defaults")) {
                    withAnimation(Motion.content) { store.resetAll() }
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(!store.hasModifications)
            }
        }
        .animation(Motion.content, value: store.feedback?.value)
    }
}

/// 点按后录制下一次按下的组合键；⌫ 清除，esc 取消。
private struct ShortcutRecorder: View {
    let action: ShortcutAction
    @ViewState private var hovering = false

    var body: some View {
        let store = ShortcutStore.shared
        let recording = store.recording == action
        let combo = store.combo(for: action)
        HStack(spacing: 4) {
            if store.isModified(action) && !recording {
                Button {
                    withAnimation(Motion.content) { store.reset(action) }
                } label: {
                    Label(tr("恢复默认", "Restore default"), systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .help(tr("恢复默认", "Restore default") + (action.defaultCombo.map { "：" + $0.display } ?? ""))
                .transition(.opacity)
            }
            Button {
                store.toggleRecording(action)
            } label: {
                pill(recording: recording, combo: combo, held: store.heldModifiers)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) {
                if hovering && !recording && combo != nil {
                    Button {
                        withAnimation(Motion.content) { _ = store.set(nil, for: action) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                            .frame(width: 22, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tr("清除", "Clear"))
                    .transition(.opacity)
                }
            }
            .onHover { hovering = $0 }
            .help(recording ? tr("⌫ 清除 · esc 取消", "⌫ clear · esc cancel") : tr("点按录制", "Click to record"))
        }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.content, value: recording)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(action.title)
        .accessibilityValue(combo?.display ?? tr("未设置", "None"))
    }

    private func pill(recording: Bool, combo: KeyCombo?, held: KeyCombo.Modifiers) -> some View {
        Group {
            if recording {
                Text(held.isEmpty ? tr("按下快捷键", "Type shortcut") : held.symbols + "…")
                    .foregroundStyle(Theme.accent)
            } else if let combo {
                Text(combo.display)
                    .foregroundStyle(Theme.text)
            } else {
                Text(tr("未设置", "None"))
                    .foregroundStyle(Theme.text3)
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minWidth: 112, minHeight: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(recording ? Theme.accent.opacity(0.08) : (hovering ? Theme.selected : Theme.hover))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(recording ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
