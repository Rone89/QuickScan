import AppIntents
import Foundation

/// 供系统「快捷指令」与 Spotlight 直接调用的扫码意图

public struct OpenScanIntent: AppIntent {
    public static let title: LocalizedStringResource = "打开扫码"
    public static let description = IntentDescription("立即打开快捷扫码并启用实时相机扫描微信/支付宝二维码。")
    public static let supportedModes: IntentModes = .foreground

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        QuickScanActionCenter.shared.enqueue(.init(action: .scan, source: "intent"))
        #endif
        return .result()
    }
}

public struct OpenAlbumScanIntent: AppIntent {
    public static let title: LocalizedStringResource = "从相册识别二维码"
    public static let description = IntentDescription("打开快捷扫码并直接从系统相册选择图片识别二维码。")
    public static let supportedModes: IntentModes = .foreground

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        QuickScanActionCenter.shared.enqueue(.init(action: .album, source: "intent"))
        #endif
        return .result()
    }
}
