import SwiftUI

/// 本地最近扫码记录列表（iOS 27 原生风格）
struct ScanHistoryView: View {
    let historyStore: ScanHistoryStore
    let onSelectPayload: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if historyStore.items.isEmpty {
                    ContentUnavailableView(
                        "暂无扫码记录",
                        systemImage: "qrcode.viewfinder",
                        description: Text("扫描微信或支付宝二维码后将自动保留在此处。")
                    )
                } else {
                    List {
                        ForEach(historyStore.items) { item in
                            Button {
                                dismiss()
                                onSelectPayload(item.payload)
                            } label: {
                                HStack(spacing: 12) {
                                    platformBadge(item.platform)

                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(item.platform.displayName)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            Text(item.scannedAt, format: .dateTime.month().day().hour().minute())
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                        Text(item.payload)
                                            .font(.footnote.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            historyStore.delete(at: offsets)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("最近扫码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark") {
                        dismiss()
                    }
                }
                if !historyStore.items.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("清空", role: .destructive) {
                            historyStore.clearAll()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func platformBadge(_ platform: QRCodePlatform) -> some View {
        let color: Color
        let symbol: String
        switch platform {
        case .wechat:
            color = Color(red: 0.03, green: 0.76, blue: 0.38)
            symbol = "message.fill"
        case .alipay:
            color = Color(red: 0.09, green: 0.47, blue: 1.0)
            symbol = "creditcard.fill"
        case .other:
            color = .secondary
            symbol = "qrcode"
        }

        return Image(systemName: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(color.gradient, in: Circle())
    }
}
