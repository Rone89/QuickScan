import CoreGraphics
import CoreImage
import XCTest
@testable import QuickScan

final class QRAutoZoomTests: XCTestCase {

    func testHighConfidenceSmallQRTriggersSmoothZoomAndFocus() {
        var policy = QRAutoZoomPolicy()
        let now = Date(timeIntervalSince1970: 1000)

        let detection = QRDetectionResult(
            score: 0.82,
            cropRect: CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10),
            fullFrameRect: CGRect(x: 0.45, y: 0.47, width: 0.10, height: 0.06)
        )

        let decision = policy.evaluate(
            detection: detection,
            currentDisplayZoom: 1.0,
            maxAutoDisplayZoom: 5.0,
            now: now
        )

        guard case .focusAndZoom(let targetZoom, let focusPoint) = decision else {
            return XCTFail("Expected focusAndZoom, got \(decision)")
        }
        // 0.38 / 0.10 = 3.8, clamped by maxSingleStepMultiplier (2.35)
        XCTAssertEqual(targetZoom, 2.35, accuracy: 0.01)
        XCTAssertEqual(focusPoint.x, 0.50, accuracy: 0.02)
        XCTAssertEqual(focusPoint.y, 0.50, accuracy: 0.02)
    }

    func testMediumConfidenceRequiresTwoConsistentFrames() {
        var policy = QRAutoZoomPolicy()
        let t0 = Date(timeIntervalSince1970: 2000)

        let frame1 = QRDetectionResult(
            score: 0.38,
            cropRect: CGRect(x: 0.44, y: 0.44, width: 0.08, height: 0.08),
            fullFrameRect: CGRect(x: 0.44, y: 0.46, width: 0.08, height: 0.05)
        )
        let d1 = policy.evaluate(detection: frame1, currentDisplayZoom: 1.0, maxAutoDisplayZoom: 5.0, now: t0)
        XCTAssertEqual(d1, .none)

        let frame2 = QRDetectionResult(
            score: 0.41,
            cropRect: CGRect(x: 0.45, y: 0.45, width: 0.08, height: 0.08),
            fullFrameRect: CGRect(x: 0.45, y: 0.47, width: 0.08, height: 0.05)
        )
        let d2 = policy.evaluate(
            detection: frame2,
            currentDisplayZoom: 1.0,
            maxAutoDisplayZoom: 5.0,
            now: t0.addingTimeInterval(0.15)
        )
        guard case .focusAndZoom(let targetZoom, _) = d2 else {
            return XCTFail("Expected focusAndZoom on second consistent frame, got \(d2)")
        }
        XCTAssertGreaterThan(targetZoom, 1.8)
    }

    func testLargeQRDoesNotOverZoomAndOnlyFocuses() {
        var policy = QRAutoZoomPolicy()
        let detection = QRDetectionResult(
            score: 0.96,
            cropRect: CGRect(x: 0.30, y: 0.30, width: 0.40, height: 0.40),
            fullFrameRect: CGRect(x: 0.30, y: 0.35, width: 0.40, height: 0.25)
        )
        let decision = policy.evaluate(detection: detection, currentDisplayZoom: 1.0, maxAutoDisplayZoom: 5.0)
        guard case .focusOnly = decision else {
            return XCTFail("Expected focusOnly for large QR, got \(decision)")
        }
    }

    func testAutoResetAfterQRLeavesFrame() {
        var policy = QRAutoZoomPolicy()
        let t0 = Date(timeIntervalSince1970: 3000)

        let smallQR = QRDetectionResult(
            score: 0.85,
            cropRect: CGRect(x: 0.45, y: 0.45, width: 0.12, height: 0.12),
            fullFrameRect: CGRect(x: 0.45, y: 0.47, width: 0.12, height: 0.07)
        )
        _ = policy.evaluate(detection: smallQR, currentDisplayZoom: 1.0, maxAutoDisplayZoom: 5.0, now: t0)

        // 1 秒后暂不复位
        let stillWaiting = policy.evaluate(
            detection: nil,
            currentDisplayZoom: 2.35,
            maxAutoDisplayZoom: 5.0,
            now: t0.addingTimeInterval(1.0)
        )
        XCTAssertEqual(stillWaiting, .none)

        // 超过 2.6 秒后自动回退 1×
        let reset = policy.evaluate(
            detection: nil,
            currentDisplayZoom: 2.35,
            maxAutoDisplayZoom: 5.0,
            now: t0.addingTimeInterval(3.0)
        )
        XCTAssertEqual(reset, .resetZoom)
    }

    func testManualOverrideSuppressesAutoZoom() {
        var policy = QRAutoZoomPolicy()
        let t0 = Date(timeIntervalSince1970: 4000)
        policy.registerManualZoom(at: t0)

        let smallQR = QRDetectionResult(
            score: 0.90,
            cropRect: CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10),
            fullFrameRect: CGRect(x: 0.45, y: 0.47, width: 0.10, height: 0.06)
        )
        let suppressed = policy.evaluate(
            detection: smallQR,
            currentDisplayZoom: 1.0,
            maxAutoDisplayZoom: 5.0,
            now: t0.addingTimeInterval(1.0)
        )
        XCTAssertEqual(suppressed, .none)
    }

    func testCompiledWeChatCoreMLModelDetectsDistantSmallQRCode() throws {
        let detector = try XCTUnwrap(WeChatQRSSDDetector(bundle: .main))

        // 在 1080×1920 画面中心放置仅 72×72px（6.7% 宽）的远距支付宝二维码
        let scene = makeSyntheticQRScene(qrSize: 72, includeQR: true)
        let result = try XCTUnwrap(detector.detect(in: scene))
        XCTAssertGreaterThan(result.score, 0.45)
        XCTAssertEqual(result.cropRect.midX, 0.5, accuracy: 0.08)
        XCTAssertEqual(result.cropRect.midY, 0.5, accuracy: 0.08)
        XCTAssertLessThan(result.dominantSizeInCrop, 0.15)

        // 空白背景应无误检
        let blankScene = makeSyntheticQRScene(qrSize: 0, includeQR: false)
        XCTAssertNil(detector.detect(in: blankScene))
    }

    private func makeSyntheticQRScene(qrSize: CGFloat, includeQR: Bool) -> CGImage {
        let width = 1080
        let height = 1920
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(red: 0.78, green: 0.74, blue: 0.68, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        if includeQR, let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue("https://qr.alipay.com/fkx1234567890demo".data(using: .utf8), forKey: "inputMessage")
            filter.setValue("M", forKey: "inputCorrectionLevel")
            if let output = filter.outputImage {
                let scale = qrSize / output.extent.width
                let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                if let qrCG = CIContext().createCGImage(scaled, from: scaled.extent) {
                    let cx = CGFloat(width) / 2.0
                    let cy = CGFloat(height) / 2.0
                    let pad = max(8, qrSize * 0.16)
                    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                    ctx.fill(CGRect(x: cx - qrSize / 2 - pad, y: cy - qrSize / 2 - pad, width: qrSize + pad * 2, height: qrSize + pad * 2))
                    ctx.interpolationQuality = .none
                    ctx.draw(qrCG, in: CGRect(x: cx - qrSize / 2, y: cy - qrSize / 2, width: qrSize, height: qrSize))
                }
            }
        }
        return ctx.makeImage()!
    }
}
