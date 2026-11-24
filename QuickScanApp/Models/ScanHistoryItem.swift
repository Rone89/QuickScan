import Foundation
import Observation

/// 单条本地扫码历史记录
struct ScanHistoryItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let payload: String
    let platform: QRCodePlatform
    let scannedAt: Date

    init(id: UUID = UUID(), payload: String, platform: QRCodePlatform, scannedAt: Date = Date()) {
        self.id = id
        self.payload = payload
        self.platform = platform
        self.scannedAt = scannedAt
    }
}

/// 轻量级扫码历史持久化存储（仅保存在本机 UserDefaults）
@MainActor
@Observable
final class ScanHistoryStore {
    private static let storageKey = "com.quickscan.scanHistory.v1"
    private static let maxItems = 30

    private(set) var items: [ScanHistoryItem] = []

    init() {
        load()
    }

    func record(route: QRCodeRoute) {
        // 避免连续重复写入同一条二维码
        if let first = items.first,
           first.payload == route.rawPayload,
           Date().timeIntervalSince(first.scannedAt) < 5 {
            return
        }

        let item = ScanHistoryItem(payload: route.rawPayload, platform: route.platform)
        items.insert(item, at: 0)
        if items.count > Self.maxItems {
            items = Array(items.prefix(Self.maxItems))
        }
        save()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            guard items.indices.contains(index) else { continue }
            items.remove(at: index)
        }
        save()
    }

    func clearAll() {
        items.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([ScanHistoryItem].self, from: data) else {
            return
        }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
