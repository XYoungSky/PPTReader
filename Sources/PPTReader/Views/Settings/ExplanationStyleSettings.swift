import AppKit
import SwiftUI

struct ExplanationStyleSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let style = settings.explanationStyle
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(footer: tr("对之后的回答生效，已有的回答不变。在消息里直接提的要求（如“详细点”“画个图”“举个例子”）优先于这里的设置。",
                                    "Applies to new answers; existing ones stay as they are. Anything you ask for in a message (more detail, a diagram, an example) takes precedence.")) {
                SettingsRow(title: tr("篇幅", "Length"), detail: style.detail.summary) {
                    SegmentedPicker(selection: $settings.explanationStyle.detail,
                                    options: ExplanationStyle.Detail.allCases.map { ($0, $0.title) })
                        .accessibilityLabel(tr("篇幅", "Length"))
                }
                SettingsRow(title: tr("图示", "Diagrams"), detail: style.diagrams.summary) {
                    SegmentedPicker(selection: $settings.explanationStyle.diagrams,
                                    options: ExplanationStyle.Diagrams.allCases.map { ($0, $0.title) })
                        .accessibilityLabel(tr("图示", "Diagrams"))
                }
                SettingsRow(title: tr("例题", "Worked examples"), detail: style.examples.summary, divider: false) {
                    SegmentedPicker(selection: $settings.explanationStyle.examples,
                                    options: ExplanationStyle.Examples.allCases.map { ($0, $0.title) })
                        .accessibilityLabel(tr("例题", "Worked examples"))
                }
            }
            .animation(Motion.content, value: style)

            CustomStyleCard(text: $settings.explanationStyle.custom)

            HStack {
                Spacer()
                Button(tr("恢复默认", "Restore Defaults")) {
                    withAnimation(Motion.content) { settings.explanationStyle = ExplanationStyle() }
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(style == ExplanationStyle())
            }
        }
    }
}

/// 自定义要求：自由填写，或点按下方的短语加入 / 移除。
private struct CustomStyleCard: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        let limit = ExplanationStyle.customLimit
        SettingsCard(title: tr("自定义要求", "Custom instructions"),
                     footer: tr("随每次提问发给模型；和上面的选项冲突时，以这里写的为准。",
                                "Sent with every question. Where it conflicts with the options above, this wins.")) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .focused($focused)
                    if text.isEmpty {
                        Text(tr("写下你希望模型怎么讲，例如：多结合工程里的实际应用；推导写完整；每讲完一部分提一个思考题。",
                                "Describe how you'd like things explained, e.g. relate ideas to real engineering uses; write out full derivations; end each part with a question to think about."))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text3)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 92)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.panel))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1)
                )
                .animation(Motion.hover, value: focused)

                HStack(alignment: .top, spacing: 12) {
                    FlowLayout(spacing: 6) {
                        ForEach(ExplanationStyle.customSuggestions, id: \.title) { suggestion in
                            SuggestionChip(title: suggestion.title, selected: text.contains(suggestion.text)) {
                                withAnimation(Motion.snappy) { toggle(suggestion.text) }
                            }
                            .help(suggestion.text)
                        }
                    }
                    Spacer(minLength: 0)
                    Text("\(text.count) / \(limit)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(text.count >= limit ? Theme.danger : Theme.text3)
                        .padding(.top, 5)
                }
            }
            .padding(14)
        }
        .onChange(of: text) { _, value in
            if value.count > limit { text = String(value.prefix(limit)) }
        }
    }

    /// 已有这句话就移除，否则另起一行加在末尾。
    private func toggle(_ sentence: String) {
        if text.contains(sentence) {
            text = text.replacingOccurrences(of: sentence, with: "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        } else {
            let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = current.isEmpty ? sentence : current + "\n" + sentence
        }
    }
}

private struct SuggestionChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: selected ? "checkmark" : "plus")
                    .font(.system(size: 9, weight: .bold))
                Text(title)
                    .font(.system(size: 12))
            }
            .foregroundStyle(selected ? Theme.accent : Theme.text2)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                Capsule().fill(selected ? Theme.accent.opacity(0.1) : (hovering ? Theme.selected : Theme.hover))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// 按行排列、放不下就换行的布局。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
