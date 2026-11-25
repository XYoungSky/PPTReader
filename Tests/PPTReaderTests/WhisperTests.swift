import Foundation
import Testing
@testable import PPTReader

/// 本机 Whisper：句段整理（去掉幻觉和复读）、语言代码，以及设置里的识别方式。
@Suite("课堂录音：Whisper")
struct WhisperTests {
    @Test("句段 → 句子：去掉空的、只有标点或标记的、特殊记号，按时间排")
    func lines() {
        let lines = WhisperEngine.lines([
            .init(start: 12.0, end: 15.5, text: " ICT2 is on Tuesday of week 13. "),
            .init(start: 3.0, end: 6.0, text: "<|startoftranscript|>Turing machines up to Rice's theorem."),
            .init(start: 7.0, end: 9.0, text: " [BLANK_AUDIO] "),
            .init(start: 9.0, end: 10.0, text: "(music)"),
            .init(start: 10.0, end: 9.5, text: " . "),
            .init(start: 20.0, end: 19.0, text: "Six questions, 80 minutes."),
        ])
        #expect(lines.map(\.text) == ["Turing machines up to Rice's theorem.", "ICT2 is on Tuesday of week 13.", "Six questions, 80 minutes."])
        #expect(lines.map(\.start) == [3, 12, 20])
        #expect(lines.allSatisfy { $0.end >= $0.start })
    }

    @Test("去掉幻觉：没人说话又没把握的句段（安静处的 Thank you.），以及紧挨着的重复句；隔得远的重复保留")
    func dropsHallucinations() {
        let lines = WhisperEngine.lines([
            .init(start: 60, end: 62, text: " Thank you.", noSpeech: 0.9, logProb: -1.4),
            .init(start: 70, end: 72, text: " Thank you.", noSpeech: 0.1, logProb: -0.3),
            .init(start: 900, end: 901, text: " Okay."),
            .init(start: 901, end: 902, text: " Okay."),
            .init(start: 902.5, end: 903, text: " okay."),
            .init(start: 930, end: 931, text: " Okay."),
        ])
        #expect(lines.map(\.text) == ["Thank you.", "Okay.", "Okay."])
        #expect(lines[1].start == 900 && lines[1].end == 903)
        #expect(lines[2].start == 930)
    }

    @Test("录音的语言 → Whisper 的语言代码")
    func language() {
        #expect(WhisperEngine.language(for: "en_US") == "en")
        #expect(WhisperEngine.language(for: "en_GB") == "en")
        #expect(WhisperEngine.language(for: "zh_CN") == "zh")
    }

    @Test("复读：压缩比过高的句段去掉；一句里连续重复三遍以上的短句只留一遍")
    func dropsRepeats() {
        let lines = WhisperEngine.lines([
            .init(start: 27, end: 50, text: " So point 1. So point 1. So point 1. So point 1. Past papers.", compression: 3.1),
            .init(start: 53, end: 60, text: " Okay. Okay. Okay. Let's start with Turing machines."),
            .init(start: 61, end: 62, text: " Yes, yes, that is right."),
        ])
        #expect(lines.map(\.text) == ["Okay. Let's start with Turing machines.", "Yes, yes, that is right."])
    }

    @Test("识别方式保存为 whisper，读回来不变")
    @MainActor
    func engineSetting() {
        let name = "PPTReaderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        AppSettings(defaults: defaults).transcriptionEngine = .whisper
        #expect(AppSettings(defaults: defaults).transcriptionEngine == .whisper)
    }
}
