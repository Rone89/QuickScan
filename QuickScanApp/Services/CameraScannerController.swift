import AVFoundation
import CoreImage
import Observation
import UIKit
import Vision

/// 相机授权与硬件状态
enum CameraAuthorizationState: Equatable {
    case notDetermined
    case authorized
    case denied
    case unavailable
}

/// 负责在独立串行队列上管理 AVCaptureSession、多摄平滑光学变焦、二维码元数据解码及微信 SSD 远距检测
final class CameraSessionManager: NSObject,
                                  AVCaptureMetadataOutputObjectsDelegate,
                                  AVCaptureVideoDataOutputSampleBufferDelegate,
                                  @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.quickscan.camera.session", qos: .userInitiated)
    private let metadataQueue = DispatchQueue(label: "com.quickscan.camera.metadata", qos: .userInitiated)
    private let visionQueue = DispatchQueue(label: "com.quickscan.camera.vision", qos: .userInitiated)

    private var videoDevice: AVCaptureDevice?
    private var zoomObservation: NSKeyValueObservation?
    private var activeLensObservation: NSKeyValueObservation?
    private var wideBaseZoomFactor: CGFloat = 1.0
    private var telephotoConstituentDevice: AVCaptureDevice?
    private var telephotoSwitchOverHWZoom: CGFloat?
    private var telephotoDisplayZoomFactor: CGFloat?
    private var maxAutoDisplayZoomFactor: CGFloat = 5.0
    private var maxManualDisplayZoomFactor: CGFloat = 10.0
    private var isConfigured = false

    private let stateLock = NSLock()
    private var isDetectionPaused = false
    private var isVisionBusy = false
    private var lastVisionInferenceUptime: TimeInterval = 0
    private var autoZoomPolicy = QRAutoZoomPolicy()

    private lazy var ssdDetector: WeChatQRSSDDetector? = WeChatQRSSDDetector()

    var onQRCodeDetected: (@Sendable (String) -> Void)?
    var onTorchAvailabilityChanged: (@Sendable (Bool) -> Void)?
    var onTorchStateChanged: (@Sendable (Bool) -> Void)?
    var onZoomFactorChanged: (@Sendable (CGFloat) -> Void)?
    var onZoomPresetsChanged: (@Sendable ([CGFloat], CGFloat) -> Void)?
    var onActiveLensChanged: (@Sendable (String, Bool) -> Void)?
    var onCameraUnavailable: (@Sendable () -> Void)?

    deinit {
        zoomObservation?.invalidate()
        activeLensObservation?.invalidate()
    }

    func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                guard self.configureSessionLocked() else {
                    self.onCameraUnavailable?()
                    return
                }
                self.isConfigured = true
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.setTorchLocked(enabled: false)
                self.session.stopRunning()
            }
        }
    }

    func setDetectionPaused(_ paused: Bool) {
        stateLock.lock()
        isDetectionPaused = paused
        if !paused {
            autoZoomPolicy.reset()
        }
        stateLock.unlock()
    }

    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice, device.hasTorch else { return }
            let nextState = device.torchMode != .on
            self.setTorchLocked(enabled: nextState)
        }
    }

    func setManualDisplayZoom(_ displayZoom: CGFloat, animated: Bool = false) {
        stateLock.lock()
        autoZoomPolicy.registerManualZoom()
        stateLock.unlock()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applyDisplayZoomLocked(
                displayZoom,
                animated: animated,
                rate: 6.5,
                maxDisplayZoom: self.maxManualDisplayZoomFactor
            )
        }
    }

    func resetZoom(animated: Bool) {
        stateLock.lock()
        autoZoomPolicy.reset()
        stateLock.unlock()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applyDisplayZoomLocked(
                1.0,
                animated: animated,
                rate: 5.0,
                maxDisplayZoom: self.maxManualDisplayZoomFactor
            )
        }
    }

    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            self.focusLocked(device: device, at: devicePoint)
        }
    }

    // MARK: - Session Setup

    private func selectBestRearCamera() -> AVCaptureDevice? {
        let preferredTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferredTypes,
            mediaType: .video,
            position: .back
        )
        for type in preferredTypes {
            if let match = discovery.devices.first(where: { $0.deviceType == type }) {
                return match
            }
        }
        return AVCaptureDevice.default(for: .video)
    }

    private func computeWideBaseZoom(for device: AVCaptureDevice) -> CGFloat {
        // 虚拟三摄/双广角设备的 1.0 为 0.5× 超广角，首档切换点才是标准 1× 主摄
        if device.isVirtualDevice,
           device.constituentDevices.first?.deviceType == .builtInUltraWideCamera,
           let firstSwitch = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            return max(1.0, CGFloat(truncating: firstSwitch))
        }
        return 1.0
    }

    private func computeTelephotoInfo(for device: AVCaptureDevice, wideBase: CGFloat) -> (device: AVCaptureDevice, hwSwitchZoom: CGFloat, displayZoom: CGFloat)? {
        guard device.isVirtualDevice else { return nil }
        guard let teleIdx = device.constituentDevices.firstIndex(where: { $0.deviceType == .builtInTelephotoCamera }),
              teleIdx > 0 else {
            return nil
        }
        let switches = device.virtualDeviceSwitchOverVideoZoomFactors
        let switchIndex = teleIdx - 1
        guard switches.indices.contains(switchIndex) else { return nil }
        let hwZoom = CGFloat(truncating: switches[switchIndex])
        let rawDisplay = hwZoom / wideBase
        let normalized = (rawDisplay * 2.0).rounded() / 2.0
        guard normalized > 1.2 else { return nil }
        return (device.constituentDevices[teleIdx], hwZoom, normalized)
    }

    private func buildZoomPresets(telephotoDisplayZoom: CGFloat?, maxDisplayZoom: CGFloat) -> [CGFloat] {
        var stops: [CGFloat] = [1.0]
        if maxDisplayZoom >= 2.0 {
            stops.append(2.0)
        }
        if let tele = telephotoDisplayZoom, tele <= maxDisplayZoom + 0.05 {
            if !stops.contains(where: { abs($0 - tele) < 0.15 }) {
                stops.append(tele)
            }
        }
        return stops.sorted()
    }

    private func configureSessionLocked() -> Bool {
        guard let device = selectBestRearCamera() else {
            return false
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return false }
            session.addInput(input)
            videoDevice = device
            wideBaseZoomFactor = computeWideBaseZoom(for: device)
            let hardwareMaxDisplay = max(1.0, device.activeFormat.videoMaxZoomFactor / wideBaseZoomFactor)
            if let teleInfo = computeTelephotoInfo(for: device, wideBase: wideBaseZoomFactor) {
                telephotoConstituentDevice = teleInfo.device
                telephotoSwitchOverHWZoom = teleInfo.hwSwitchZoom
                telephotoDisplayZoomFactor = teleInfo.displayZoom
            } else {
                telephotoConstituentDevice = nil
                telephotoSwitchOverHWZoom = nil
                telephotoDisplayZoomFactor = nil
            }
            // 自动变焦上限动态覆盖硬件物理长焦档（最高 8×），手动缩放支持至 10×
            let desiredAutoCap = max(5.0, (telephotoDisplayZoomFactor ?? 4.0) * 1.25)
            maxAutoDisplayZoomFactor = min(min(desiredAutoCap, 8.0), hardwareMaxDisplay)
            maxManualDisplayZoomFactor = min(10.0, hardwareMaxDisplay)
            let presets = buildZoomPresets(
                telephotoDisplayZoom: telephotoDisplayZoomFactor,
                maxDisplayZoom: maxManualDisplayZoomFactor
            )
            onZoomPresetsChanged?(presets, maxManualDisplayZoomFactor)
        } catch {
            return false
        }

        // 1. 硬件级 QR 元数据实时解码
        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else { return false }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: metadataQueue)
        if metadataOutput.availableMetadataObjectTypes.contains(.qr) {
            metadataOutput.metadataObjectTypes = [.qr]
        }

        // 2. 视频帧输出供微信开源 CoreML SSD 检测远距小二维码并触发自动光学变焦
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(self, queue: visionQueue)
        }

        // 初始化到标准 1× 焦段、禁止长焦回落主摄，并开启连续自动对焦
        do {
            try device.lockForConfiguration()
            if device.isVirtualDevice {
                // 清空回落列表，避免室内光线或中近距离时系统停留在主摄数码裁切而不切物理长焦
                device.fallbackPrimaryConstituentDevices = []
            }
            let initialZoom = min(wideBaseZoomFactor, device.activeFormat.videoMaxZoomFactor)
            device.videoZoomFactor = initialZoom
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {
            // 非致命配置
        }

        // 监听实际光学/数码变焦值，实时同步到主界面 Liquid Glass 焦距拨轮
        zoomObservation?.invalidate()
        let baseZoom = wideBaseZoomFactor
        zoomObservation = device.observe(\.videoZoomFactor, options: [.initial, .new]) { [weak self] _, change in
            guard let self, let hwZoom = change.newValue else { return }
            let display = max(0.5, hwZoom / baseZoom)
            self.onZoomFactorChanged?(display)
        }

        // 监听当前真实生效的物理镜头（主摄 / 长焦 / 超广角）
        activeLensObservation?.invalidate()
        activeLensObservation = device.observe(\.activePrimaryConstituent, options: [.initial, .new]) { [weak self] _, change in
            guard let self else { return }
            let activeDevice = change.newValue ?? nil
            let (label, isTele) = Self.describeLens(activeDevice)
            self.onActiveLensChanged?(label, isTele)
        }

        // 提前在后台预热 CoreML SSD 模型（避免首帧卡顿）
        visionQueue.async { [weak self] in
            _ = self?.ssdDetector
        }

        onTorchAvailabilityChanged?(device.hasTorch)
        onTorchStateChanged?(false)
        return true
    }

    private static func describeLens(_ device: AVCaptureDevice?) -> (String, Bool) {
        guard let device else { return ("主摄", false) }
        switch device.deviceType {
        case .builtInTelephotoCamera:
            return ("长焦", true)
        case .builtInUltraWideCamera:
            return ("超广角", false)
        default:
            return ("主摄", false)
        }
    }

    private func applyDisplayZoomLocked(
        _ displayZoom: CGFloat,
        animated: Bool,
        rate: Float,
        maxDisplayZoom: CGFloat
    ) {
        guard let device = videoDevice else { return }
        let hwMax = min(device.activeFormat.videoMaxZoomFactor, maxDisplayZoom * wideBaseZoomFactor)
        let hwMin = max(1.0, wideBaseZoomFactor)
        let targetHW = max(hwMin, min(displayZoom * wideBaseZoomFactor, hwMax))

        do {
            try device.lockForConfiguration()
            if device.isRampingVideoZoom {
                device.cancelVideoZoomRamp()
            }

            if device.isVirtualDevice,
               let tele = telephotoConstituentDevice,
               let teleHW = telephotoSwitchOverHWZoom {
                let wantsTelephoto = targetHW >= teleHW - 0.02

                if wantsTelephoto {
                    if #available(iOS 27.0, *),
                       device.isPrimaryConstituentDeviceSwitchingBehaviorLockedWithDeviceSupported {
                        if device.activePrimaryConstituent !== tele || device.primaryConstituentDeviceSwitchingBehavior != .locked {
                            // 直接锁定物理长焦子镜头，系统会立刻切到长焦硬件（并将焦距对齐至长焦起跳点）
                            device.setPrimaryConstituentDeviceSwitchingBehaviorLockedWith(tele)
                        }
                        let clampedTeleTarget = max(device.minAvailableVideoZoomFactor, min(targetHW, device.activeFormat.videoMaxZoomFactor))
                        if animated && abs(device.videoZoomFactor - clampedTeleTarget) > 0.05 {
                            device.ramp(toVideoZoomFactor: clampedTeleTarget, withRate: rate)
                        } else {
                            device.videoZoomFactor = clampedTeleTarget
                        }
                    } else {
                        if animated {
                            device.ramp(toVideoZoomFactor: targetHW, withRate: rate)
                        } else {
                            device.videoZoomFactor = targetHW
                        }
                    }
                } else {
                    // 降回低于长焦倍率前，必须先解除长焦锁定恢复 .auto，否则 minAvailableVideoZoomFactor 会被钳在长焦倍率
                    if device.primaryConstituentDeviceSwitchingBehavior == .locked {
                        device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
                    }
                    let clampedWideTarget = max(device.minAvailableVideoZoomFactor, min(targetHW, device.activeFormat.videoMaxZoomFactor))
                    if animated {
                        device.ramp(toVideoZoomFactor: clampedWideTarget, withRate: rate)
                    } else {
                        device.videoZoomFactor = clampedWideTarget
                    }
                }
            } else {
                let clamped = max(device.minAvailableVideoZoomFactor, min(targetHW, device.activeFormat.videoMaxZoomFactor))
                if animated {
                    device.ramp(toVideoZoomFactor: clamped, withRate: rate)
                } else {
                    device.videoZoomFactor = clamped
                }
            }

            device.unlockForConfiguration()
        } catch {
            // 忽略单次变焦锁定失败
        }
    }

    private func focusLocked(device: AVCaptureDevice, at devicePoint: CGPoint) {
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {
            // 忽略对焦失败
        }
    }

    private func setTorchLocked(enabled: Bool) {
        guard let device = videoDevice, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = enabled ? .on : .off
            device.unlockForConfiguration()
            onTorchStateChanged?(enabled)
        } catch {
            onTorchStateChanged?(false)
        }
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        stateLock.lock()
        let paused = isDetectionPaused
        stateLock.unlock()
        guard !paused else { return }

        guard let readable = metadataObjects.first(where: { $0.type == .qr }) as? AVMetadataMachineReadableCodeObject,
              let value = readable.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return
        }

        stateLock.lock()
        isDetectionPaused = true
        stateLock.unlock()

        onQRCodeDetected?(value)
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (WeChat SSD Auto-Zoom)

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let nowUptime = ProcessInfo.processInfo.systemUptime

        stateLock.lock()
        let shouldSkip = isDetectionPaused
            || isVisionBusy
            || (nowUptime - lastVisionInferenceUptime) < 0.13
        if !shouldSkip {
            isVisionBusy = true
            lastVisionInferenceUptime = nowUptime
        }
        stateLock.unlock()

        guard !shouldSkip else { return }
        defer {
            stateLock.lock()
            isVisionBusy = false
            stateLock.unlock()
        }

        guard let device = videoDevice,
              !device.isRampingVideoZoom,
              let detector = ssdDetector,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let detection = detector.detect(in: pixelBuffer)

        let currentDisplayZoom = max(1.0, device.videoZoomFactor / wideBaseZoomFactor)
        let maxAutoDisplayZoom = maxAutoDisplayZoomFactor

        stateLock.lock()
        let pausedNow = isDetectionPaused
        let decision: QRAutoZoomDecision = pausedNow
            ? .none
            : autoZoomPolicy.evaluate(
                detection: detection,
                currentDisplayZoom: currentDisplayZoom,
                maxAutoDisplayZoom: maxAutoDisplayZoom
            )
        stateLock.unlock()

        switch decision {
        case .none:
            break
        case .focusOnly(let point):
            sessionQueue.async { [weak self] in
                guard let self, let dev = self.videoDevice else { return }
                self.focusLocked(device: dev, at: point)
            }
        case .focusAndZoom(let targetZoom, let point):
            sessionQueue.async { [weak self] in
                guard let self, let dev = self.videoDevice else { return }
                self.focusLocked(device: dev, at: point)
                self.applyDisplayZoomLocked(
                    targetZoom,
                    animated: true,
                    rate: 5.0,
                    maxDisplayZoom: self.maxAutoDisplayZoomFactor
                )
            }
        case .resetZoom:
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.applyDisplayZoomLocked(
                    1.0,
                    animated: true,
                    rate: 3.8,
                    maxDisplayZoom: self.maxAutoDisplayZoomFactor
                )
            }
        }
    }
}

/// 主线程状态控制器，供 SwiftUI 视图绑定
@MainActor
@Observable
final class CameraScannerController {
    let sessionManager = CameraSessionManager()

    var authorizationState: CameraAuthorizationState = .notDetermined
    var isTorchAvailable = false
    var isTorchOn = false
    var currentZoomFactor: CGFloat = 1.0
    var zoomPresets: [CGFloat] = [1.0, 2.0]
    var maxManualZoomFactor: CGFloat = 10.0
    var activeLensName: String = "主摄"
    var isTelephotoActive: Bool = false

    var onQRCodeDetected: ((String) -> Void)?

    init() {
        sessionManager.onQRCodeDetected = { [weak self] payload in
            Task { @MainActor [weak self] in
                self?.onQRCodeDetected?(payload)
            }
        }
        sessionManager.onTorchAvailabilityChanged = { [weak self] available in
            Task { @MainActor [weak self] in
                self?.isTorchAvailable = available
            }
        }
        sessionManager.onTorchStateChanged = { [weak self] isOn in
            Task { @MainActor [weak self] in
                self?.isTorchOn = isOn
            }
        }
        sessionManager.onZoomFactorChanged = { [weak self] displayZoom in
            Task { @MainActor [weak self] in
                self?.currentZoomFactor = displayZoom
            }
        }
        sessionManager.onZoomPresetsChanged = { [weak self] presets, maxZoom in
            Task { @MainActor [weak self] in
                self?.zoomPresets = presets
                self?.maxManualZoomFactor = maxZoom
            }
        }
        sessionManager.onActiveLensChanged = { [weak self] lensName, isTele in
            Task { @MainActor [weak self] in
                self?.activeLensName = lensName
                self?.isTelephotoActive = isTele
            }
        }
        sessionManager.onCameraUnavailable = { [weak self] in
            Task { @MainActor [weak self] in
                self?.authorizationState = .unavailable
            }
        }
    }

    func prepareAndStart() async {
        #if targetEnvironment(simulator)
        authorizationState = .unavailable
        return
        #else
        guard AVCaptureDevice.default(for: .video) != nil else {
            authorizationState = .unavailable
            return
        }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            authorizationState = .authorized
            sessionManager.configureAndStart()
        case .notDetermined:
            authorizationState = .notDetermined
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorizationState = granted ? .authorized : .denied
            if granted {
                sessionManager.configureAndStart()
            }
        case .denied, .restricted:
            authorizationState = .denied
        @unknown default:
            authorizationState = .denied
        }
        #endif
    }

    func stop() {
        sessionManager.stop()
    }

    func pauseDetection() {
        sessionManager.setDetectionPaused(true)
    }

    func resumeDetection() {
        sessionManager.setDetectionPaused(false)
    }

    func toggleTorch() {
        sessionManager.toggleTorch()
    }

    func applyManualZoom(scale: CGFloat, baseZoom: CGFloat) {
        let nextZoom = max(1.0, min(baseZoom * scale, maxManualZoomFactor))
        currentZoomFactor = nextZoom
        sessionManager.setManualDisplayZoom(nextZoom, animated: false)
    }

    func applyDialZoom(_ factor: CGFloat) {
        let clamped = max(1.0, min(factor, maxManualZoomFactor))
        currentZoomFactor = clamped
        sessionManager.setManualDisplayZoom(clamped, animated: false)
    }

    func setQuickZoom(_ factor: CGFloat) {
        let clamped = max(1.0, min(factor, maxManualZoomFactor))
        currentZoomFactor = clamped
        sessionManager.setManualDisplayZoom(clamped, animated: true)
    }

    func resetZoom(animated: Bool = true) {
        sessionManager.resetZoom(animated: animated)
    }

    func focus(at devicePoint: CGPoint) {
        sessionManager.focus(at: devicePoint)
    }

    /// 从相册图片数据中识别二维码（CoreImage + Vision 双引擎兜底）
    nonisolated static func detectQRCode(in imageData: Data) -> String? {
        if let ciImage = CIImage(data: imageData) {
            let detector = CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: nil,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
            )
            if let features = detector?.features(in: ciImage) as? [CIQRCodeFeature],
               let payload = features.compactMap(\.messageString).first(where: { !$0.isEmpty }) {
                return payload
            }
        }

        guard let uiImage = UIImage(data: imageData), let cgImage = uiImage.cgImage else {
            return nil
        }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            if let observations = request.results,
               let payload = observations.compactMap(\.payloadStringValue).first(where: { !$0.isEmpty }) {
                return payload
            }
        } catch {
            return nil
        }

        return nil
    }
}
