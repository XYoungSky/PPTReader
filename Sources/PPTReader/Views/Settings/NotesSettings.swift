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
                         footer: tr("所有课件通用，例如专业、年级、已经学过的课、学习目标。放在系统提示里，修改后的下一次提问生效。",
                                    "Applies to every deck: your major, year, courses you've taken, what you're aiming for. It goes into the system prompt and takes effect from your next question.")) {
                NoteEditor(text: $settings.learnerProfile, limit: AppSettings.profileLimit, height: 72,
                           placeholder: tr("例如：电子信息专业大二，线性代数学过但不熟，目标是期末 85 分以上。",
                                           "e.g. Second-year electrical engineering; I've taken linear algebra but I'm rusty; aiming for a high grade in the final."))
            }

            if let course = chat.course {
                SettingsCard(title: tr("课程说明 · ", "Course notes · ") + course.lastPathComponent,
                             footer: tr("这门课的所有课件共用，例如老师强调的重点、记号约定、考试范围。保存在 PPTReader 的数据中，课程文件夹本身不会被修改。",
                                        "Shared by every deck in this course, such as what the lecturer stresses, notation and exam scope. Stored in PPTReader's data; the course folder itself is never changed.")) {
                    NoteEditor(text: Binding(get: { settings.courseNotes(for: course) },
                                             set: { settings.setCourseNotes($0, for: course) }),
                               limit: AppSettings.courseNotesLimit, height: 120,
                               placeholder: tr("例如：老师说第 4 章只考计算不考证明；本课程向量一律用粗体表示；期中范围是第 1–5 章。",
                                               "e.g. Chapter 4 is tested on calculations only, not proofs; vectors are written in bold; the midterm covers chapters 1–5."))
                }
            } else {
                SettingsCard(title: tr("课程说明", "Course notes"),
                             footer: tr("打开一份课件后，可以为它所在的课程写说明。", "Open a deck to write notes for its course.")) {
                    EmptyView()
                }
            }

            if let record = chat.record {
                SettingsCard(title: tr("学习记录 · 当前课件", "Study record · this deck"),
                             footer: tr("对话超出上限时自动整理，代替被丢弃的较早对话。清除后，那些对话会在下次超出上限时重新整理。",
                                        "Written automatically when the chat exceeds the limit, in place of the earlier messages that are dropped. If cleared, they're condensed again the next time the limit is reached.")) {
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
