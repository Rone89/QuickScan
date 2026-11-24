import Foundation
import UIKit

/// 外部 App 打开结果
enum URLOpenOutcome: Equatable {
    case opened
    case appNotInstalled(QRCodePlatform)
    case failed
}

@MainActor
protocol URLOpening {
    func openRouteImmediately(_ route: QRCodeRoute, completion: @escaping @MainActor (URLOpenOutcome) -> Void)
    func openCandidatesImmediately(_ candidates: [URL], completion: @escaping @MainActor (Bool) -> Void)
    func openExternalURL(_ url: URL)
}

/// 封装 UIApplication.shared.open，无额外前置提示，同步发起微信与支付宝跳转
@MainActor
final class SystemURLOpener: URLOpening {
    func openRouteImmediately(_ route: QRCodeRoute, completion: @escaping @MainActor (URLOpenOutcome) -> Void) {
        let candidates = [route.targetURL, route.fallbackURL].compactMap { $0 }
        guard !candidates.isEmpty else {
            completion(.failed)
            return
        }

        openCandidatesImmediately(candidates) { opened in
            if opened {
                completion(.opened)
            } else {
                completion(.appNotInstalled(route.platform))
            }
        }
    }

    func openCandidatesImmediately(_ candidates: [URL], completion: @escaping @MainActor (Bool) -> Void) {
        openCandidate(at: 0, in: candidates, completion: completion)
    }

    func openExternalURL(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private func openCandidate(
        at index: Int,
        in candidates: [URL],
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard candidates.indices.contains(index) else {
            completion(false)
            return
        }

        UIApplication.shared.open(candidates[index], options: [:]) { success in
            Task { @MainActor in
                if success {
                    completion(true)
                } else {
                    self.openCandidate(at: index + 1, in: candidates, completion: completion)
                }
            }
        }
    }
}
