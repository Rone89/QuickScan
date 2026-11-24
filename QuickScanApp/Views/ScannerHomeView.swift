import PhotosUI
import SwiftUI
import UIKit

/// 主扫码界面：iOS 27 原生 Liquid Glass 相机取景风格，识别微信/支付宝二维码后无提示直接跳转
struct ScannerHomeView: View {
    let actionCenter: QuickScanActionCenter
    let scanner: CameraScannerController

    @Environment(\.scenePhase) private var scenePhase

    @State private var historyStore = ScanHistoryStore()
    private let urlOpener: any URLOpening = SystemURLOpener()

    @State private var baseZoomFactor: CGFloat = 1.0
    @State private var viewfinderBreathing = false
    @State private var focusIndicatorPoint: CGPoint?
    @State private var focusIndicatorID = UUID()

    @State private var lastHandledPayload: String?
    @State private var lastHandledDate: Date = .distantPast

    @State private var activeResult: ScanResultPresentation?
    @State private var showHistory = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?

    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        ZStack {
            cameraLayer
                .ignoresSafeArea()

            if scanner.authorizationState == .authorized {
                nativeViewfinderOverlay
                focusIndicatorLayer
            }

            liquidGlassControlsOverlay
        }
        .statusBarHidden(false)
        .task {
            impactFeedback.prepare()
            scanner.onQRCodeDetected = { payload in
                handleDetectedPayload(payload)
            }
            await scanner.prepareAndStart()
            if let deepLink = actionCenter.pendingPayload {
                consumeDeepLink(deepLink)
            }
        }
        .onDisappear {
            scanner.stop()
        }
        .onChange(of: actionCenter.pendingRequestToken) { _, _ in
            guard let payload = actionCenter.pendingPayload else { return }
            consumeDeepLink(payload)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task {
                    await scanner.prepareAndStart()
                    if scanner.authorizationState == .authorized,
                       activeResult == nil, !showHistory, !showPhotoPicker {
                        scanner.resetZoom(animated: false)
                        baseZoomFactor = 1.0
                        scanner.resumeDetection()
                    }
                }
            case .background:
                scanner.pauseDetection()
            default:
                break
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await decodeQRCodeFromPhoto(newItem)
                selectedPhotoItem = nil
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItem,
            matching: .images
        )
        .sheet(item: $activeResult, onDismiss: {
            scanner.resumeDetection()
        }) { presentation in
            ScanResultSheetView(
                presentation: presentation,
                onOpenAlipay: { raw in
                    activeResult = nil
                    openInAlipayDirectly(raw)
                },
                onOpenWeChatScan: {
                    activeResult = nil
                    openWeChatScanner()
                },
                onOpenWeb: { url in
                    activeResult = nil
                    urlOpener.openExternalURL(url)
                    scanner.resumeDetection()
                },
                onDismiss: {
                    activeResult = nil
                }
            )
        }
        .sheet(isPresented: $showHistory, onDismiss: {
            if activeResult == nil {
                scanner.resumeDetection()
            }
        }) {
            ScanHistoryView(historyStore: historyStore) { payload in
                lastHandledPayload = nil
                handleDetectedPayload(payload)
            }
        }
    }

    // MARK: - Camera & State Layers

    @ViewBuilder
    private var cameraLayer: some View {
        switch scanner.authorizationState {
        case .authorized:
            CameraPreviewView(
                session: scanner.sessionManager.session,
                onFocus: { devicePoint, viewPoint in
                    scanner.focus(at: devicePoint)
                    triggerFocusIndicator(at: viewPoint)
                },
                onZoom: { scale, ended in
                    scanner.applyManualZoom(scale: scale, baseZoom: baseZoomFactor)
                    if ended {
                        baseZoomFactor = scanner.currentZoomFactor
                    }
                }
            )
        case .notDetermined:
            Color.black
                .overlay {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
        case .denied:
            permissionDeniedView
        case .unavailable:
            simulatorFallbackView
        }
    }

    private var permissionDeniedView: some View {
        Color(.systemBackground)
            .overlay {
                ContentUnavailableView {
                    Label("需要相机权限", systemImage: "camera.fill")
                } description: {
                    Text("请在系统设置中开启相机权限，即可自动扫描微信和支付宝二维码并直接跳转。")
                } actions: {
                    Button("前往系统设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            urlOpener.openExternalURL(url)
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
            }
    }

    private var simulatorFallbackView: some View {
        Color(.systemGroupedBackground)
            .overlay {
                VStack(spacing: 24) {
                    ContentUnavailableView {
                        Label("快捷扫码", systemImage: "qrcode.viewfinder")
                    } description: {
                        Text("真机运行将直接启用实时相机扫码；当前环境可模拟测试路由逻辑或从相册识别。")
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 12) {
                        Button {
                            lastHandledPayload = nil
                            handleDetectedPayload("wxp://f2f0DemoWeChatPaymentCode123456")
                        } label: {
                            Label("模拟微信二维码（直跳扫一扫）", systemImage: "message.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Color(red: 0.03, green: 0.76, blue: 0.38))
                        .controlSize(.large)

                        Button {
                            lastHandledPayload = nil
                            handleDetectedPayload("https://qr.alipay.com/fkx1234567890demo")
                        } label: {
                            Label("模拟支付宝二维码（直接打开）", systemImage: "creditcard.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Color(red: 0.09, green: 0.47, blue: 1.0))
                        .controlSize(.large)

                        Button {
                            lastHandledPayload = nil
                            handleDetectedPayload("https://example.com/pay?merchant=demo")
                        } label: {
                            Label("模拟普通 / 聚合二维码", systemImage: "qrcode")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                    .padding(.horizontal, 28)
                }
            }
    }

    // MARK: - Native iOS Code Scanner Viewfinder

    private var nativeViewfinderOverlay: some View {
        GeometryReader { proxy in
            let frameSize = min(proxy.size.width * 0.66, 264)
            ZStack {
                // 全屏覆盖至状态栏与底部小白条的轻薄光学遮罩（eoFill 精准镂空中间取景框）
                ViewfinderScrimShape(cutoutSize: frameSize, cornerRadius: 28)
                    .fill(Color.black.opacity(0.24), style: FillStyle(eoFill: true))

                // 原生系统扫码同款纯白呼吸四角取景框
                ViewfinderCornersShape(cornerLength: 32, cornerRadius: 28)
                    .stroke(
                        .white.opacity(viewfinderBreathing ? 0.96 : 0.72),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                    )
                    .shadow(color: .black.opacity(0.32), radius: 8, y: 2)
                    .frame(width: frameSize, height: frameSize)
                    .scaleEffect(viewfinderBreathing ? 1.0 : 0.975)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                            viewfinderBreathing = true
                        }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var focusIndicatorLayer: some View {
        if let point = focusIndicatorPoint {
            ZStack(alignment: .topLeading) {
                Color.clear
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.yellow, lineWidth: 1.5)
                    .frame(width: 68, height: 68)
                    .position(point)
                    .id(focusIndicatorID)
                    .transition(.scale(scale: 1.25).combined(with: .opacity))
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    // MARK: - iOS 27 Native Liquid Glass Floating Chrome

    private var liquidGlassControlsOverlay: some View {
        let isCameraLive = scanner.authorizationState == .authorized
        let foreground: Color = isCameraLive ? .white : .primary

        return VStack(spacing: 0) {
            // 顶部 Liquid Glass 悬浮栏
            GlassEffectContainer(spacing: 12) {
                HStack {
                    HStack(spacing: 7) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.subheadline.weight(.semibold))
                        Text("快捷扫码")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(foreground)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .glassEffect(isCameraLive ? .clear : .regular, in: .capsule)

                    Spacer()

                    Button {
                        scanner.pauseDetection()
                        showHistory = true
                    } label: {
                        Image(systemName: "clock")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(foreground)
                            .frame(width: 44, height: 44)
                    }
                    .glassEffect(isCameraLive ? .clear.interactive() : .regular.interactive(), in: .circle)
                    .accessibilityLabel("最近扫码")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            Spacer()

            // 底部控制区：系统相机同款液态玻璃焦距拨轮 + 引导文案 + Liquid Glass 圆形功能坞
            VStack(spacing: 14) {
                if isCameraLive {
                    CameraZoomDialView(
                        currentZoom: scanner.currentZoomFactor,
                        presets: scanner.zoomPresets,
                        maxZoom: scanner.maxManualZoomFactor,
                        activeLensName: scanner.activeLensName,
                        isTelephotoActive: scanner.isTelephotoActive,
                        onSelectPreset: { stop in
                            baseZoomFactor = stop
                            scanner.setQuickZoom(stop)
                        },
                        onScrubZoom: { factor in
                            baseZoomFactor = factor
                            scanner.applyDialZoom(factor)
                        }
                    )

                    Text("对准微信或支付宝二维码")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.86))
                        .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
                }

                GlassEffectContainer(spacing: 28) {
                    HStack(spacing: 28) {
                        Button {
                            scanner.pauseDetection()
                            showPhotoPicker = true
                        } label: {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 21, weight: .medium))
                                .foregroundStyle(foreground)
                                .frame(width: 56, height: 56)
                        }
                        .glassEffect(isCameraLive ? .clear.interactive() : .regular.interactive(), in: .circle)
                        .accessibilityLabel("从相册识别二维码")

                        if scanner.isTorchAvailable {
                            Button {
                                scanner.toggleTorch()
                            } label: {
                                Image(systemName: scanner.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                    .font(.system(size: 21, weight: .medium))
                                    .foregroundStyle(scanner.isTorchOn ? .black : .white)
                                    .symbolEffect(.bounce, value: scanner.isTorchOn)
                                    .frame(width: 56, height: 56)
                            }
                            .glassEffect(
                                scanner.isTorchOn
                                    ? .regular.tint(.yellow).interactive()
                                    : .clear.interactive(),
                                in: .circle
                            )
                            .accessibilityLabel(scanner.isTorchOn ? "关闭手电筒" : "开启手电筒")
                        }
                    }
                }
            }
            .padding(.bottom, 26)
        }
    }

    private func triggerFocusIndicator(at point: CGPoint) {
        let token = UUID()
        focusIndicatorID = token
        withAnimation(.snappy(duration: 0.22)) {
            focusIndicatorPoint = point
        }
        Task {
            try? await Task.sleep(for: .milliseconds(850))
            if focusIndicatorID == token {
                withAnimation(.easeOut(duration: 0.2)) {
                    focusIndicatorPoint = nil
                }
            }
        }
    }

    // MARK: - Deep Link & Silent Direct Routing

    private func consumeDeepLink(_ payload: QuickScanDeepLink.Payload) {
        actionCenter.pendingPayload = nil
        activeResult = nil
        showHistory = false
        lastHandledPayload = nil

        switch payload.action {
        case .scan:
            showPhotoPicker = false
            baseZoomFactor = 1.0
            scanner.resetZoom(animated: false)
            Task {
                await scanner.prepareAndStart()
                scanner.resumeDetection()
            }
        case .album:
            scanner.pauseDetection()
            showPhotoPicker = true
        }
    }

    private func handleDetectedPayload(_ rawPayload: String) {
        guard let route = QRCodeRouter.route(for: rawPayload) else {
            scanner.resumeDetection()
            return
        }

        // 防抖：返回前台瞬间若镜头仍对准同一张码，1.2 秒内不重复触发
        let now = Date()
        if lastHandledPayload == route.rawPayload, now.timeIntervalSince(lastHandledDate) < 1.2 {
            scanner.resumeDetection()
            return
        }
        lastHandledPayload = route.rawPayload
        lastHandledDate = now

        impactFeedback.impactOccurred()
        historyStore.record(route: route)

        switch route.platform {
        case .wechat, .alipay:
            // 无提示直接跳转
            urlOpener.openRouteImmediately(route) { outcome in
                handleOpenOutcome(outcome, route: route)
            }
        case .other:
            activeResult = ScanResultPresentation(route: route, notice: nil)
        }
    }

    private func handleOpenOutcome(_ outcome: URLOpenOutcome, route: QRCodeRoute) {
        switch outcome {
        case .opened:
            // 成功发起跳转；若用户取消离开仍留在当前页，稍后静默恢复取景识别
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                if activeResult == nil && !showHistory && !showPhotoPicker {
                    scanner.resumeDetection()
                }
            }
        case .appNotInstalled(let platform):
            activeResult = ScanResultPresentation(
                route: route,
                notice: "未能打开\(platform.displayName)，请确认设备已安装\(platform.displayName)。"
            )
        case .failed:
            activeResult = ScanResultPresentation(
                route: route,
                notice: "无法直接打开该链接，可手动复制或选择其他方式。"
            )
        }
    }

    private func openInAlipayDirectly(_ rawPayload: String) {
        let manualRoute = QRCodeRoute(
            rawPayload: rawPayload,
            platform: .alipay,
            targetURL: QRCodeRouter.alipayDirectURL(for: rawPayload),
            fallbackURL: QRCodeRouter.alipayFallbackURL(for: rawPayload),
            webURL: nil
        )
        urlOpener.openRouteImmediately(manualRoute) { outcome in
            handleOpenOutcome(outcome, route: manualRoute)
        }
    }

    private func openWeChatScanner() {
        let manualRoute = QRCodeRoute(
            rawPayload: "",
            platform: .wechat,
            targetURL: QRCodeRouter.wechatScanURL,
            fallbackURL: QRCodeRouter.wechatFallbackURL,
            webURL: nil
        )
        urlOpener.openRouteImmediately(manualRoute) { _ in
            Task {
                try? await Task.sleep(for: .seconds(1.0))
                scanner.resumeDetection()
            }
        }
    }

    private func decodeQRCodeFromPhoto(_ item: PhotosPickerItem) async {
        defer {
            if activeResult == nil {
                scanner.resumeDetection()
            }
        }

        guard let data = try? await item.loadTransferable(type: Data.self) else {
            return
        }

        let payload = await Task.detached(priority: .userInitiated) {
            CameraScannerController.detectQRCode(in: data)
        }.value

        if let payload {
            lastHandledPayload = nil
            handleDetectedPayload(payload)
        }
    }
}

/// 全屏遮罩镂空形状（配合 eoFill 覆盖状态栏与底部指示条且中间无接缝）
struct ViewfinderScrimShape: Shape {
    let cutoutSize: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        let cutout = CGRect(
            x: rect.midX - cutoutSize / 2,
            y: rect.midY - cutoutSize / 2,
            width: cutoutSize,
            height: cutoutSize
        )
        path.addRoundedRect(
            in: cutout,
            cornerSize: CGSize(width: cornerRadius, height: cornerRadius),
            style: .continuous
        )
        return path
    }
}

/// 原生系统扫码风格四角取景描边
struct ViewfinderCornersShape: Shape {
    let cornerLength: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = cornerRadius
        let l = cornerLength

        // 左上
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + l))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))

        // 右上
        path.move(to: CGPoint(x: rect.maxX - l, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(270),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))

        // 右下
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))

        // 左下
        path.move(to: CGPoint(x: rect.minX + l, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))

        return path
    }
}
