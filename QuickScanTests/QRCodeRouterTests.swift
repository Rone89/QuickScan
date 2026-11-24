import XCTest
@testable import QuickScan

final class QRCodeRouterTests: XCTestCase {

    // MARK: - WeChat QR Codes

    func testWeChatPersonalPaymentCodeRoutesToWeChatScan() {
        let route = QRCodeRouter.route(for: "wxp://f2f0AbCdEfGhIjKlMnOpQrStUvWxYz")
        XCTAssertEqual(route?.platform, .wechat)
        XCTAssertEqual(route?.targetURL, URL(string: "weixin://scanqrcode"))
        XCTAssertEqual(route?.fallbackURL, URL(string: "weixin://"))
    }

    func testWeChatMerchantPaySchemeRoutesToWeChatScan() {
        let route = QRCodeRouter.route(for: "weixin://wxpay/bizpayurl?pr=1234567890")
        XCTAssertEqual(route?.platform, .wechat)
        XCTAssertEqual(route?.targetURL, URL(string: "weixin://scanqrcode"))
    }

    func testWeChatContactAndGroupLinksRouteToWeChatScan() {
        let payloads = [
            "https://u.wechat.com/M1234567890abcdef",
            "https://weixin.qq.com/g/AwYAAABCDEF12345",
            "http://weixin.qq.com/r/abc12345",
            "https://payapp.weixin.qq.com/sjt/qr/abc",
            "https://payapp.wechatpay.cn/sjt/qr/xyz",
            "https://wx.tenpay.com/f2f?t=abcdef",
            "https://wxaurl.cn/abc1234",
            "https://work.weixin.qq.com/u/vc123456"
        ]

        for payload in payloads {
            let route = QRCodeRouter.route(for: payload)
            XCTAssertEqual(route?.platform, .wechat, "Expected WeChat for \(payload)")
            XCTAssertEqual(route?.targetURL, URL(string: "weixin://scanqrcode"))
        }
    }

    // MARK: - Alipay QR Codes

    func testAlipayPersonalPaymentQRRoutesDirectlyToAlipay() {
        let raw = "https://qr.alipay.com/fkx1234567890abcdef"
        let route = QRCodeRouter.route(for: raw)

        XCTAssertEqual(route?.platform, .alipay)
        XCTAssertEqual(
            route?.targetURL?.absoluteString,
            "alipays://platformapi/startapp?saId=10000007&qrcode=https%3A%2F%2Fqr.alipay.com%2Ffkx1234567890abcdef"
        )
        XCTAssertEqual(
            route?.fallbackURL?.absoluteString,
            "alipayqr://platformapi/startapp?saId=10000007&qrcode=https%3A%2F%2Fqr.alipay.com%2Ffkx1234567890abcdef"
        )
    }

    func testAlipayQueryParametersAreStrictlyPercentEncoded() {
        let raw = "https://render.alipay.com/p/s/i?scheme=alipays://test&id=42&name=支付"
        let route = QRCodeRouter.route(for: raw)

        XCTAssertEqual(route?.platform, .alipay)
        let targetString = route?.targetURL?.absoluteString ?? ""
        XCTAssertTrue(targetString.hasPrefix("alipays://platformapi/startapp?saId=10000007&qrcode="))

        let components = URLComponents(string: targetString)
        let decodedQR = components?.queryItems?.first(where: { $0.name == "qrcode" })?.value
        XCTAssertEqual(decodedQR, raw)
    }

    func testAlipayDirectSchemePreservesTargetAndUpgradesAlipayToAlipays() {
        let alipaysRaw = "alipays://platformapi/startapp?appId=20000067&url=https%3A%2F%2Fexample.com"
        let route1 = QRCodeRouter.route(for: alipaysRaw)
        XCTAssertEqual(route1?.platform, .alipay)
        XCTAssertEqual(route1?.targetURL?.absoluteString, alipaysRaw)

        let alipayRaw = "alipay://platformapi/startapp?saId=10000007"
        let route2 = QRCodeRouter.route(for: alipayRaw)
        XCTAssertEqual(route2?.platform, .alipay)
        XCTAssertEqual(route2?.targetURL?.absoluteString, "alipays://platformapi/startapp?saId=10000007")
    }

    // MARK: - Domain Spoofing & Generic QR Codes

    func testSpoofedDomainsAreNotMisclassified() {
        let spoofedAlipay = QRCodeRouter.route(for: "https://fakealipay.com/qr/123")
        XCTAssertEqual(spoofedAlipay?.platform, .other)
        XCTAssertNil(spoofedAlipay?.targetURL)
        XCTAssertEqual(spoofedAlipay?.webURL, URL(string: "https://fakealipay.com/qr/123"))

        let spoofedWeChat = QRCodeRouter.route(for: "https://notwechat.com/u/abc")
        XCTAssertEqual(spoofedWeChat?.platform, .other)
        XCTAssertNil(spoofedWeChat?.targetURL)
    }

    func testEmptyOrWhitespacePayloadReturnsNil() {
        XCTAssertNil(QRCodeRouter.route(for: ""))
        XCTAssertNil(QRCodeRouter.route(for: "   \n\t  "))
    }

    // MARK: - Widget Deep Link Parsing

    func testDeepLinkGenerationAndParsing() {
        let scanURL = QuickScanDeepLink.url(action: .scan, source: "widget_small")
        XCTAssertEqual(QuickScanDeepLink.parse(scanURL), QuickScanDeepLink.Payload(action: .scan, source: "widget_small"))

        let albumURL = QuickScanDeepLink.url(action: .album, source: "widget_medium_album")
        XCTAssertEqual(QuickScanDeepLink.parse(albumURL), QuickScanDeepLink.Payload(action: .album, source: "widget_medium_album"))

        let unrelated = URL(string: "https://example.com/scan")!
        XCTAssertNil(QuickScanDeepLink.parse(unrelated))
    }
}
