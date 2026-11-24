import SwiftUI
import UIKit

/// 扫码结果弹窗：仅在目标 App 未安装或扫描到非微信/支付宝二维码时弹出，采用 iOS 27 原生 Liquid Glass 控件样式
struct ScanResultPresentation: Identifiable, Equatable {
    let id = UUID()
    let route: QRCodeRoute
    let notice: String?
}

struct ScanResultSheetView: View {
    let presentation: ScanResultPresentation
    let onOpenAlipay: (String) -> Void
    let onOpenWeChatScan: () -> Void
    let onOpenWeb: (URL) -> Void
    let onDismiss: () -> Void

    @State private var copied = false

    private let wechatGreen = Color(red: 0.03, green: 0.76, blue: 0.38)
    private let alipayBlue = Color(red: 0.09, green: 0.47, blue: 1.0)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerView

                    if let notice = presentation.notice {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                            Text(notice)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: ConcentricRectangle(corners: .concentric, isUniform: true))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("二维码内容")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)

                        Text(presentation.route.rawPayload)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(.quaternary.opacity(0.5), in: ConcentricRectangle(corners: .concentric, isUniform: true))
                    }

                    VStack(spacing: 12) {
                        if let webURL = presentation.route.webURL {
                            Button {
                                onOpenWeb(webURL)
                            } label: {
                                Label("在 Safari 中打开", systemImage: "safari")
                                    .font(.body.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .tint(.blue)
                            .controlSize(.large)
                        }

                        HStack(spacing: 12) {
                            Button {
                                onOpenAlipay(presentation.route.rawPayload)
                            } label: {
                                Label("支付宝打开", systemImage: "creditcard.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .tint(alipayBlue)
                            .controlSize(.large)

                            Button {
                                onOpenWeChatScan()
                            } label: {
                                Label("微信扫一扫", systemImage: "qrcode.viewfinder")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .tint(wechatGreen)
                            .controlSize(.large)
                        }

                        Button {
                            UIPasteboard.general.string = presentation.route.rawPayload
                            withAnimation(.snappy) { copied = true }
                        } label: {
                            Label(
                                copied ? "已复制" : "复制内容",
                                systemImage: copied ? "checkmark" : "doc.on.doc"
                            )
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                }
                .padding(20)
            }
            .navigationTitle("识别结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onDismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(badgeColor.gradient, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.route.platform.displayName)
                    .font(.headline)
                Text(subtitleText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var iconName: String {
        switch presentation.route.platform {
        case .wechat: return "message.fill"
        case .alipay: return "creditcard.fill"
        case .other: return "qrcode"
        }
    }

    private var badgeColor: Color {
        switch presentation.route.platform {
        case .wechat: return wechatGreen
        case .alipay: return alipayBlue
        case .other: return .blue
        }
    }

    private var subtitleText: String {
        switch presentation.route.platform {
        case .wechat: return "微信二维码"
        case .alipay: return "支付宝二维码"
        case .other: return "可选择使用支付宝、微信或浏览器打开"
        }
    }
}
