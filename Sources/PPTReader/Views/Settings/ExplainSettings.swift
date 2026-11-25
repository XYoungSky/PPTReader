import AppKit
import SwiftUI

struct ExplainSettings: View {
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

            SettingsCard(footer: tr("框选后可以就框内的图、公式或文字提问：框内截图和文字会一起发给模型；模型不支持识图或关闭了截图时只发文字。",
                                    "After boxing an area you can ask about the figure, formula or text inside it: a screenshot of the box and its text are sent together, or just the text if the model can't see images or screenshots are off.")) {
                SettingsRow(title: tr("在课件上拖动", "Dragging on slides"),
                            detail: tr("按住 Shift 拖动时换成另一种", "Hold Shift while dragging for the other one"), divider: false) {
                    SegmentedPicker(selection: $settings.dragSelectsRegion,
                                    options: [(false, tr("选文字", "Select text")), (true, tr("框选", "Draw box"))])
                        .accessibilityLabel(tr("在课件上拖动", "Dragging on slides"))
                }
            }

            SettingsCard(title: tr("上下文", "Context"),
                         footer: tr("课件或对话超出上限时，保留当前页附近的课件和最近的对话。模型的上下文窗口在「模型」中设置。",
                                    "When the deck or chat exceeds a limit, the pages around the current one and the latest messages are kept. Set the model's context window under Model.")) {
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
                SettingsRow(title: tr("携带历史消息", "Chat history")) {
                    SegmentedPicker(selection: $settings.historyLimit, options: [(8, "8"), (16, "16"), (32, "32")])
                }
                SettingsRow(title: tr("整理较早的对话", "Condense earlier messages"),
                            detail: tr("超出上限时先整理成学习记录再丢弃，模型记得讲过什么；每次整理多一次请求",
                                       "Before old messages are dropped, they're condensed into a study record so the tutor remembers them; costs one extra request each time")) {
                    Toggle("", isOn: $settings.compactHistory)
                        .toggleStyle(AccentToggleStyle())
                        .labelsHidden()
                }
                SettingsRow(title: tr("上下文上限", "Context limit"),
                            detail: tr("占模型上下文窗口的比例，其余留给回答 · 约 \(TokenEstimate.label(settings.contextTokenBudget)) / \(TokenEstimate.label(settings.contextWindow))",
                                       "Share of the model's context window; the rest is left for the answer · about \(TokenEstimate.label(settings.contextTokenBudget)) of \(TokenEstimate.label(settings.contextWindow))"),
                            divider: false) {
                    HStack(spacing: 10) {
                        Slider(value: $settings.contextBudgetPercent, in: 0.2...0.9, step: 0.05)
                            .tint(Theme.accent)
                            .controlSize(.small)
                            .frame(width: 150)
                            .accessibilityLabel(tr("上下文上限", "Context limit"))
                        Text(StatsFormat.percent(settings.contextBudgetPercent))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.text)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }
}
