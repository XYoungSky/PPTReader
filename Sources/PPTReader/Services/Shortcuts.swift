import AppKit
import Observation
import SwiftUI

/// 可以自定义快捷键的操作。
enum ShortcutAction: String, CaseIterable, Identifiable {
    case openFolder, refreshFiles
    case toggleSidebar, toggleChat, statistics
    case previousPage, nextPage, zoomIn, zoomOut, fitToWindow, toggleLayout
    case explainPage, askQuestion, summarize, conceptMap, quiz, toggleAutoExplain, toggleThinking, stop

    var id: String { rawValue }

    enum Group: CaseIterable, Identifiable {
        case file, view, reading, tutor

        var id: Self { self }

        var title: String {
            switch self {
            case .file: tr("文件", "File")
            case .view: tr("显示", "View")
            case .reading: tr("阅读", "Reading")
            case .tutor: tr("讲解", "Tutor")
            }
        }
    }

    var group: Group {
        switch self {
        case .openFolder, .refreshFiles: .file
        case .toggleSidebar, .toggleChat, .statistics: .view
        case .previousPage, .nextPage, .zoomIn, .zoomOut, .fitToWindow, .toggleLayout: .reading
        case .explainPage, .askQuestion, .summarize, .conceptMap, .quiz, .toggleAutoExplain, .toggleThinking, .stop: .tutor
        }
    }

    var title: String {
        switch self {
        case .openFolder: tr("打开课程文件夹", "Open course folder")
        case .refreshFiles: tr("刷新文件列表", "Refresh file list")
        case .toggleSidebar: tr("显示 / 隐藏侧边栏", "Show / hide sidebar")
        case .toggleChat: tr("显示 / 隐藏 AI 面板", "Show / hide AI panel")
        case .statistics: tr("学习统计", "Statistics")
        case .previousPage: tr("上一页", "Previous page")
        case .nextPage: tr("下一页", "Next page")
        case .zoomIn: tr("放大", "Zoom in")
        case .zoomOut: tr("缩小", "Zoom out")
        case .fitToWindow: tr("适合窗口", "Fit to window")
        case .toggleLayout: tr("切换连续滚动 / 单页", "Continuous / single page")
        case .explainPage: tr("讲解本页", "Explain page")
        case .askQuestion: tr("提问", "Ask a question")
        case .summarize: QuickAction.summary.title
        case .conceptMap: QuickAction.outline.title
        case .quiz: QuickAction.quiz.title
        case .toggleAutoExplain: tr("翻页自动讲解", "Auto-explain on page turn")
        case .toggleThinking: tr("深度思考", "Deep thinking")
        case .stop: tr("停止生成", "Stop generating")
        }
    }

    var defaultCombo: KeyCombo? {
        switch self {
        case .openFolder: KeyCombo("o", [.command])
        case .refreshFiles: KeyCombo("r", [.command])
        case .toggleSidebar: KeyCombo("s", [.control, .command])
        case .toggleChat: KeyCombo("0", [.option, .command])
        case .statistics: KeyCombo("s", [.shift, .command])
        case .previousPage: KeyCombo(KeyCombo.up, [.option, .command])
        case .nextPage: KeyCombo(KeyCombo.down, [.option, .command])
        case .zoomIn: KeyCombo("=", [.command])
        case .zoomOut: KeyCombo("-", [.command])
        case .fitToWindow: KeyCombo("0", [.command])
        case .explainPage: KeyCombo("e", [.command])
        case .askQuestion: KeyCombo("l", [.command])
        case .stop: KeyCombo(".", [.command])
        case .toggleLayout, .summarize, .conceptMap, .quiz, .toggleAutoExplain, .toggleThinking: nil
        }
    }
}

/// 一组按键：单个字符（小写）或特殊键名，加上修饰键。
struct KeyCombo: Codable, Hashable {
    struct Modifiers: OptionSet, Codable, Hashable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)

        init(rawValue: Int) { self.rawValue = rawValue }

        init(_ flags: NSEvent.ModifierFlags) {
            var value: Modifiers = []
            if flags.contains(.control) { value.insert(.control) }
            if flags.contains(.option) { value.insert(.option) }
            if flags.contains(.shift) { value.insert(.shift) }
            if flags.contains(.command) { value.insert(.command) }
            self = value
        }

        /// 按 macOS 惯例排列：⌃⌥⇧⌘。
        var symbols: String {
            (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
                + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
        }
    }

    static let up = "up", down = "down", left = "left", right = "right"

    var key: String
    var modifiers: Modifiers

    init(_ key: String, _ modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// 特殊键：名称、键码、菜单使用的 KeyEquivalent、显示符号。
    private struct Special {
        let name: String
        let keyCode: UInt16
        let equivalent: KeyEquivalent
        let symbol: String
    }

    private static let specials: [Special] = {
        var list = [
            Special(name: up, keyCode: 126, equivalent: .upArrow, symbol: "↑"),
            Special(name: down, keyCode: 125, equivalent: .downArrow, symbol: "↓"),
            Special(name: left, keyCode: 123, equivalent: .leftArrow, symbol: "←"),
            Special(name: right, keyCode: 124, equivalent: .rightArrow, symbol: "→"),
            Special(name: "return", keyCode: 36, equivalent: .return, symbol: "↩"),
            Special(name: "enter", keyCode: 76, equivalent: .return, symbol: "⌤"),
            Special(name: "tab", keyCode: 48, equivalent: .tab, symbol: "⇥"),
            Special(name: "space", keyCode: 49, equivalent: .space, symbol: "Space"),
            Special(name: "delete", keyCode: 51, equivalent: .delete, symbol: "⌫"),
            Special(name: "forwardDelete", keyCode: 117, equivalent: .deleteForward, symbol: "⌦"),
            Special(name: "escape", keyCode: 53, equivalent: .escape, symbol: "⎋"),
            Special(name: "home", keyCode: 115, equivalent: .home, symbol: "↖"),
            Special(name: "end", keyCode: 119, equivalent: .end, symbol: "↘"),
            Special(name: "pageUp", keyCode: 116, equivalent: .pageUp, symbol: "⇞"),
            Special(name: "pageDown", keyCode: 121, equivalent: .pageDown, symbol: "⇟"),
        ]
        let functionKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in functionKeyCodes.enumerated() {
            let scalar = UnicodeScalar(UInt32(NSF1FunctionKey) + UInt32(index))!
            list.append(Special(name: "f\(index + 1)", keyCode: code, equivalent: KeyEquivalent(Character(scalar)), symbol: "F\(index + 1)"))
        }
        return list
    }()

    private var special: Special? { Self.specials.first { $0.name == key } }

    var isFunctionKey: Bool { key.count > 1 && key.hasPrefix("f") && Int(key.dropFirst()) != nil }

    var keyEquivalent: KeyEquivalent {
        if let special { return special.equivalent }
        return KeyEquivalent(key.first ?? " ")
    }

    var eventModifiers: EventModifiers {
        var value: EventModifiers = []
        if modifiers.contains(.control) { value.insert(.control) }
        if modifiers.contains(.option) { value.insert(.option) }
        if modifiers.contains(.shift) { value.insert(.shift) }
        if modifiers.contains(.command) { value.insert(.command) }
        return value
    }

    var keyboardShortcut: KeyboardShortcut { KeyboardShortcut(keyEquivalent, modifiers: eventModifiers) }

    var keySymbol: String { special?.symbol ?? key.uppercased() }

    /// 例如「⌥⌘↓」。
    var display: String { modifiers.symbols + keySymbol }

    /// 从按键事件生成；不支持的按键返回 nil。
    init?(event: NSEvent) {
        let modifiers = Modifiers(event.modifierFlags)
        if let special = Self.specials.first(where: { $0.keyCode == event.keyCode }) {
            self.init(special.name, modifiers)
            return
        }
        // 去掉修饰键后得到按键本身（⇧ 和 ⌥ 不改变记录的字符）
        guard let characters = event.characters(byApplyingModifiers: [])?.lowercased(),
              characters.count == 1, let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar), !CharacterSet.whitespaces.contains(scalar),
              scalar.value < 0xF700 || scalar.value > 0xF8FF else { return nil }
        self.init(characters, modifiers)
    }
}

/// 快捷键设置：只保存与默认不同的项，修改后菜单立即更新。
@MainActor
@Observable
final class ShortcutStore {
    static let shared = ShortcutStore()
    /// 以 JSON 字符串存入 UserDefaults，菜单命令通过 @AppStorage 监听它。
    static let defaultsKey = "ui.shortcuts"

    enum Feedback: Equatable {
        case moved(from: ShortcutAction)
        case needsModifier
        case reserved(String)
        case unsupported

        var text: String {
            switch self {
            case .moved(let action): tr("已从「\(action.title)」移到这里", "Moved from “\(action.title)”")
            case .needsModifier: tr("需包含 ⌘ 或 ⌃", "Include ⌘ or ⌃")
            case .reserved(let combo): tr("\(combo) 是系统快捷键", "\(combo) is reserved by the system")
            case .unsupported: tr("不支持这个按键", "This key isn't supported")
            }
        }

        var isError: Bool {
            if case .moved = self { return false }
            return true
        }
    }

    /// 用户的修改；值为 nil 表示清除了这个快捷键。
    private(set) var overrides: [ShortcutAction: KeyCombo?] = [:]
    /// 正在录制的操作。
    private(set) var recording: ShortcutAction?
    /// 录制时已按住的修饰键，用于实时显示。
    private(set) var heldModifiers: KeyCombo.Modifiers = []
    private(set) var feedback: (action: ShortcutAction, value: Feedback)?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var feedbackTask: Task<Void, Never>?
    /// 点按录制中的按钮会先触发「点击别处结束录制」，这里避免它紧接着又开始录制。
    @ObservationIgnored private var justEnded: ShortcutAction?

    /// 系统或标准菜单占用的组合。
    private static let reserved: Set<KeyCombo> = [
        KeyCombo("q", [.command]), KeyCombo("w", [.command]), KeyCombo("h", [.command]), KeyCombo("h", [.option, .command]),
        KeyCombo("m", [.command]), KeyCombo(",", [.command]), KeyCombo("c", [.command]), KeyCombo("v", [.command]),
        KeyCombo("x", [.command]), KeyCombo("a", [.command]), KeyCombo("z", [.command]), KeyCombo("z", [.shift, .command]),
        KeyCombo("f", [.control, .command]), KeyCombo("`", [.command]), KeyCombo("tab", [.command]),
        KeyCombo("space", [.command]), KeyCombo("space", [.control]), KeyCombo("space", [.control, .command]),
        KeyCombo("escape", [.option, .command]), KeyCombo("/", [.shift, .command]),
    ]

    private init() {
        guard let json = UserDefaults.standard.string(forKey: Self.defaultsKey),
              let stored = try? JSONDecoder().decode([String: Stored].self, from: Data(json.utf8)) else { return }
        for (name, value) in stored {
            guard let action = ShortcutAction(rawValue: name) else { continue }
            overrides[action] = .some(value.combo)
        }
    }

    private struct Stored: Codable {
        var combo: KeyCombo?
    }

    // MARK: - 查询

    func combo(for action: ShortcutAction) -> KeyCombo? {
        if let override = overrides[action] { return override }
        return action.defaultCombo
    }

    func keyboardShortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        combo(for: action)?.keyboardShortcut
    }

    /// 菜单项右侧显示的符号，未设置时为 nil。
    func label(for action: ShortcutAction) -> String? {
        combo(for: action)?.display
    }

    /// 附在提示文字后面，例如「 ⌘E」。
    func hint(_ action: ShortcutAction) -> String {
        label(for: action).map { " " + $0 } ?? ""
    }

    func isModified(_ action: ShortcutAction) -> Bool {
        combo(for: action) != action.defaultCombo
    }

    var hasModifications: Bool { ShortcutAction.allCases.contains(where: isModified) }

    // MARK: - 修改

    /// 设置快捷键；若已被其他操作使用，从那里移除并返回它。
    @discardableResult
    func set(_ combo: KeyCombo?, for action: ShortcutAction) -> ShortcutAction? {
        var displaced: ShortcutAction?
        if let combo, let owner = ShortcutAction.allCases.first(where: { $0 != action && self.combo(for: $0) == combo }) {
            assign(nil, to: owner)
            displaced = owner
        }
        assign(combo, to: action)
        save()
        return displaced
    }

    func reset(_ action: ShortcutAction) {
        guard let combo = action.defaultCombo else {
            set(nil, for: action)
            return
        }
        set(combo, for: action)
    }

    func resetAll() {
        endRecording()
        overrides = [:]
        feedback = nil
        save()
    }

    private func assign(_ combo: KeyCombo?, to action: ShortcutAction) {
        if combo == action.defaultCombo {
            overrides[action] = nil
        } else {
            overrides[action] = .some(combo)
        }
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, Stored(combo: $0.value)) })
        if stored.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(stored), let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: Self.defaultsKey)
        }
    }

    // MARK: - 录制

    func toggleRecording(_ action: ShortcutAction) {
        if justEnded == action {
            justEnded = nil
            return
        }
        if recording == action {
            endRecording()
        } else {
            beginRecording(action)
        }
    }

    func beginRecording(_ action: ShortcutAction) {
        endRecording()
        recording = action
        heldModifiers = []
        if feedback?.action == action { feedback = nil }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endRecording() }
        }
    }

    func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        recording = nil
        heldModifiers = []
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let action = recording else { return event }
        switch event.type {
        case .flagsChanged:
            heldModifiers = KeyCombo.Modifiers(event.modifierFlags)
            return nil
        case .leftMouseDown, .rightMouseDown:
            justEnded = action
            endRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                if self?.justEnded == action { self?.justEnded = nil }
            }
            return event
        case .keyDown:
            let bare = KeyCombo.Modifiers(event.modifierFlags).isEmpty
            if bare && event.keyCode == 53 {
                endRecording()
                return nil
            }
            if bare && (event.keyCode == 51 || event.keyCode == 117) {
                set(nil, for: action)
                endRecording()
                return nil
            }
            guard let combo = KeyCombo(event: event) else {
                show(.unsupported, for: action)
                return nil
            }
            if !combo.isFunctionKey && !combo.modifiers.contains(.command) && !combo.modifiers.contains(.control) {
                show(.needsModifier, for: action)
                return nil
            }
            if Self.reserved.contains(combo) {
                show(.reserved(combo.display), for: action)
                return nil
            }
            let displaced = set(combo, for: action)
            endRecording()
            if let displaced { show(.moved(from: displaced), for: action) } else if feedback?.action == action { feedback = nil }
            return nil
        default:
            return event
        }
    }

    private func show(_ value: Feedback, for action: ShortcutAction) {
        feedback = (action, value)
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.content) { self?.feedback = nil }
        }
    }
}
