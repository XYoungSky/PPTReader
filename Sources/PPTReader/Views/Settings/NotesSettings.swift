import AppKit
import SwiftUI

/// 分层的学习档案（参考 Claude Code 的 CLAUDE.md 与 Codex 的 AGENTS.md）：
/// 关于我（所有课件通用）→ 课程说明（按课程文件夹）→ 学习记录（每份课件自动整理）。
struct NotesSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let chat = model.chat
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(title: tr("关于我", "About me"),
                         help: tr("适用于所有课件，如专业、年级、已修课程和学习目标。下一次提问时生效。",
                                  "Applies to every deck: major, year, completed courses and goals. Takes effect from the next question.")) {
                NoteEditor(text: $settings.learnerProfile, limit: AppSettings.profileLimit, height: 72,
                           placeholder: tr("例如：电子信息专业大二，已修线性代数，期末目标 85 分以上",
                                           "e.g. Second-year EE; completed linear algebra; aiming for 85+ in the final"))
            }

            if let course = chat.course {
                SettingsCard(title: tr("课程说明 · ", "Course notes · ") + course.lastPathComponent,
                             help: tr("本课程所有课件共用，如教师强调的重点、记号约定和考试范围。",
                                      "Shared by every deck in this course: emphasized topics, notation and exam scope.")) {
                    NoteEditor(text: Binding(get: { settings.courseNotes(for: course) },
                                             set: { settings.setCourseNotes($0, for: course) }),
                               limit: AppSettings.courseNotesLimit, height: 120,
                               placeholder: tr("例如：第 4 章只考计算；向量以粗体表示；期中范围为第 1–5 章",
                                               "e.g. Ch. 4: calculations only; vectors in bold; midterm covers Ch. 1–5"))
                }
            } else {
                SettingsCard(title: tr("课程说明", "Course notes"),
                             footer: tr("打开课件后，可编写所属课程的说明。", "Open a deck to write notes for its course.")) {
                    EmptyView()
                }
            }

            if let record = chat.record {
                SettingsCard(title: tr("学习记录 · 当前课件", "Study record · this deck"),
                             help: tr("对话超出上限时自动生成，用于替代被移除的较早对话。清除后，将在下次超出上限时重新生成。",
                                      "Generated when the chat exceeds its limit, replacing the removed messages. If cleared, it is regenerated next time.")) {
                    VStack(alignment: .leading, spacing: 10) {
                        ScrollView {
                            Text(record.text)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.text2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                        HStack {
                            Text(tr("已整理 \(record.messageCount) 条消息", "\(record.messageCount) messages condensed"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.text3)
                            Spacer()
                            Button(tr("清除记录", "Clear Record")) { chat.clearRecord() }
                                .buttonStyle(OutlineButtonStyle())
                        }
                    }
                    .padding(14)
                }
            }
        }
    }
}

/// 多行文字输入框，带字数上限和占位文字。
private struct NoteEditor: View {
    @Binding var text: String
    let limit: Int
    let height: CGFloat
    let placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($focused)
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text3)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: height)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.panel))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1)
            )
            .animation(Motion.hover, value: focused)
            Text("\(text.count) / \(limit)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(text.count >= limit ? Theme.danger : Theme.text3)
        }
        .padding(14)
        .onChange(of: text) { _, value in
            if value.count > limit { text = String(value.prefix(limit)) }
        }
    }
}
