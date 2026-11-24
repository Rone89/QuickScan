import SwiftUI
import WidgetKit

struct QuickScanWidgetEntry: TimelineEntry {
    let date: Date
}

struct QuickScanTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickScanWidgetEntry {
        QuickScanWidgetEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickScanWidgetEntry) -> Void) {
        completion(QuickScanWidgetEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickScanWidgetEntry>) -> Void) {
        let entry = QuickScanWidgetEntry(date: .now)
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

struct QuickScanWidget: Widget {
    let kind: String = "QuickScanWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickScanTimelineProvider()) { entry in
            QuickScanWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("快捷扫码")
        .description("一键打开主 App 实时扫码，自动识别微信跳扫一扫、支付宝直接打开。")
        .contentMarginsDisabled()
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}
