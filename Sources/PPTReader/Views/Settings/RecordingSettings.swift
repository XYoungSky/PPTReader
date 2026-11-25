import AppKit
import AVFoundation
import SwiftUI

/// 课堂录音：转写语言和识别方式、音质、时长上限、实时字幕、输入设备、占用空间。
struct RecordingSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @ViewState private var size = ""
    @ViewState private var device = ""

    var body: some View {
        @Bindable var settings = settings
        let lectures = model.lectures
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(title: tr("转写", "Transcription"),
                         footer: tr("在本机离线转写，录音不会上传。", "Transcribed offline on this Mac. Audio is never uploaded.")) {
                SettingsRow(title: tr("转写语言", "Language")) {
                    PopMenuButton(trailing: true, style: OutlineButtonStyle()) {
                        LectureController.locales.map { locale in
                            PopMenuItem(locale.title, checked: settings.recordingLocale == locale.id) { settings.recordingLocale = locale.id }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(LectureController.localeTitle(settings.recordingLocale))
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                    }
                    .fixedSize()
                }
                let whisper = WhisperModel.shared
                let showsWhisper = settings.transcriptionEngine == .whisper || whisper.state != .missing
                SettingsRow(title: tr("识别方式", "Recognizer"),
                            help: tr("标准：系统识别，速度快。\n听写：参考当前课件中的术语，适合安静、近距离的场景；距离较远或有噪音时可能遗漏大量内容。\nWhisper：在本机运行的 OpenAI 模型，口音重、距离远或有噪音时更准确，需先下载模型。\n更改从下一次录音起生效；已有的录音可在「课堂录音」窗口中重新转写。",
                                     "Standard: the system recognizer; fast.\nDictation: uses terms from the open deck; suited to quiet rooms close to the speaker. At a distance or with noise it may miss much of the speech.\nWhisper: an OpenAI model running on this Mac; more accurate with accents, distance or noise. Download the model first.\nChanges apply from the next recording; existing recordings can be re-transcribed in the Lectures window."),
                            divider: showsWhisper) {
                    SegmentedPicker(selection: Binding(get: { settings.transcriptionEngine }, set: { value in
                        settings.transcriptionEngine = value
                        lectures.transcription.engine = value
                    }), options: [(.speech, tr("标准", "Standard")), (.dictation, tr("听写", "Dictation")), (.whisper, "Whisper")])
                }
                if showsWhisper {
                    WhisperModelRow(model: whisper)
                        .transition(.opacity)
                }
            }
            .animation(Motion.content, value: settings.transcriptionEngine)

            SettingsCard(title: tr("录音", "Recording")) {
                SettingsRow(title: tr("音质", "Quality"),
                            detail: settings.recordingBitRate == 64_000 ? tr("3 小时约 90 MB", "About 90 MB for 3 hours") : tr("3 小时约 46 MB", "About 46 MB for 3 hours")) {
                    SegmentedPicker(selection: $settings.recordingBitRate, options: [(32_000, tr("标准 32 kbps", "Standard 32 kbps")), (64_000, tr("高 64 kbps", "High 64 kbps"))])
                }
                SettingsRow(title: tr("时长上限", "Length limit"),
                            detail: tr("结束前 5 分钟提醒", "Reminder 5 minutes before"),
                            help: tr("达到上限后自动停止并保存。", "Recording stops and is saved when the limit is reached.")) {
                    SegmentedPicker(selection: $settings.recordingLimitHours, options: [1, 2, 3, 4, 6].map { ($0, tr("\($0) 小时", "\($0) h")) })
                }
                SettingsRow(title: tr("课件上的批注", "Notes on slides"),
                            detail: tr("在对应页显示整理结果", "Show organized notes on matching pages"),
                            help: tr("补充要点和课程安排显示在对应页的页边，点按可跳转到录音位置。原文件不会被修改。",
                                     "Supplements and course arrangements appear in the margin of matching pages; click one to jump to that point in the recording. The original file is not modified.")) {
                    Toggle("", isOn: Binding(get: { settings.showLectureAnnotations }, set: { value in
                        settings.showLectureAnnotations = value
                        model.refreshAnnotations()
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
                SettingsRow(title: tr("实时字幕", "Live captions"), detail: tr("显示在录音条上方", "Shown above the recording bar")) {
                    Toggle("", isOn: Binding(get: { lectures.showsCaptions }, set: { lectures.showsCaptions = $0 }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                SettingsRow(title: tr("输入设备", "Input device"), detail: device, divider: false) {
                    Button(tr("声音设置…", "Sound Settings…")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
            }

            SettingsCard(title: tr("存储", "Storage"),
                         help: tr("录音、转写和整理结果保存在 PPTReader 的数据目录中。单条录音可在「课堂录音」窗口中删除。",
                                  "Audio, transcripts and organized results are stored in PPTReader's data folder. Delete individual recordings in the Lectures window.")) {
                SettingsRow(title: tr("课堂录音", "Lectures"), detail: size, divider: false) {
                    HStack(spacing: 8) {
                        Button(tr("打开", "Open")) { RecordingsWindow.shared.show() }
                            .buttonStyle(OutlineButtonStyle())
                        Button(tr("在访达中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([RecordingStore.shared.root]) }
                            .buttonStyle(OutlineButtonStyle())
                    }
                }
            }
        }
        .onAppear {
            let count = RecordingStore.shared.all().count
            size = tr("\(count) 条录音 · ", "\(count) recordings · ") + ByteCountFormatter.string(fromByteCount: RecordingStore.shared.size(), countStyle: .file)
            device = AVCaptureDevice.default(for: .audio)?.localizedName ?? tr("未找到输入设备", "No input device")
        }
    }
}

/// Whisper 模型：下载、进度、删除。
private struct WhisperModelRow: View {
    let model: WhisperModel
    @ViewState private var size = ""

    var body: some View {
        SettingsRow(title: tr("Whisper 模型", "Whisper model"), detail: detail, detailColor: failed ? Theme.danger : Theme.text3,
                    help: tr("OpenAI 的开源语音识别模型（large-v3 turbo），在本机运行，录音不会上传。模型从 Hugging Face 下载，约 650 MB；未下载时按「标准」方式转写。",
                             "OpenAI's open-source speech model (large-v3 turbo), running on this Mac; audio is never uploaded. The model (about 650 MB) is downloaded from Hugging Face; until then, Standard is used."),
                    divider: false) {
            switch model.state {
            case .missing, .failed:
                Button(tr("下载", "Download")) { model.download() }
                    .buttonStyle(OutlineButtonStyle())
            case .downloading(let fraction):
                HStack(spacing: 10) {
                    ProgressView(value: fraction)
                        .tint(Theme.accent)
                        .frame(width: 120)
                    Button(tr("取消", "Cancel")) { model.cancel() }
                        .buttonStyle(OutlineButtonStyle())
                }
            case .preparing:
                ProgressView().controlSize(.small)
            case .ready:
                Button(tr("删除…", "Delete…")) { confirmDelete() }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
        .onAppear(perform: measure)
        .onChange(of: model.state) { _, _ in measure() }
    }

    private var failed: Bool { if case .failed = model.state { true } else { false } }

    private var detail: String {
        switch model.state {
        case .missing: tr("未下载 · 约 650 MB", "Not downloaded · about 650 MB")
        case .downloading(let fraction): tr("正在下载 \(Int(fraction * 100))%", "Downloading \(Int(fraction * 100))%")
        case .preparing: tr("正在准备模型，首次约需三分钟", "Preparing the model; the first time takes about three minutes")
        case .ready: tr("已下载", "Downloaded") + (size.isEmpty ? "" : " · " + size)
        case .failed(let message): tr("下载失败：", "Download failed: ") + message
        }
    }

    private func measure() {
        guard model.state == .ready else { size = ""; return }
        Task.detached {
            let bytes = WhisperModel.size()
            let text = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            await MainActor.run { size = text }
        }
    }

    private func confirmDelete() {
        PopMenu.shared.show([
            .header(tr("删除后需重新下载才能使用 Whisper", "You'll need to download it again to use Whisper")),
            PopMenuItem(tr("删除 Whisper 模型", "Delete Whisper Model"), icon: "trash", destructive: true) { model.delete() },
            PopMenuItem(tr("取消", "Cancel"), icon: "xmark") {},
        ], placement: .at(NSEvent.mouseLocation), in: NSApp.keyWindow, minWidth: 220)
    }
}
