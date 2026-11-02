import Foundation

enum AppInfo {
    /// 从 Info.plist 读取；`swift run` 时没有 Info.plist，使用源码中的版本号。
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.4"
}
