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
                SettingsRow(title: tr("停留时间", "Delay"), divider: false) {
                    SegmentedPicker(selection: $settings.autoExplainDelay, options: [(1.0, "1s"), (1.5, "1.5s"), (3.0, "3s"), (5.0, "5s")])
                }
            }

            SettingsCard {
                SettingsRow(title: tr("在课件上拖动", "Dragging on slides"),
                            detail: tr("按住 Shift 切换", "Hold Shift to switch"),
                            help: tr("框选区域后，可针对其中的图表或公式提问，区域截图会一并发送给模型。",
                                     "Box an area to ask about the figure or formula in it; a screenshot of the area is sent with the question."),
                            divider: false) {
                    SegmentedPicker(selection: $settings.dragSelectsRegion,
                                    options: [(false, tr("选文字", "Select text")), (true, tr("框选", "Draw box"))])
                        .accessibilityLabel(tr("在课件上拖动", "Dragging on slides"))
                }
            }

            SettingsCard(title: tr("上下文", "Context"),
                         help: tr("超出上限时，仅保留当前页附近的课件内容和最近的对话。", "Beyond a limit, only the pages near the current one and the latest messages are kept.")) {
                SettingsRow(title: tr("附带当前页截图", "Attach page screenshot"),
                            detail: tr("使模型能看到图表与公式", "Lets the model see figures and formulas")) {
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
                            detail: tr("保留已讲内容的要点", "Keeps the key points of earlier messages"),
                            help: tr("超出上限时，先将较早的对话整理为学习记录再移除；每次整理需额外发送一次请求。",
                                     "Beyond the limit, earlier messages are condensed into a study record before removal. Each condensation costs one extra request.")) {
                    Toggle("", isOn: $settings.compactHistory)
                        .toggleStyle(AccentToggleStyle())
                        .labelsHidden()
                }
                SettingsRow(title: tr("上下文上限", "Context limit"),
                            detail: tr("约 \(TokenEstimate.label(settings.contextTokenBudget)) / \(TokenEstimate.label(settings.contextWindow))",
                                       "About \(TokenEstimate.label(settings.contextTokenBudget)) of \(TokenEstimate.label(settings.contextWindow))"),
                            help: tr("占模型上下文窗口的比例，其余部分留给回答。窗口大小在「模型」中设置。",
                                     "Share of the model's context window; the rest is reserved for the answer. Set the window size under Model."),
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
