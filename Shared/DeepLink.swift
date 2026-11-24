import Foundation

/// 主 App、小组件与系统快捷指令共享的 URL Scheme 深链定义
public enum QuickScanDeepLink {
    public static let scheme = "quickscan"

    public enum Action: String, Equatable, Sendable {
        /// 直接进入实时相机扫码
        case scan
        /// 直接拉起相册选择二维码图片识别
        case album
    }

    public struct Payload: Equatable, Sendable {
        public let action: Action
        public let source: String?

        public init(action: Action, source: String? = nil) {
            self.action = action
            self.source = source
        }
    }

    /// 生成供小组件或快捷指令跳转主 App 使用的 URL
    public static func url(action: Action = .scan, source: String = "widget") -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = action == .scan ? "scan" : action.rawValue
        var items: [URLQueryItem] = []
        if !source.isEmpty {
            items.append(URLQueryItem(name: "source", value: source))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url ?? URL(string: "\(scheme)://scan")!
    }

    /// 解析从外部（小组件、快捷指令等）传入的 URL
    public static func parse(_ url: URL) -> Payload? {
        guard url.scheme?.lowercased() == scheme else {
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = components?.host?.lowercased()
        let queryItems = components?.queryItems ?? []

        let source = queryItems.first(where: { $0.name == "source" })?.value
        let actionQuery = queryItems.first(where: { $0.name == "action" })?.value?.lowercased()

        if let actionQuery, let matched = Action(rawValue: actionQuery) {
            return Payload(action: matched, source: source)
        }
        if let host, let matched = Action(rawValue: host) {
            return Payload(action: matched, source: source)
        }

        return Payload(action: .scan, source: source)
    }
}
