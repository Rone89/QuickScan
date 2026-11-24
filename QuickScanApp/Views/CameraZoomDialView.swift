import SwiftUI
import UIKit

/// iOS 27 原生系统相机风格的液态玻璃焦距拨轮：
/// - 收起态：紧凑三档清透玻璃胶囊（1× / 2× / 真机长焦），点按瞬切对应镜头
/// - 拨动任一处横向滑动即可展开为对数刻度 3D 弧面拨轮，带精细 Taptic 刻度震动与光学档位吸附，松手自动收起
struct CameraZoomDialView: View {
    let currentZoom: CGFloat
    let presets: [CGFloat]
    let maxZoom: CGFloat
    let activeLensName: String
    let isTelephotoActive: Bool
    let onSelectPreset: (CGFloat) -> Void
    let onScrubZoom: (CGFloat) -> Void

    @State private var isExpanded = false
    @State private var isDragging = false
    @State private var dragStartLogZoom: CGFloat = 0
    @State private var lastTickIndex: Int?
    @State private var collapseTask: Task<Void, Never>?

    private let pointsPerOctave: CGFloat = 112
    private let ticksPerOctave: Int = 10

    private let selectionHaptic = UISelectionFeedbackGenerator()
    private let majorDetentHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let minorTickHaptic = UIImpactFeedbackGenerator(style: .light)

    private var majorStops: [CGFloat] {
        var stops = presets
        for extra in [CGFloat(8.0), CGFloat(10.0)] where extra <= maxZoom + 0.05 {
            if !stops.contains(where: { abs($0 - extra) < 0.25 }) {
                stops.append(extra)
            }
        }
        return stops.sorted()
    }

    var body: some View {
        VStack(spacing: 8) {
            if isExpanded {
                // 展开态顶部悬浮焦距读数与当前物理镜头指示（主摄 / 长焦）
                HStack(spacing: 6) {
                    Text(activeLensName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isTelephotoActive ? Color.black : Color.white.opacity(0.9))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            isTelephotoActive ? Color.yellow : Color.white.opacity(0.2),
                            in: Capsule()
                        )

                    Text(formatZoomValue(currentZoom, withUnit: true))
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(Color.yellow)
                        .shadow(color: .black.opacity(0.55), radius: 5, y: 1)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.88)))
            } else if isTelephotoActive {
                Text("长焦镜头")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.yellow)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .glassEffect(.clear, in: .capsule)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            ZStack {
                if isExpanded {
                    expandedDialRuler
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                } else {
                    collapsedPresetPill
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
            .contentShape(Capsule())
            .simultaneousGesture(dialDragGesture)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: isExpanded)
        .onDisappear {
            collapseTask?.cancel()
        }
    }

    // MARK: - Collapsed Native Multi-Stop Capsule

    private var collapsedPresetPill: some View {
        let activeIndex = activeZoomPresetIndex()

        return HStack(spacing: 4) {
            ForEach(Array(presets.enumerated()), id: \.offset) { index, stop in
                let isActive = index == activeIndex
                Button {
                    guard !isDragging else { return }
                    selectionHaptic.selectionChanged()
                    onSelectPreset(stop)
                } label: {
                    Text(isActive ? formatZoomValue(currentZoom, withUnit: true) : formatZoomValue(stop, withUnit: false))
                        .font(.system(size: isActive ? 12.5 : 11.5, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(isActive ? Color.yellow : Color.white.opacity(0.88))
                        .frame(width: isActive ? 42 : 32, height: 32)
                        .background(
                            isActive ? Color.white.opacity(0.18) : Color.clear,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换至 \(formatZoomValue(stop, withUnit: true)) 焦距")
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .glassEffect(.clear.interactive(), in: .capsule)
        .animation(.snappy(duration: 0.22), value: activeIndex)
    }

    // MARK: - Expanded Curved Tick-Mark Zoom Dial Wheel

    private var expandedDialRuler: some View {
        let safeCurrent = max(1.0, min(currentZoom, maxZoom))
        let currentLog = log2(safeCurrent)
        let maxLog = log2(max(1.01, maxZoom))
        let majorLogs = majorStops.map { (stop: $0, logVal: log2($0)) }

        return ZStack {
            Canvas { context, size in
                let centerX = size.width * 0.5
                let halfSpan = size.width * 0.48
                let baseY = size.height * 0.52

                // 1. 按对数等距绘制精细次刻度（每倍焦距 10 格，手感与原生相机一致）
                let totalMinorTicks = Int(floor(maxLog * CGFloat(ticksPerOctave)))
                for idx in 0...totalMinorTicks {
                    let tickLog = CGFloat(idx) / CGFloat(ticksPerOctave)
                    let dx = (tickLog - currentLog) * pointsPerOctave
                    guard abs(dx) <= halfSpan else { continue }

                    // 靠近主光学刻度时跳过次刻度，避免双线重叠
                    if majorLogs.contains(where: { abs($0.logVal - tickLog) < 0.035 }) {
                        continue
                    }

                    let norm = abs(dx) / halfSpan
                    let edgeAlpha = max(0, 1.0 - pow(norm, 2.0))
                    let arcDrop = pow(norm, 2.0) * 5.0
                    let x = centerX + dx
                    let isHalfStep = (idx % 5 == 0)
                    let tickHeight: CGFloat = isHalfStep ? 11.5 : 8.0

                    let rect = CGRect(
                        x: x - 0.65,
                        y: baseY - tickHeight * 0.5 + arcDrop,
                        width: 1.3,
                        height: tickHeight
                    )
                    let alpha = (isHalfStep ? 0.68 : 0.40) * edgeAlpha
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 0.65),
                        with: .color(.white.opacity(alpha))
                    )
                }

                // 2. 绘制物理光学焦段主刻度与刻度数值标签
                for entry in majorLogs {
                    let dx = (entry.logVal - currentLog) * pointsPerOctave
                    guard abs(dx) <= halfSpan else { continue }

                    let norm = abs(dx) / halfSpan
                    let edgeAlpha = max(0, 1.0 - pow(norm, 2.0))
                    let arcDrop = pow(norm, 2.0) * 5.0
                    let x = centerX + dx
                    let isNearCenter = abs(dx) < 8

                    let tickHeight: CGFloat = 15.5
                    let rect = CGRect(
                        x: x - 0.9,
                        y: baseY - tickHeight * 0.5 + arcDrop - 1.5,
                        width: 1.8,
                        height: tickHeight
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 0.9),
                        with: .color((isNearCenter ? Color.yellow : Color.white).opacity(0.95 * edgeAlpha))
                    )

                    // 主刻度下方小号倍率标注（1× / 2× / 4× / 8× 等）
                    let labelText = Text(formatZoomValue(entry.stop, withUnit: true))
                        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle((isNearCenter ? Color.yellow : Color.white).opacity(0.88 * edgeAlpha))
                    context.draw(
                        labelText,
                        at: CGPoint(x: x, y: baseY + 15.5 + arcDrop),
                        anchor: .center
                    )
                }

                // 3. 固定居中相机黄指示指针
                let needleRect = CGRect(
                    x: centerX - 1.25,
                    y: baseY - 12.5,
                    width: 2.5,
                    height: 21.0
                )
                context.fill(
                    Path(roundedRect: needleRect, cornerRadius: 1.25),
                    with: .color(.yellow)
                )
            }
            .frame(width: 292, height: 56)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .white, location: 0.14),
                        .init(color: .white, location: 0.86),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .frame(width: 296, height: 56)
        .glassEffect(.clear.interactive(), in: .capsule)
        .accessibilityLabel("焦距拨轮，当前 \(formatZoomValue(currentZoom, withUnit: true))")
    }

    // MARK: - Drag Gesture & Tactile Detent Feedback

    private var dialDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                collapseTask?.cancel()

                if !isDragging {
                    isDragging = true
                    dragStartLogZoom = log2(max(1.0, currentZoom))
                    lastTickIndex = Int((dragStartLogZoom * CGFloat(ticksPerOctave)).rounded())
                    minorTickHaptic.prepare()
                    majorDetentHaptic.prepare()
                    if !isExpanded {
                        isExpanded = true
                    }
                }

                let maxLog = log2(max(1.01, maxZoom))
                // 向左滑放大、向右滑缩小（与 iOS 系统相机一致）
                let deltaLog = -value.translation.width / pointsPerOctave
                let targetLog = max(0.0, min(maxLog, dragStartLogZoom + deltaLog))
                let targetZoom = pow(2.0, targetLog)

                // 刻度触感反馈：光学主档位强阻尼感，普通刻度轻震动
                let tickIdx = Int((targetLog * CGFloat(ticksPerOctave)).rounded())
                if tickIdx != lastTickIndex {
                    lastTickIndex = tickIdx
                    let hitMajorStop = majorStops.contains { abs(log2($0) - targetLog) < 0.055 }
                    if hitMajorStop {
                        majorDetentHaptic.impactOccurred(intensity: 0.85)
                    } else {
                        minorTickHaptic.impactOccurred(intensity: 0.35)
                    }
                }

                onScrubZoom(targetZoom)
            }
            .onEnded { _ in
                isDragging = false
                lastTickIndex = nil

                // 松手时若非常接近物理光学焦段（误差 < 3.5%），磁吸对齐到精准光学倍率
                if let nearestStop = majorStops.first(where: { abs(currentZoom - $0) / max($0, 1.0) < 0.035 }) {
                    onSelectPreset(nearestStop)
                }

                scheduleAutoCollapse()
            }
    }

    private func scheduleAutoCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, !isDragging else { return }
            isExpanded = false
        }
    }

    // MARK: - Helpers

    private func activeZoomPresetIndex() -> Int {
        guard !presets.isEmpty else { return 0 }
        var active = 0
        for (idx, stop) in presets.enumerated() {
            if currentZoom >= stop - 0.12 {
                active = idx
            }
        }
        return active
    }

    private func formatZoomValue(_ value: CGFloat, withUnit: Bool) -> String {
        let rounded = (value * 10).rounded() / 10
        let number: String
        if abs(rounded - rounded.rounded()) < 0.05 {
            number = "\(Int(rounded.rounded()))"
        } else {
            number = String(format: "%.1f", rounded)
        }
        return withUnit ? "\(number)×" : number
    }
}
