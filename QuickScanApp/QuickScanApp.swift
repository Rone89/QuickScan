import SwiftUI
import UIKit
import WidgetKit

/// UIKit 生命周期代理：尽早捕获来自小组件与快捷指令的 quickscan:// 深链
final class QuickScanAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        guard let payload = QuickScanDeepLink.parse(url) else {
            return false
        }
        Task { @MainActor in
            QuickScanActionCenter.shared.enqueue(payload)
        }
        return true
    }
}

@main
struct QuickScanApp: App {
    @UIApplicationDelegateAdaptor(QuickScanAppDelegate.self) private var appDelegate
    @State private var actionCenter = QuickScanActionCenter.shared
    @State private var scanner = CameraScannerController()

    var body: some Scene {
        WindowGroup {
            ScannerHomeView(actionCenter: actionCenter, scanner: scanner)
                .onAppear {
                    WidgetCenter.shared.reloadAllTimelines()
                }
                .onOpenURL { url in
                    if let payload = QuickScanDeepLink.parse(url) {
                        actionCenter.enqueue(payload)
                    }
                }
        }
    }
}
