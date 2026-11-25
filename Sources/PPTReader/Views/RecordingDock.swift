import SwiftUI

/// 课件区底部居中的录音条：录音时是胶囊（时长、电平、暂停、停止、字幕、打开窗口），上方可以展开实时字幕；
/// 停止后变成几秒的提示。样式和“识别扫描页”的提示一致。
struct RecordingDock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lectures = model.lectures
        VStack(spacing: 8) {
            if lectures.isRecording {
                if lectures.showsCaptions, !(lectures.captionFinal.isEmpty && lectures.captionVolatile.isEmpty) {
                    CaptionCard(final: lectures.captionFinal, volatile: lectures.captionVolatile,
                                locale: lectures.recorder.recording?.locale ?? model.settings.recordingLocale)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                RecordingCapsule(lectures: lectures)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
            } else if let problem = lectures.problem {
                DockToast {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.danger)
                    Text(problem)
                        .lineLimit(2)
                    DockButton(title: tr("关闭", "Dismiss")) { lectures.dismissProblem() }
                }
                .transition(.opacity)
            } else if let saved = lectures.saved {
                let busy = lectures.transcription.isBusy(with: saved.id)
                DockToast {
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "checkmark.circle").foregroundStyle(Theme.accent)
                    }
                    Text(busy
                         ? tr("已保存 \(Self.length(saved.duration))的录音，正在转写…", "Saved \(Self.length(saved.duration)) of audio, transcribing…")
                         : tr("已保存 \(Self.length(saved.duration))的录音，转写完成", "Saved \(Self.length(saved.duration)) of audio, transcribed"))
                    DockButton(title: tr("查看", "View")) {
                        RecordingsWindow.shared.show(select: saved.id)
                        lectures.dismissSaved()
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.bottom, 16)
        .padding(.horizontal, 24)
        .animation(Motion.panel, value: lectures.isRecording)
        .animation(Motion.content, value: lectures.showsCaptions)
        .animation(Motion.content, value: lectures.saved)
        .animation(Motion.content, value: lectures.problem)
    }

    static func length(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return tr("不到 1 分钟", "under a minute") }
        if minutes < 60 { return tr("\(minutes) 分钟", "\(minutes) min") }
        let rest = minutes % 60
        return rest == 0 ? tr("\(minutes / 60) 小时", "\(minutes / 60) h") : tr("\(minutes / 60) 小时 \(rest) 分", "\(minutes / 60) h \(rest) min")
    }
}

/// 录音中的胶囊。
private struct RecordingCapsule: View {
    let lectures: LectureController

    var body: some View {
        let recorder = lectures.recorder
        let paused = recorder.state == .paused
        HStack(spacing: 2) {
            HStack(spacing: 8) {
                if paused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.text3)
                } else {
                    PulsingDot()
                }
                Text(Self.clock(recorder.elapsed))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                if paused {
                    Text(tr("已暂停", "Paused"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                } else if case .warning(let remaining) = recorder.limitStatus {
                    Text(tr("还剩 \(max(1, Int((remaining / 60).rounded(.up)))) 分钟", "\(max(1, Int((remaining / 60).rounded(.up)))) min left"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(Theme.accent.opacity(0.13)))
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)

            if !paused {
                LevelMeter(level: recorder.level)
                    .padding(.trailing, 6)
            }
            separator
            if paused {
                Button { lectures.resume() } label: {
                    Label(tr("继续", "Resume"), systemImage: "play.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .foregroundStyle(Theme.surface)
                        .background(Capsule().fill(Theme.text))
                }
                .buttonStyle(.plain)
                .help(tr("继续录音", "Resume recording"))
            } else {
                Button { lectures.pause() } label: { Label(tr("暂停", "Pause"), systemImage: "pause") }
                    .buttonStyle(IconButtonStyle(size: 30))
                    .help(tr("暂停录音（暂停时退出也不会丢失）", "Pause recording (nothing is lost if you quit while paused)"))
            }
            Button { lectures.stop() } label: {
                Label {
                    Text(tr("停止", "Stop"))
                } icon: {
                    Image(systemName: "stop.fill").foregroundStyle(Theme.danger)
                }
            }
            .buttonStyle(IconButtonStyle(size: 30))
            .help(tr("停止并保存", "Stop and save") + ShortcutStore.shared.hint(.record))
            separator
            Button { lectures.showsCaptions.toggle() } label: {
                Label(tr("实时字幕", "Live captions"), systemImage: "captions.bubble")
            }
            .buttonStyle(IconButtonStyle(isOn: lectures.showsCaptions, size: 30))
            .help(lectures.showsCaptions ? tr("隐藏实时字幕", "Hide live captions") : tr("显示实时字幕", "Show live captions"))
            Button { RecordingsWindow.shared.show(select: recorder.recording?.id) } label: {
                Label(tr("课堂录音", "Lectures"), systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(IconButtonStyle(size: 30))
            .help(tr("打开「课堂录音」", "Open Lectures") + ShortcutStore.shared.hint(.recordings))
        }
        .padding(.trailing, 4)
        .frame(height: 38)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }

    private var separator: some View {
        Rectangle().fill(Theme.border).frame(width: 1, height: 18).padding(.horizontal, 4)
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }
}

/// 实时字幕：最多三行，只显示最后的部分；还会变的文字颜色浅。
private struct CaptionCard: View {
    let final: String
    let volatile: String
    let locale: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("实时字幕", "Live captions") + " · " + LectureController.localeTitle(locale))
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
            (Text(final).foregroundColor(Theme.text) + Text(volatile.isEmpty ? "" : " " + volatile).foregroundColor(Theme.text3))
                .font(.system(size: 14))
                .lineSpacing(3)
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }
}

/// 输入电平：五根竖条，高低错开。
private struct LevelMeter: View {
    let level: Float
    private static let shape: [CGFloat] = [0.45, 0.75, 1, 0.65, 0.4]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.shape.indices, id: \.self) { i in
                Capsule()
                    .fill(Theme.text2.opacity(0.55))
                    .frame(width: 2.5, height: max(3, 16 * CGFloat(level) * Self.shape[i]))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}

/// 录音中的红点，慢慢闪；开了“减少动态效果”时不闪。
private struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var dim = false

    var body: some View {
        Circle()
            .fill(Theme.danger)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// 停止后、出错时的提示条。
private struct DockToast<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.text)
            .padding(.leading, 14)
            .padding(.trailing, 5)
            .frame(minHeight: 38)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }
}

private struct DockButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(Theme.hover))
        }
        .buttonStyle(.plain)
    }
}

/// 工具栏里的麦克风：点一下开始 / 停止，右键可以换转写语言、打开「课堂录音」。
struct RecordButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lectures = model.lectures
        let recording = lectures.isRecording
        Button { lectures.toggle() } label: {
            Label {
                Text(recording ? tr("停止录音", "Stop Recording") : tr("开始录音", "Start Recording"))
            } icon: {
                Image(systemName: recording ? "mic.fill" : "mic")
                    .foregroundStyle(recording ? Theme.danger : Theme.text2)
            }
        }
        .buttonStyle(IconButtonStyle())
        .help((recording ? tr("停止录音", "Stop recording") : tr("开始录音（右键选择转写语言）", "Start recording (right-click to choose the transcription language)"))
              + ShortcutStore.shared.hint(.record))
        .contextMenu { RecordingMenuItems() }
    }
}

/// 工具栏右键菜单和菜单栏「录音」菜单共用的项目。
struct RecordingMenuItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lectures = model.lectures
        Button(lectures.isRecording ? tr("停止录音", "Stop Recording") : tr("开始录音", "Start Recording")) { lectures.toggle() }
        if lectures.isRecording {
            Button(lectures.recorder.state == .paused ? tr("继续录音", "Resume Recording") : tr("暂停录音", "Pause Recording")) {
                lectures.recorder.state == .paused ? lectures.resume() : lectures.pause()
            }
        }
        Divider()
        Picker(tr("转写语言", "Transcription Language"), selection: Binding(
            get: { model.settings.recordingLocale }, set: { model.settings.recordingLocale = $0 })) {
            ForEach(LectureController.locales, id: \.id) { locale in
                Text(locale.title).tag(locale.id)
            }
        }
        .disabled(lectures.isRecording)
        Divider()
        Button(tr("打开「课堂录音」", "Open Lectures")) { RecordingsWindow.shared.show() }
    }
}
