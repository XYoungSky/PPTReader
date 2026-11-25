import SwiftUI

/// AI 面板顶部的上下文用量：一个小圆环和百分比，点开看每部分占多少、缓存是否还有效、学习记录整理到哪里
/// （参考 Claude Code 的 /context 与 /usage）。
struct ContextMeter: View {
    @Environment(AppModel.self) private var model
    @ViewState private var showing = false

    var body: some View {
        let chat = model.chat
        if let report = chat.report {
            Button {
                showing.toggle()
            } label: {
                HStack(spacing: 4) {
                    Ring(fraction: report.windowFraction, busy: chat.isRecording)
                    Text(StatsFormat.percent(report.windowFraction))
                        .font(.system(size: 11).monospacedDigit())
                }
                .foregroundStyle(Theme.text3)
            }
            .buttonStyle(TextButtonStyle(font: .system(size: 11)))
            .help(tr("上下文用量与缓存", "Context and cache"))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                ContextDetail(report: report, record: chat.record, isRecording: chat.isRecording)
            }
        }
    }

    private struct Ring: View {
        let fraction: Double
        let busy: Bool

        var body: some View {
            ZStack {
                Circle().stroke(Theme.text3.opacity(0.3), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(fraction > 0.85 ? Theme.danger : Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
            .opacity(busy ? 0.5 : 1)
        }
    }
}

private struct ContextDetail: View {
    let report: ContextReport
    let record: StudyRecord?
    let isRecording: Bool
    @ViewState private var showRecord = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("上下文", "Context"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(summary)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.text3)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.label) { row in
                    PartRow(label: row.label, tokens: row.tokens, total: max(report.breakdown.total, 1), color: row.color)
                }
            }

            Divider()
            cache

            if record != nil || isRecording {
                Divider()
                recordSection
            }

            Button(tr("编辑学习档案…", "Edit study notes…")) { SettingsWindow.show(.notes) }
                .buttonStyle(TextButtonStyle(font: .system(size: 12)))
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(Theme.panel)
    }

    private var summary: String {
        let used = TokenEstimate.label(report.usage?.prompt ?? report.estimatedTokens)
        let fraction = StatsFormat.percent(report.windowFraction)
        return tr("上次请求约 \(used)，占上下文窗口 \(TokenEstimate.label(report.window)) 的 \(fraction)",
                  "Last request about \(used), \(fraction) of the \(TokenEstimate.label(report.window)) window")
    }

    private var rows: [(label: String, tokens: Int, color: Color)] {
        let scale = report.tokenScale
        let b = report.breakdown
        let items: [(String, Int, Color)] = [
            (tr("写作说明", "Instructions"), b.instructions, Theme.text3),
            (tr("学习档案", "Study notes"), b.memory, Theme.text2),
            (tr("课件", "Deck"), b.courseware, Theme.accent),
            (tr("学习记录", "Study record"), b.record, Theme.text2),
            (tr("历史对话", "Earlier messages"), b.history, Theme.text2),
            (tr("本轮提问", "This question"), b.question, Theme.text),
            (tr("页面截图", "Screenshot"), b.image, Theme.text3),
        ]
        return items.filter { $0.1 > 0 }.map { ($0.0, Int(Double($0.1) * scale), $0.2) }
    }

    @ViewBuilder
    private var cache: some View {
        // 每 30 秒刷新一次，判断缓存是否已过期
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(alignment: .leading, spacing: 4) {
                Text(cacheLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                if report.cacheLikelyExpired(at: timeline.date), let lifetime = report.cacheLifetime {
                    let minutes = Int(lifetime / 60)
                    Text(tr("距上次提问已超过 \(minutes) 分钟，缓存可能已失效，下次提问的课件部分将按全价计费。",
                            "Over \(minutes) min since the last request; the cache may have expired, so the deck will be billed at full price next time."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var cacheLine: String {
        guard let rate = report.cacheHitRate else { return tr("缓存：等待用量数据", "Cache: awaiting usage") }
        var line = tr("缓存命中 ", "Cache hit ") + StatsFormat.percent(rate)
        if let write = report.usage?.cacheWrite, write > 0 {
            line += tr(" · 写入 ", " · wrote ") + TokenEstimate.label(write)
        }
        return line
    }

    @ViewBuilder
    private var recordSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isRecording {
                Text(tr("正在将较早的对话整理为学习记录…", "Condensing earlier messages into a study record…"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
            }
            if let record {
                Button {
                    withAnimation(Motion.content) { showRecord.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(tr("学习记录：已整理较早的 \(record.messageCount) 条消息", "Study record: \(record.messageCount) earlier messages condensed"))
                        Image(systemName: showRecord ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .buttonStyle(TextButtonStyle(font: .system(size: 12)))
                if showRecord {
                    ScrollView {
                        Text(record.text)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.text2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
            }
        }
    }

    private struct PartRow: View {
        let label: String
        let tokens: Int
        let total: Int
        let color: Color

        var body: some View {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 70, alignment: .leading)
                GeometryReader { proxy in
                    Capsule()
                        .fill(color.opacity(0.75))
                        .frame(width: max(2, proxy.size.width * Double(tokens) / Double(total)))
                        .frame(maxHeight: .infinity)
                }
                .frame(height: 5)
                Text(TokenEstimate.label(tokens))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.text3)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}
