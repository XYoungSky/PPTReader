import AppKit

/// 记录阅读时长：App 在前台、打开了课件，且最近几分钟内有操作（翻页、点按、滚动、键盘）或正在生成回答时才计时。
@MainActor
final class StudyTracker {
    /// 超过这么久没有任何操作就停止计时。
    static let idleLimit: TimeInterval = 5 * 60
    private static let interval: TimeInterval = 15

    /// 正在生成回答时视为在学习。
    var isBusy: () -> Bool = { false }

    private let stats: StatsStore
    private var deck: String?
    private var lastActivity = Date()
    private var lastTick: Date?
    private var timer: Timer?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    init(stats: StatsStore) {
        self.stats = stats
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // 不计入切到其他 App 的时间
                self?.lastTick = Date()
                self?.lastActivity = Date()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
                self?.stats.saveNow()
                self?.stats.waitForPendingWrites()
            }
        })
    }

    func open(deck path: String, page: Int) {
        installMonitorIfNeeded()
        tick()
        deck = path
        lastTick = Date()
        lastActivity = Date()
        stats.notePage(page, deck: path)
    }

    func close() {
        tick()
        deck = nil
        lastTick = nil
    }

    func pageViewed(_ page: Int) {
        lastActivity = Date()
        guard let deck else { return }
        stats.notePage(page, deck: deck)
    }

    /// 在打开第一份课件时（App 已完成启动）开始监听操作。
    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .magnify, .swipe]
        ) { [weak self] event in
            self?.lastActivity = Date()
            return event
        }
    }

    private func tick() {
        let now = Date()
        defer { lastTick = now }
        guard let deck, let last = lastTick, NSApp.isActive else { return }
        if isBusy() { lastActivity = now }
        // 只计到最后一次操作后的空闲上限；电脑休眠等长间隔按一个周期封顶
        let end = min(now, lastActivity.addingTimeInterval(Self.idleLimit))
        let seconds = min(end.timeIntervalSince(last), Self.interval * 2)
        if seconds > 0 { stats.addStudyTime(seconds, deck: deck, at: now) }
    }
}
