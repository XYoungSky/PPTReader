import AppKit
import Foundation
import Testing
@testable import PPTReader

/// 课堂录音的「AI 整理」：转写的切分、找课件、请求内容、解析结果，以及用假的模型跑一遍完整流程。
@Suite("课堂录音：AI 整理")
@MainActor
struct LectureOrganizerTests {
    private typealias O = LectureOrganizer

    private func lines(_ times: [Double]) -> [O.TimedLine] {
        times.map { O.TimedLine(time: $0, text: "sentence at \(Int($0))") }
    }

    /// 写一份每页一行文字的 PDF。
    private func makePDF(_ url: URL, pages: [String]) {
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(at: CGPoint(x: 20, y: 250), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PPTReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    // MARK: - 转写

    @Test("时间的写法：mm:ss、h:mm:ss、带括号、秒数；读不出时为空")
    func times() {
        #expect(O.clock(65) == "01:05")
        #expect(O.clock(3725) == "1:02:05")
        #expect(O.seconds(from: "12:05") == 725)
        #expect(O.seconds(from: "[1:02:05]") == 3725)
        #expect(O.seconds(from: NSNumber(value: 42)) == 42)
        #expect(O.seconds(from: "soon") == nil)
        #expect(O.seconds(from: nil) == nil)
    }

    @Test("按 10 分钟切段；摘录每段只取开头，总长有上限")
    func chunking() {
        let all = lines(Array(stride(from: 0.0, to: 1800, by: 20)))
        let parts = O.chunks(all)
        #expect(parts.count == 3)
        #expect(parts.map { $0.first!.time } == [0, 600, 1200])
        #expect(O.chunks([]).isEmpty)

        let excerpt = O.excerpt(all, limit: 1_500)
        #expect(excerpt.count < 1_700)
        #expect(excerpt.contains("[00:00]") && excerpt.contains("[10:00]") && excerpt.contains("[20:00]"))

        let budgeted = O.parts(all, budget: 200)
        #expect(budgeted.count > 1)
        #expect(budgeted.flatMap { $0 } == all)
    }

    // MARK: - 课件

    @Test("课程文件夹里的课件：同一个文件夹的排前面；跳过隐藏文件和 Office 锁文件；没转换过的 PPT 读不到文字")
    func candidates() async throws {
        try await withDirectory { course in
            let lectures = course.appendingPathComponent("Lectures")
            let tutorials = course.appendingPathComponent("Tutorial")
            for folder in [lectures, tutorials] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            makePDF(lectures.appendingPathComponent("01-intro.pdf"), pages: ["Intro to OS", "History"])
            makePDF(tutorials.appendingPathComponent("T09.pdf"), pages: ["Tutorial 9 scheduling"])
            try Data("x".utf8).write(to: tutorials.appendingPathComponent("T10.pptx"))
            try Data("x".utf8).write(to: tutorials.appendingPathComponent("~$T10.pptx"))
            try Data("x".utf8).write(to: tutorials.appendingPathComponent(".hidden.pdf"))
            try Data("x".utf8).write(to: course.appendingPathComponent("notes.txt"))

            let found = O.candidates(course: course, recordedDeck: tutorials.appendingPathComponent("T09.pdf").path)
            #expect(found.map(\.title) == ["T09", "T10", "01-intro"])
            #expect(found.map(\.folder) == ["Tutorial", "Tutorial", "Lectures"])
            #expect(found.map(\.readable) == [true, false, true])
            #expect(found[0].head.contains("Tutorial 9"))
            #expect(found[2].head.contains("Intro to OS") && found[2].head.contains("History"))
            #expect(O.candidates(course: course, recordedDeck: nil, limit: 1).count == 1)
        }
    }

    // MARK: - 第 1 步

    private let decks = [
        O.Candidate(path: "/c/a.pdf", title: "a", folder: "Lectures", head: "Processes", readable: true),
        O.Candidate(path: "/c/b.pdf", title: "b", folder: "", head: "", readable: true),
    ]

    private func recording(deck: String? = "/c/a.pdf") -> Recording {
        Recording(id: "r", title: "Week 4", startedAt: Date(), coursePath: "/c", deckPath: deck, locale: "en_US", bitRate: 32_000,
                  segments: [.init(index: 1, startedAt: Date(), duration: 600, state: .complete, transcribed: true),
                             .init(index: 2, startedAt: Date(), duration: 600, state: .complete, transcribed: true)])
    }

    @Test("判断相关课件的请求：列出编号、文件夹、开头的文字，标出录音时打开的那份")
    func deckRequest() throws {
        let messages = O.deckMessages(recording: recording(), excerpt: "[00:01] hi", candidates: decks, english: false)
        let user = try #require(messages.last?["content"] as? String)
        #expect(user.contains("[1] a（文件夹：Lectures） —— 录音时打开的课件\nProcesses"))
        #expect(user.contains("[2] b\n（读不到文字）"))
        #expect(user.contains("<transcript_excerpt>\n[00:01] hi"))
        #expect((messages.first?["content"] as? String)?.contains("\"decks\"") == true)
    }

    @Test("读出相关课件：编号可以是字符串，越界和重复的去掉，读不出时为空")
    func parseDecks() {
        let choices = O.parseDecks(#"好的：{"decks":[{"id":"2","reason":"讲了 b"},{"id":7},{"id":2},{"id":1}]}"#, candidates: decks)
        #expect(choices == [O.Choice(path: "/c/b.pdf", reason: "讲了 b"), O.Choice(path: "/c/a.pdf", reason: "")])
        #expect(O.parseDecks("[1]", candidates: decks) == [O.Choice(path: "/c/a.pdf", reason: "")])
        #expect(O.parseDecks(#"{"decks":[]}"#, candidates: decks) == [])
        #expect(O.parseDecks("没有", candidates: decks) == nil)
    }

    // MARK: - 第 2 步

    private let alignDecks = [
        O.Deck(path: "/c/a.pdf", title: "a", pages: ["Process states", String(repeating: "x", count: 3_000), ""]),
        O.Deck(path: "/c/b.pdf", title: "b", pages: ["Threads"]),
    ]

    @Test("补充要点的前缀：每份课件一个 id，按页标出页码，长页截断，空页说明")
    func supplementPrefix() {
        let system = O.supplementSystem(decks: alignDecks, pageLimit: 1_000, english: false)
        #expect(system.contains("<deck id=\"1\" title=\"a\">\n【第 1 页】\nProcess states"))
        #expect(system.contains("<deck id=\"2\" title=\"b\">\n【第 1 页】\nThreads"))
        #expect(system.contains("【第 3 页】\n（这一页没有文字）"))
        #expect(!system.contains(String(repeating: "x", count: 1_001)))
        #expect(O.supplementSystem(decks: alignDecks, pageLimit: 100, english: true).contains("[Page 1]\nProcess states"))
    }

    @Test("读出补充要点：课件缺省是第一份；越界的页当作课件以外；时间读不出或离这一段太远时用段首")
    func parseSupplements() throws {
        let part = lines([600, 700, 1190])
        let output = """
        ```json
        {"supplements":[
          {"deck":2,"page":1,"point":"线程共享地址空间","quote":"threads share","start":"11:40"},
          {"page":"2","point":"考试会考","quote":"exam","start":"99:00"},
          {"deck":1,"page":40,"point":"课件外的例子","quote":"","start":620},
          {"page":1,"point":"  "}
        ]}
        ```
        """
        let items = try #require(O.parseSupplements(output, decks: alignDecks, part: part))
        #expect(items.count == 3)
        #expect(items[0] == O.Supplement(deck: "/c/b.pdf", page: 1, point: "线程共享地址空间", quote: "threads share", time: 700))
        #expect(items[1].deck == "/c/a.pdf" && items[1].page == 2 && items[1].time == 600)
        #expect(items[2].deck == nil && items[2].page == nil && items[2].time == 620)
        #expect(O.parseSupplements("[]", decks: alignDecks, part: part) == [])
        #expect(O.parseSupplements("no", decks: alignDecks, part: part) == nil)
    }

    // MARK: - 第 3 步

    @Test("笔记的请求带上课件以外的要点；分部分时说明是第几部分；去掉代码块标记")
    func notes() throws {
        let extra = [O.Supplement(deck: nil, page: nil, point: "Linux 用四级页表", quote: "", time: 65)]
        let messages = O.notesMessages(recording: recording(), decks: ["a", "b"], lines: lines([5]), supplements: extra,
                                       english: false, part: (2, 3))
        let user = try #require(messages.last?["content"] as? String)
        #expect(user.contains("相关课件：a、b"))
        #expect(user.contains("第 2/3 部分"))
        #expect(user.contains("- [01:05] (课件以外) Linux 用四级页表"))
        #expect(user.contains("<transcript>\n[00:05] sentence at 5\n</transcript>"))
        #expect(O.cleanNotes("```markdown\n# 笔记\n- a\n```") == "# 笔记\n- a")
        #expect(O.cleanNotes("  ## 直接写的\n") == "## 直接写的")
    }

    @Test("整理结果存进录音文件夹，清单里记下相关课件")
    func store() async throws {
        try await withDirectory { root in
            let store = RecordingStore(root: root)
            let r = try store.create(title: "r", coursePath: nil, deckPath: nil, locale: "en_US", bitRate: 32_000)
            #expect(store.notes(r.id) == nil && store.organized(r.id) == nil)
            let result = O.Result(decks: ["/c/a.pdf"], supplements: [O.Supplement(deck: "/c/a.pdf", page: 3, point: "p", quote: "q", time: 9)],
                                  createdAt: Date(timeIntervalSince1970: 1_764_000_000))
            try store.saveOrganized(result, notes: "# n", for: r.id)
            #expect(store.notes(r.id) == "# n")
            #expect(store.organized(r.id) == result)
            #expect(store.load(r.id)?.relatedDecks == ["/c/a.pdf"])
        }
    }

    // MARK: - 完整流程

    @Test("用假的模型跑一遍：找出两份课件让用户确认，逐段找补充要点，写笔记并保存")
    func fullRun() async throws {
        try await withDirectory { root in
            let course = root.appendingPathComponent("OS")
            try FileManager.default.createDirectory(at: course, withIntermediateDirectories: true)
            let deckA = course.appendingPathComponent("04-processes.pdf")
            let deckB = course.appendingPathComponent("05-scheduling.pdf")
            makePDF(deckA, pages: ["Process control block and its fields", "Context switch between two processes"])
            makePDF(deckB, pages: ["Round robin scheduling with a time quantum"])
            makePDF(course.appendingPathComponent("01-intro.pdf"), pages: ["Intro"])

            let store = RecordingStore(root: root.appendingPathComponent("Recordings"))
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
            var r = try store.create(title: "Week 4", coursePath: course.path, deckPath: deckA.path, locale: "en_US", bitRate: 32_000)
            r.segments = [.init(index: 1, startedAt: Date(), duration: 600, state: .complete, transcribed: true),
                          .init(index: 2, startedAt: Date(), duration: 300, state: .complete, transcribed: true)]
            try store.save(r)
            try store.appendTranscript([
                TranscriptLine(segment: 1, start: 5, end: 8, text: "The PCB stores the registers."),
                TranscriptLine(segment: 1, start: 400, end: 405, text: "This is not on the slides: exam question."),
                TranscriptLine(segment: 2, start: 10, end: 14, text: "Round robin uses a quantum."),
            ], to: r.id)

            let name = "PPTReaderTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let controller = LectureController(settings: AppSettings(defaults: defaults),
                                               stats: StatsStore(fileURL: root.appendingPathComponent("Stats.json")), store: store)
            var calls: [(ModelTask, String)] = []
            controller.completion = { task, messages in
                let user = messages.last?["content"] as? String ?? ""
                calls.append((task, user))
                let text: String
                switch task {
                case .lectureDecks:
                    // 列表顺序：录音时打开的那份所在的文件夹里，按名字排
                    #expect(user.contains("[2] 04-processes") && user.contains("[3] 05-scheduling"))
                    text = #"{"decks":[{"id":2,"reason":"PCB"},{"id":3,"reason":"round robin"}]}"#
                case .lectureSupplements:
                    text = user.contains(" 1/2")
                        ? #"{"supplements":[{"deck":1,"page":1,"point":"PCB 存寄存器","quote":"The PCB","start":"00:05"},{"page":null,"point":"考试会考","quote":"exam","start":"06:40"}]}"#
                        : #"{"supplements":[{"deck":2,"page":1,"point":"时间片","quote":"quantum","start":"10:10"}]}"#
                default:
                    #expect(user.contains("考试会考"))
                    text = "```markdown\n## 笔记（00:05）\n- 要点\n```"
                }
                return LLMTask.Output(text: text, usage: nil, truncated: false)
            }

            controller.organize(r.id)
            while controller.organizeTasks[r.id] != nil { await Task.yield() }
            guard case .choosing(let options) = controller.organizing[r.id] else {
                Issue.record("没有进入确认课件的阶段：\(String(describing: controller.organizing[r.id]))")
                return
            }
            #expect(options.filter(\.suggested).map(\.candidate.title) == ["04-processes", "05-scheduling"])
            #expect(options.first?.reason == "PCB")

            controller.confirmOrganize(r.id, decks: [deckA.path, deckB.path])
            while controller.organizeTasks[r.id] != nil { await Task.yield() }
            #expect(controller.organizing[r.id] == nil)
            #expect(calls.map(\.0) == [.lectureDecks, .lectureSupplements, .lectureSupplements, .lectureNotes])

            let result = try #require(store.organized(r.id))
            #expect(result.decks == [deckA.path, deckB.path])
            #expect(result.supplements.map(\.point) == ["PCB 存寄存器", "考试会考", "时间片"])
            #expect(result.supplements.map(\.time) == [5, 400, 610])
            #expect(result.supplements.last?.deck == deckB.path)
            #expect(store.notes(r.id) == "## 笔记（00:05）\n- 要点")
            #expect(store.load(r.id)?.relatedDecks == [deckA.path, deckB.path])
        }
    }

    @Test("模型的回答读不出来时停在“失败”，可以重试")
    func failure() async throws {
        try await withDirectory { root in
            let store = RecordingStore(root: root)
            var r = try store.create(title: "r", coursePath: nil, deckPath: nil, locale: "en_US", bitRate: 32_000)
            r.segments = [.init(index: 1, startedAt: Date(), duration: 60, state: .complete, transcribed: true)]
            try store.save(r)
            try store.appendTranscript([TranscriptLine(segment: 1, start: 1, end: 2, text: "hi")], to: r.id)
            let name = "PPTReaderTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let controller = LectureController(settings: AppSettings(defaults: defaults),
                                               stats: StatsStore(fileURL: root.appendingPathComponent("Stats.json")), store: store)
            controller.completion = { _, _ in LLMTask.Output(text: "{\"supplements\":", usage: nil, truncated: true) }
            // 没有课件：只写笔记，模型的回答当作笔记原样保存
            controller.confirmOrganize(r.id, decks: [])
            while controller.organizeTasks[r.id] != nil { await Task.yield() }
            #expect(store.notes(r.id) == "{\"supplements\":")

            // 对照课件时读不出 JSON：失败
            let deck = root.appendingPathComponent("a.pdf")
            makePDF(deck, pages: ["A page with enough text to skip OCR"])
            controller.confirmOrganize(r.id, decks: [deck.path])
            while controller.organizeTasks[r.id] != nil { await Task.yield() }
            guard case .failed(let message) = controller.organizing[r.id] else {
                Issue.record("应该失败")
                return
            }
            #expect(message.contains("截断") || message.contains("cut off"))
            controller.cancelOrganize(r.id)
            #expect(controller.organizing[r.id] == nil)
        }
    }
}
