import AppKit
import Foundation
import Testing
@testable import PPTReader

/// 课堂录音的「AI 整理」（只找课件上没有的内容和课程安排，不写笔记）：转写的切分、找课件、请求内容、解析结果，
/// 以及用假的模型跑一遍完整流程。
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
        #expect(user.contains("课程文件夹：c\n"))
        #expect((messages.first?["content"] as? String)?.contains("\"course\"") == true)
    }

    @Test("读出课程编号：去掉空格、转大写；太长、没有数字的不算")
    func parseCourse() {
        #expect(O.parseCourse(#"{"course":"comp 3021","decks":[]}"#) == "COMP3021")
        #expect(O.parseCourse(#"{"course":null,"decks":[]}"#) == nil)
        #expect(O.parseCourse(#"{"course":"Operating Systems"}"#) == nil)
        #expect(O.parseCourse(#"{"decks":[]}"#) == nil)
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
        #expect(system.contains("\"supplement\"") && system.contains("\"arrangement\"") && !system.contains("笔记"))
        // 没有课件：只找课程安排，不带课件
        let arrangements = O.supplementSystem(decks: [], pageLimit: 1_000, english: false)
        #expect(arrangements.contains("课程安排") && !arrangements.contains("<courseware>"))
    }

    @Test("读出结果：两种类型；课件缺省是第一份；越界的页当作对不上；时间读不出或离这一段太远时用段首；没有课件时都是课程安排")
    func parseSupplements() throws {
        let part = lines([600, 700, 1190])
        let output = """
        ```json
        {"items":[
          {"kind":"supplement","deck":2,"page":1,"point":"线程共享地址空间","quote":"threads share","start":"11:40"},
          {"kind":"arrangement","page":"2","point":"考试会考这一页","quote":"exam","start":"99:00"},
          {"deck":1,"page":40,"point":"课件外的例子","quote":"","start":620},
          {"kind":"Arrangement","page":null,"point":"作业推迟到周五","start":"19:00"},
          {"page":1,"point":"  "}
        ]}
        ```
        """
        let items = try #require(O.parseSupplements(output, decks: alignDecks, part: part))
        #expect(items.count == 4)
        #expect(items[0] == O.Supplement(kind: .supplement, deck: "/c/b.pdf", page: 1, point: "线程共享地址空间", quote: "threads share", time: 700))
        #expect(items[1].kind == .arrangement && items[1].deck == "/c/a.pdf" && items[1].page == 2 && items[1].time == 600)
        #expect(items[2].kind == .supplement && items[2].deck == nil && items[2].page == nil && items[2].time == 620)
        #expect(items[3].kind == .arrangement && items[3].time == 1140)
        // 旧的键名和顶层数组也认
        #expect(O.parseSupplements(#"{"supplements":[{"point":"p"}]}"#, decks: alignDecks, part: part)?.count == 1)
        #expect(O.parseSupplements("[]", decks: alignDecks, part: part) == [])
        #expect(O.parseSupplements("no", decks: alignDecks, part: part) == nil)
        // 没有课件：都当作课程安排，不带页码
        let noDeck = try #require(O.parseSupplements(#"{"items":[{"kind":"supplement","page":3,"point":"p"}]}"#, decks: [], part: part))
        #expect(noDeck == [O.Supplement(kind: .arrangement, deck: nil, page: nil, point: "p", quote: "", time: 600)])
    }

    @Test("旧格式的结果（没有类型）读出来当作补充")
    func legacyKind() throws {
        let item = try JSONDecoder().decode(O.Supplement.self, from: Data(#"{"deck":null,"page":2,"point":"p","quote":"q","time":3}"#.utf8))
        #expect(item.kind == .supplement && item.page == 2)
    }

    // MARK: - 纠正转写

    @Test("纠正和找要点的请求都以同样的课件全文开头（同一个模型时共用缓存）；每行带编号和时间")
    func correctionRequest() throws {
        let correction = O.correctionSystem(decks: alignDecks, pageLimit: 1_000, english: false)
        let supplement = O.supplementSystem(decks: alignDecks, pageLimit: 1_000, english: false)
        let prefix = O.coursewarePrefix(alignDecks, pageLimit: 1_000, english: false)
        #expect(!prefix.isEmpty && correction.hasPrefix(prefix) && supplement.hasPrefix(prefix))
        #expect(correction.contains("\"fixes\"") && correction.contains("不要改写"))
        #expect(!O.correctionSystem(decks: [], pageLimit: 1_000, english: true).contains("<courseware>"))

        let part = [(id: 7, line: O.TimedLine(time: 65, text: "The colonel saves registers.")),
                    (id: 8, line: O.TimedLine(time: 70, text: "Next."))]
        let messages = O.correctionMessages(system: correction, part: part, index: 1, total: 3, english: false)
        let user = try #require(messages.last?["content"] as? String)
        #expect(user.contains("#7 [01:05] The colonel saves registers.\n#8 [01:10] Next."))
    }

    @Test("读出纠正：编号要在这一段里；去掉抄进来的编号和时间；没改、空的、改动太大的不要")
    func parseCorrections() throws {
        let part = [(id: 7, line: O.TimedLine(time: 65, text: "The colonel saves the registers of the process.")),
                    (id: 8, line: O.TimedLine(time: 70, text: "Dykstra's semaphores.")),
                    (id: 9, line: O.TimedLine(time: 75, text: "Okay."))]
        let output = """
        {"fixes":[
          {"id":7,"text":"The kernel saves the registers of the process."},
          {"id":"8","text":"#8 [01:10] Dijkstra's semaphores."},
          {"id":9,"text":"Okay. And now a completely different and much longer sentence that the lecturer never said at all."},
          {"id":12,"text":"out of this part"},
          {"id":7,"text":"  "}
        ]}
        """
        let fixes = try #require(O.parseCorrections(output, part: part))
        #expect(fixes == [7: "The kernel saves the registers of the process.", 8: "Dijkstra's semaphores."])
        #expect(O.parseCorrections(#"{"fixes":[{"id":9,"text":"Okay."}]}"#, part: part) == [:])
        #expect(O.parseCorrections("broken", part: part) == nil)
    }

    @Test("整理结果存进录音文件夹，清单里记下相关课件")
    func store() async throws {
        try await withDirectory { root in
            let store = RecordingStore(root: root)
            let r = try store.create(title: "r", coursePath: nil, deckPath: nil, locale: "en_US", bitRate: 32_000)
            #expect(store.organized(r.id) == nil)
            let result = O.Result(decks: ["/c/a.pdf"], supplements: [
                O.Supplement(deck: "/c/a.pdf", page: 3, point: "p", quote: "q", time: 9),
                O.Supplement(kind: .arrangement, deck: nil, page: nil, point: "exam", quote: "", time: 20),
            ], createdAt: Date(timeIntervalSince1970: 1_764_000_000))
            try store.saveOrganized(result, for: r.id)
            #expect(store.organized(r.id) == result)
            let corrections = O.Corrections(lines: [.init(segment: 1, start: 5, text: "fixed")], createdAt: Date(timeIntervalSince1970: 0))
            try store.saveCorrections(corrections, for: r.id)
            #expect(store.corrections(r.id) == corrections)
            #expect(corrections.text(segment: 1, start: 5) == "fixed" && corrections.text(segment: 1, start: 6) == nil)
            #expect(store.load(r.id)?.relatedDecks == ["/c/a.pdf"])
        }
    }

    // MARK: - 完整流程

    @Test("用假的模型跑一遍：找出两份课件让用户确认，逐段纠正转写，再用纠正过的转写找补充要点和课程安排，保存")
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
                    text = #"{"course":"comp 3021","decks":[{"id":2,"reason":"PCB"},{"id":3,"reason":"round robin"}]}"#
                case .lectureTranscript:
                    text = user.contains("#1 [00:05] The PCB stores the registers.")
                        ? #"{"fixes":[{"id":1,"text":"The PCB stores all the registers."}]}"#
                        : #"{"fixes":[]}"#
                default:
                    if user.contains(" 1/2") { #expect(user.contains("all the registers")) }
                    text = user.contains(" 1/2")
                        ? #"{"items":[{"kind":"supplement","deck":1,"page":1,"point":"PCB 存寄存器","quote":"The PCB","start":"00:05"},{"kind":"arrangement","page":null,"point":"考试会考","quote":"exam","start":"06:40"}]}"#
                        : #"{"items":[{"kind":"supplement","deck":2,"page":1,"point":"时间片","quote":"quantum","start":"10:10"}]}"#
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
            #expect(store.load(r.id)?.tags == ["COMP3021"])

            controller.confirmOrganize(r.id, decks: [deckA.path, deckB.path])
            while controller.organizeTasks[r.id] != nil { await Task.yield() }
            #expect(controller.organizing[r.id] == nil)
            #expect(calls.map(\.0) == [.lectureDecks, .lectureTranscript, .lectureTranscript, .lectureSupplements, .lectureSupplements])
            #expect(store.corrections(r.id)?.lines == [.init(segment: 1, start: 5, text: "The PCB stores all the registers.")])

            let result = try #require(store.organized(r.id))
            #expect(result.decks == [deckA.path, deckB.path])
            #expect(result.supplements.map(\.point) == ["PCB 存寄存器", "考试会考", "时间片"])
            #expect(result.supplements.map(\.kind) == [.supplement, .arrangement, .supplement])
            #expect(result.supplements.map(\.time) == [5, 400, 610])
            #expect(result.supplements.last?.deck == deckB.path)
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
            var answer = #"{"items":[{"kind":"arrangement","point":"周五交作业","start":"00:01"}]}"#
            controller.completion = { _, messages in
                #expect((messages.first?["content"] as? String)?.contains("<courseware>") == false)
                return LLMTask.Output(text: answer, usage: nil, truncated: false)
            }
            // 没有课件：只找课程安排
            controller.confirmOrganize(r.id, decks: [])
            while controller.organizeTasks[r.id] != nil { await Task.yield() }
            #expect(store.organized(r.id)?.supplements.map(\.kind) == [.arrangement])

            answer = "{\"items\":"
            controller.completion = { _, _ in LLMTask.Output(text: answer, usage: nil, truncated: true) }

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
