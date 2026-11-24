import Foundation

/// 识别出的二维码所属平台类型
public enum QRCodePlatform: String, Codable, Equatable, Sendable {
    case wechat
    case alipay
    case other

    public var displayName: String {
        switch self {
        case .wechat: return "微信"
        case .alipay: return "支付宝"
        case .other: return "二维码"
        }
    }
}

/// 二维码路由解析结果
public struct QRCodeRoute: Equatable, Sendable {
    public let rawPayload: String
    public let platform: QRCodePlatform
    /// 首选跳转 URL（微信为 weixin://scanqrcode，支付宝为直达 URL Scheme）
    public let targetURL: URL?
    /// 兜底跳转 URL（主 Scheme 不可用时尝试）
    public let fallbackURL: URL?
    /// 若原始内容是普通网页链接，可供 Safari 打开
    public let webURL: URL?

    public init(
        rawPayload: String,
        platform: QRCodePlatform,
        targetURL: URL?,
        fallbackURL: URL?,
        webURL: URL?
    ) {
        self.rawPayload = rawPayload
        self.platform = platform
        self.targetURL = targetURL
        self.fallbackURL = fallbackURL
        self.webURL = webURL
    }
}

/// 微信与支付宝二维码识别与跳转路由器
public enum QRCodeRouter {
    /// 微信扫一扫 URL Scheme
    public static let wechatScanURL = URL(string: "weixin://scanqrcode")!
    public static let wechatFallbackURL = URL(string: "weixin://")!

    private static let wechatSchemes: Set<String> = [
        "wxp",
        "weixin",
        "wechat"
    ]

    private static let wechatHostSuffixes: [String] = [
        "weixin.qq.com",
        "wechat.com",
        "wechatpay.cn",
        "weixin.com",
        "tenpay.com",
        "wxaurl.cn",
        "wx.qq.com",
        "weixin110.qq.com",
        "servicewechat.com"
    ]

    private static let alipaySchemes: Set<String> = [
        "alipays",
        "alipay",
        "alipayqr"
    ]

    private static let alipayHostSuffixes: [String] = [
        "alipay.com",
        "alipay.cn",
        "alipayplus.com",
        "alipaydev.com",
        "alipayobjects.com"
    ]

    /// RFC 3986 未保留字符集，确保作为 query 参数值时不会破坏 `:` `/` `?` `&` `=` 等分隔符
    private static let rfc3986Unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// 识别二维码字符串并生成跳转路由
    public static func route(for rawPayload: String) -> QRCodeRoute? {
        let trimmed = rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let parsedURL = parseURLSafely(from: trimmed)
        let scheme = parsedURL?.scheme?.lowercased() ?? extractSchemePrefix(from: trimmed)
        let host = parsedURL?.host?.lowercased()

        // 1. 微信二维码 -> 直接跳转微信扫一扫
        if isWeChat(scheme: scheme, host: host) {
            return QRCodeRoute(
                rawPayload: trimmed,
                platform: .wechat,
                targetURL: wechatScanURL,
                fallbackURL: wechatFallbackURL,
                webURL: webURLIfHTTP(parsedURL)
            )
        }

        // 2. 支付宝二维码 -> 直接由支付宝打开对应码内容
        if isAlipay(scheme: scheme, host: host) {
            if let scheme, alipaySchemes.contains(scheme) {
                let primary = normalizedAlipaySchemeURL(raw: trimmed, parsed: parsedURL)
                let fallback = alipayDirectURL(for: trimmed)
                return QRCodeRoute(
                    rawPayload: trimmed,
                    platform: .alipay,
                    targetURL: primary ?? fallback,
                    fallbackURL: fallback,
                    webURL: nil
                )
            }

            return QRCodeRoute(
                rawPayload: trimmed,
                platform: .alipay,
                targetURL: alipayDirectURL(for: trimmed),
                fallbackURL: alipayFallbackURL(for: trimmed),
                webURL: webURLIfHTTP(parsedURL)
            )
        }

        // 3. 其他二维码（含聚合收款码、普通网址、纯文本等）
        return QRCodeRoute(
            rawPayload: trimmed,
            platform: .other,
            targetURL: nil,
            fallbackURL: nil,
            webURL: webURLIfHTTP(parsedURL)
        )
    }

    /// 构造支付宝直接解析打开任意二维码内容的 URL（saId=10000007 为支付宝扫码直达引擎）
    public static func alipayDirectURL(for payload: String) -> URL? {
        let encoded = percentEncodeQueryValue(payload)
        return URL(string: "alipays://platformapi/startapp?saId=10000007&qrcode=\(encoded)")
    }

    /// 支付宝备用 Scheme（alipayqr）
    public static func alipayFallbackURL(for payload: String) -> URL? {
        let encoded = percentEncodeQueryValue(payload)
        return URL(string: "alipayqr://platformapi/startapp?saId=10000007&qrcode=\(encoded)")
    }

    /// 严格按 RFC 3986 对查询参数值进行百分号编码
    public static func percentEncodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: rfc3986Unreserved) ?? value
    }

    // MARK: - Private Helpers

    private static func isWeChat(scheme: String?, host: String?) -> Bool {
        if let scheme, wechatSchemes.contains(scheme) {
            return true
        }
        if let scheme, (scheme == "http" || scheme == "https"), let host {
            return matchesDomain(host, suffixes: wechatHostSuffixes)
        }
        return false
    }

    private static func isAlipay(scheme: String?, host: String?) -> Bool {
        if let scheme, alipaySchemes.contains(scheme) {
            return true
        }
        if let scheme, (scheme == "http" || scheme == "https"), let host {
            return matchesDomain(host, suffixes: alipayHostSuffixes)
        }
        return false
    }

    private static func matchesDomain(_ host: String, suffixes: [String]) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return suffixes.contains { suffix in
            normalized == suffix || normalized.hasSuffix(".\(suffix)")
        }
    }

    private static func parseURLSafely(from raw: String) -> URL? {
        if let url = URL(string: raw), url.scheme != nil {
            return url
        }
        if let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let url = URL(string: encoded),
           url.scheme != nil {
            return url
        }
        return nil
    }

    private static func extractSchemePrefix(from raw: String) -> String? {
        guard let range = raw.range(of: "://") else {
            return nil
        }
        let prefix = raw[..<range.lowerBound].lowercased()
        guard !prefix.isEmpty,
              prefix.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else {
            return nil
        }
        return prefix
    }

    private static func normalizedAlipaySchemeURL(raw: String, parsed: URL?) -> URL? {
        if raw.lowercased().hasPrefix("alipay://") {
            let upgraded = "alipays://" + raw.dropFirst("alipay://".count)
            if let upgradedURL = parseURLSafely(from: upgraded) {
                return upgradedURL
            }
        }
        return parsed ?? parseURLSafely(from: raw)
    }

    private static func webURLIfHTTP(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}
