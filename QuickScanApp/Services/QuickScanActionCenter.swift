import Foundation
import Observation

/// 统一接收来自小组件、URL Scheme（quickscan://scan）与系统快捷指令的扫码动作请求
@MainActor
@Observable
final class QuickScanActionCenter {
    static let shared = QuickScanActionCenter()

    var pendingPayload: QuickScanDeepLink.Payload?
    var pendingRequestToken = UUID()

    private init() {}

    func enqueue(_ payload: QuickScanDeepLink.Payload) {
        pendingPayload = payload
        pendingRequestToken = UUID()
    }
}
