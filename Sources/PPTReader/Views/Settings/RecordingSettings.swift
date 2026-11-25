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
                         footer: tr("转写在本机离线完成，录音不会上传。识别方式“听写”会参考当前课件里的术语（缩写、人名），句子由 PPTReader 按停顿和标点切分；哪种更准和老师的口音、录音环境有关，可以都试试。改动从下一次录音开始生效。",
                                    "Transcription runs on this Mac and nothing is uploaded. Dictation uses the open deck's terms (acronyms, names) and PPTReader splits its sentences; which one is more accurate depends on the lecturer and the room, so try both. Changes apply from the next recording.")) {
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
                SettingsRow(title: tr("识别方式", "Recognizer"), divider: false) {
                    SegmentedPicker(selection: Binding(get: { settings.transcriptionEngine }, set: { value in
                        settings.transcriptionEngine = value
                        lectures.transcription.engine = value
                    }), options: [(.speech, tr("标准", "Standard")), (.dictation, tr("听写（参考课件术语）", "Dictation (uses deck terms)"))])
                }
            }

            SettingsCard(title: tr("录音", "Recording")) {
                SettingsRow(title: tr("音质", "Quality"),
                            detail: settings.recordingBitRate == 64_000 ? tr("3 小时约 90 MB", "About 90 MB for 3 hours") : tr("3 小时约 46 MB，转写够用", "About 46 MB for 3 hours, enough for transcription")) {
                    SegmentedPicker(selection: $settings.recordingBitRate, options: [(32_000, tr("标准 32 kbps", "Standard 32 kbps")), (64_000, tr("高 64 kbps", "High 64 kbps"))])
                }
                SettingsRow(title: tr("时长上限", "Length limit"),
                            detail: tr("到点前 5 分钟提醒，到点自动停止并保存", "A reminder 5 minutes before; stops and saves when reached")) {
                    SegmentedPicker(selection: $settings.recordingLimitHours, options: [1, 2, 3, 4, 6].map { ($0, tr("\($0) 小时", "\($0) h")) })
                }
                SettingsRow(title: tr("课件上的批注", "Notes on slides"),
                            detail: tr("整理出的补充要点和课程安排显示在对应页的页边，点一下跳到录音；不改原文件", "Organized supplements and arrangements appear in the margin of their pages; click to jump to the recording. Files aren't changed")) {
                    Toggle("", isOn: Binding(get: { settings.showLectureAnnotations }, set: { value in
                        settings.showLectureAnnotations = value
                        model.refreshAnnotations()
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
                SettingsRow(title: tr("实时字幕", "Live captions"), detail: tr("录音时在录音条上方显示", "Shown above the recording bar while recording")) {
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
                         footer: tr("录音、转写和整理结果都保存在 PPTReader 的数据里，课程文件夹不会被修改。单条录音可以在「课堂录音」窗口里删除。",
                                    "Audio, transcripts and organized results are stored in PPTReader's data; the course folder is never changed. Delete individual recordings in the Lectures window.")) {
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
            size = tr("\(count) 条录音，", "\(count) recordings, ") + ByteCountFormatter.string(fromByteCount: RecordingStore.shared.size(), countStyle: .file)
            device = AVCaptureDevice.default(for: .audio)?.localizedName ?? tr("没有找到输入设备", "No input device found")
        }
    }
}
