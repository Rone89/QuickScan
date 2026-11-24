import AVFoundation
import SwiftUI
import UIKit

/// 承载 AVCaptureVideoPreviewLayer 的 UIKit 容器，支持双指缩放与点击对焦
final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }

    /// 回调参数：(设备归一化对焦点, 视图坐标点击点)
    var onFocusRequested: ((CGPoint, CGPoint) -> Void)?
    var onZoomScaleChanged: ((CGFloat, Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        setupGestures()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let viewPoint = recognizer.location(in: self)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
        onFocusRequested?(devicePoint, viewPoint)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .changed:
            onZoomScaleChanged?(recognizer.scale, false)
        case .ended, .cancelled, .failed:
            onZoomScaleChanged?(recognizer.scale, true)
        default:
            break
        }
    }
}

/// 将相机预览桥接到 SwiftUI
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let onFocus: (CGPoint, CGPoint) -> Void
    let onZoom: (CGFloat, Bool) -> Void

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.onFocusRequested = onFocus
        view.onZoomScaleChanged = onZoom
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.onFocusRequested = onFocus
        uiView.onZoomScaleChanged = onZoom
    }
}
