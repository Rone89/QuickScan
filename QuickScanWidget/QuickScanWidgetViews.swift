import SwiftUI
import WidgetKit

/// iOS 27 液态玻璃风格自适应小组件：
/// - 完整色彩模式：高透光学渐变基底 + 镜面高光描边玻璃徽章 + 同心圆角磨砂卡片
/// - 液态玻璃透明 / 着色模式（.accented / .vibrant）：自动透出系统原生实时折射玻璃底板，突出 `.widgetAccentable()` 玻璃层次
struct QuickScanWidgetEntryView: View {
    let entry: QuickScanWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    private let alipayBlue = Color(red: 0.06, green: 0.46, blue: 0.99)
    private let wechatGreen = Color(red: 0.03, green: 0.74, blue: 0.47)

    private var isFullColor: Bool {
        renderingMode == .fullColor
    }

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                smallLiquidGlassWidget
                    .widgetURL(QuickScanDeepLink.url(action: .scan, source: "widget_small"))
            case .systemMedium:
                mediumLiquidGlassWidget
                    .widgetURL(QuickScanDeepLink.url(action: .scan, source: "widget_medium"))
            case .accessoryCircular:
                circularLockScreenWidget
                    .widgetURL(QuickScanDeepLink.url(action: .scan, source: "lockscreen_circular"))
            case .accessoryRectangular:
                rectangularLockScreenWidget
                    .widgetURL(QuickScanDeepLink.url(action: .scan, source: "lockscreen_rectangular"))
            case .accessoryInline:
                inlineLockScreenWidget
                    .widgetURL(QuickScanDeepLink.url(action: .scan, source: "lockscreen_inline"))
            default:
                smallLiquidGlassWidget
                    .widgetURL(QuickScanDeepLink.url(action: .scan, source: "widget_default"))
            }
        }
        .containerBackground(for: .widget) {
            backgroundForFamily
        }
    }

    // MARK: - 2×2 Small Liquid Glass Widget

    private var smallLiquidGlassWidget: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                liquidGlassMedallion(size: 50, cornerRadius: 15, symbolSize: 23)

                Spacer()

                ZStack {
                    Circle()
                        .fill(innerGlassFill)
                    Circle()
                        .strokeBorder(specularRimGradient, lineWidth: 0.8)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isFullColor ? primaryTextColor.opacity(0.78) : .primary)
                        .widgetAccentable()
                }
                .frame(width: 28, height: 28)
            }

            Spacer(minLength: 8)

            Text("快捷扫码")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(primaryTextColor)
                .widgetAccentable()

            HStack(spacing: 6) {
                glowDot(color: wechatGreen)
                Text("微信")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(secondaryTextColor)

                Text("·")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(secondaryTextColor.opacity(0.6))

                glowDot(color: alipayBlue)
                Text("支付宝")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5.5)
            .background(innerGlassFill, in: Capsule())
            .overlay(Capsule().strokeBorder(specularRimGradient, lineWidth: 0.75))
            .padding(.top, 7)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - 4×2 Medium Liquid Glass Widget

    private var mediumLiquidGlassWidget: some View {
        HStack(spacing: 10) {
            Link(destination: QuickScanDeepLink.url(action: .scan, source: "widget_medium_scan")) {
                VStack(alignment: .leading, spacing: 0) {
                    liquidGlassMedallion(size: 48, cornerRadius: 15, symbolSize: 22)

                    Spacer(minLength: 6)

                    Text("快捷扫码")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(primaryTextColor)
                        .widgetAccentable()

                    Text("自动变焦 · 秒速直跳")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.top, 2)
                }
                .padding(13)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(
                    innerGlassFill,
                    in: ConcentricRectangle(corners: .concentric, isUniform: true)
                )
                .overlay(
                    ConcentricRectangle(corners: .concentric, isUniform: true)
                        .stroke(specularRimGradient, lineWidth: 1.0)
                )
                .clipShape(ConcentricRectangle(corners: .concentric, isUniform: true))
            }

            VStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 8) {
                    routeRow(title: "微信码", subtitle: "跳扫一扫", color: wechatGreen)
                    Divider()
                        .overlay(primaryTextColor.opacity(0.1))
                    routeRow(title: "支付宝", subtitle: "直接打开", color: alipayBlue)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .background(
                    innerGlassFill,
                    in: ConcentricRectangle(corners: .concentric, isUniform: true)
                )
                .overlay(
                    ConcentricRectangle(corners: .concentric, isUniform: true)
                        .stroke(specularRimGradient, lineWidth: 1.0)
                )
                .clipShape(ConcentricRectangle(corners: .concentric, isUniform: true))

                Link(destination: QuickScanDeepLink.url(action: .album, source: "widget_medium_album")) {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 12, weight: .semibold))
                            .widgetAccentable()
                        Text("相册识别")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(secondaryTextColor.opacity(0.75))
                    }
                    .foregroundStyle(primaryTextColor)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(innerGlassFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(specularRimGradient, lineWidth: 0.8))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
    }

    // MARK: - Liquid Glass Visual Components

    private func liquidGlassMedallion(size: CGFloat, cornerRadius: CGFloat, symbolSize: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return ZStack {
            if isFullColor {
                // 底部光学色核
                shape
                    .fill(
                        LinearGradient(
                            colors: [alipayBlue, wechatGreen],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: alipayBlue.opacity(colorScheme == .dark ? 0.45 : 0.30), radius: 10, y: 4)

                // 上半部镜面玻璃光泽层
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.46),
                                .white.opacity(0.08),
                                .clear,
                                .white.opacity(0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // 光学折光边缘高光
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.85), .white.opacity(0.18), .white.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.1
                    )
            } else {
                shape
                    .fill(.quaternary.opacity(0.65))
                shape
                    .strokeBorder(specularRimGradient, lineWidth: 0.9)
            }

            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(isFullColor ? .white : .primary)
                .shadow(color: isFullColor ? .black.opacity(0.18) : .clear, radius: 3, y: 1)
                .widgetAccentable()
        }
        .frame(width: size, height: size)
    }

    private func routeRow(title: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: 7) {
            glowDot(color: color)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(primaryTextColor)

            Spacer(minLength: 0)

            Text(subtitle)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(secondaryTextColor)
        }
    }

    private func glowDot(color: Color) -> some View {
        Circle()
            .fill(isFullColor ? color : .primary)
            .frame(width: 6.5, height: 6.5)
            .shadow(color: isFullColor ? color.opacity(0.75) : .clear, radius: 3.5)
            .widgetAccentable()
    }

    private var primaryTextColor: Color {
        guard isFullColor else { return .primary }
        return colorScheme == .dark ? .white : Color(red: 0.06, green: 0.11, blue: 0.18)
    }

    private var secondaryTextColor: Color {
        guard isFullColor else { return .secondary }
        return colorScheme == .dark ? .white.opacity(0.74) : Color(red: 0.12, green: 0.22, blue: 0.34).opacity(0.72)
    }

    private var innerGlassFill: AnyShapeStyle {
        if !isFullColor {
            return AnyShapeStyle(.white.opacity(0.08))
        }
        if colorScheme == .dark {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [.white.opacity(0.13), .white.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [.white.opacity(0.74), .white.opacity(0.46)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var specularRimGradient: LinearGradient {
        if !isFullColor {
            return LinearGradient(
                colors: [.white.opacity(0.38), .white.opacity(0.05), .white.opacity(0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        if colorScheme == .dark {
            return LinearGradient(
                colors: [.white.opacity(0.36), .white.opacity(0.07), .white.opacity(0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [.white.opacity(0.95), .white.opacity(0.30), .white.opacity(0.70)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Lock Screen Accessory Widgets

    private var circularLockScreenWidget: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 24, weight: .semibold))
                .widgetAccentable()
        }
    }

    private var rectangularLockScreenWidget: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary)
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                    .widgetAccentable()
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("快捷扫码")
                    .font(.headline)
                    .widgetAccentable()
                Text("微信 · 支付宝自动识别")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var inlineLockScreenWidget: some View {
        Label("快捷扫码", systemImage: "qrcode.viewfinder")
    }

    // MARK: - Liquid Glass Adaptive Container Background

    @ViewBuilder
    private var backgroundForFamily: some View {
        switch family {
        case .systemSmall, .systemMedium:
            if isFullColor {
                ZStack {
                    // 深浅色自适应光学玻璃底色
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color(red: 0.04, green: 0.09, blue: 0.18), Color(red: 0.02, green: 0.13, blue: 0.14)]
                            : [Color(red: 0.91, green: 0.96, blue: 1.00), Color(red: 0.89, green: 0.98, blue: 0.96)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    // 左上角蓝绿折光环境辉光
                    RadialGradient(
                        colors: [
                            alipayBlue.opacity(colorScheme == .dark ? 0.34 : 0.16),
                            .clear
                        ],
                        center: .topLeading,
                        startRadius: 8,
                        endRadius: 155
                    )

                    RadialGradient(
                        colors: [
                            wechatGreen.opacity(colorScheme == .dark ? 0.24 : 0.13),
                            .clear
                        ],
                        center: .bottomTrailing,
                        startRadius: 8,
                        endRadius: 150
                    )
                }
            } else {
                // 透明液态玻璃 / 着色模式交由系统原生折射玻璃层渲染
                Color.clear
            }
        default:
            Color.clear
        }
    }
}
