import AppKit
import SwiftUI

struct AppearanceSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        @Bindable var localizer = Localizer.shared
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                SettingsRow(title: tr("语言", "Language")) {
                    SegmentedPicker(selection: $localizer.language, options: [
                        (.system, tr("跟随系统", "System")),
                        (.zh, "中文"),
                        (.en, "English"),
                    ])
                }
                SettingsRow(title: tr("讲解字号", "Text size")) {
                    SegmentedPicker(selection: $settings.chatFontSize, options: [
                        (14.0, "14"), (15.0, "15"), (16.0, "16"), (17.0, "17"), (18.0, "18"),
                    ])
                }
                SettingsRow(title: tr("讲解字体", "Font"), divider: false) {
                    SegmentedPicker(selection: $settings.chatSerif, options: [(false, tr("无衬线", "Sans")), (true, tr("衬线", "Serif"))])
                }
            }
        }
    }
}
