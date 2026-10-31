import SwiftUI

/// macOS 27 SDK 把 `@State` 改成了宏，而只装命令行工具（没有 Xcode）时缺少 SwiftUIMacros 插件。
/// 通过类型别名直接使用 `State` 属性包装器，两种环境下都能编译。
typealias ViewState<Value> = SwiftUI.State<Value>
