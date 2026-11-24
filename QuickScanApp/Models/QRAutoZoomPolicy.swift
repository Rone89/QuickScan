import CoreGraphics
import Foundation

/// 自动变焦决策输出
public enum QRAutoZoomDecision: Equatable, Sendable {
    case none
    case focusOnly(sensorFocusPoint: CGPoint)
    case focusAndZoom(targetDisplayZoom: CGFloat, sensorFocusPoint: CGPoint)
    case resetZoom
}

/// 远距离二维码自动变焦防抖策略状态机（纯 Swift，无硬件副作用，便于单元测试）
public struct QRAutoZoomPolicy: Sendable {
    /// 高置信度单帧直接确认阈值
    public let highConfidenceThreshold: Float = 0.58
    /// 中低置信度需连续两帧空间一致确认阈值
    public let mediumConfidenceThreshold: Float = 0.28
    /// 当二维码主导边长小于正方形取景视野该比例时触发放大
    public let zoomTriggerSizeThreshold: CGFloat = 0.27
    /// 目标放大后二维码在正方形视野中的理想占比
    public let desiredSizeInCrop: CGFloat = 0.38
    /// 单次平滑推近的最大倍率跨度（过大则分两步推近，避免画面突兀跳变）
    public let maxSingleStepMultiplier: CGFloat = 2.35
    /// 触发变焦的最小有效增量
    public let minimumZoomDelta: CGFloat = 0.22
    /// 连续两次自动变焦之间的冷却间隔（等待镜头平滑推进与对焦稳定）
    public let zoomStepCooldown: TimeInterval = 0.42
    /// 画面中二维码消失后自动回退 1× 的等待时长
    public let autoResetDelay: TimeInterval = 2.6
    /// 用户手动缩放后暂停自动变焦的礼让时长
    public let manualOverrideDuration: TimeInterval = 4.0

    private var pendingCandidateCenter: CGPoint?
    private var pendingCandidateDate: Date = .distantPast
    private var lastConfirmedDetectionDate: Date = .distantPast
    private var lastZoomActionDate: Date = .distantPast
    private var manualOverrideUntil: Date = .distantPast
    private(set) var isAutoZoomActive: Bool = false

    public init() {}

    public mutating func reset() {
        pendingCandidateCenter = nil
        pendingCandidateDate = .distantPast
        lastConfirmedDetectionDate = .distantPast
        lastZoomActionDate = .distantPast
        manualOverrideUntil = .distantPast
        isAutoZoomActive = false
    }

    public mutating func registerManualZoom(at now: Date = Date()) {
        manualOverrideUntil = now.addingTimeInterval(manualOverrideDuration)
        isAutoZoomActive = false
        pendingCandidateCenter = nil
    }

    public mutating func evaluate(
        detection: QRDetectionResult?,
        currentDisplayZoom: CGFloat,
        maxAutoDisplayZoom: CGFloat,
        now: Date = Date()
    ) -> QRAutoZoomDecision {
        // 尊重用户手动变焦手势
        if now < manualOverrideUntil {
            return .none
        }

        guard let detection, detection.score >= mediumConfidenceThreshold else {
            pendingCandidateCenter = nil
            // 若此前由自动变焦推近，且二维码离开画面超过 autoResetDelay，则平滑回到 1×
            if isAutoZoomActive,
               currentDisplayZoom > 1.08,
               now.timeIntervalSince(lastConfirmedDetectionDate) >= autoResetDelay {
                isAutoZoomActive = false
                return .resetZoom
            }
            return .none
        }

        // 防抖确认：高置信度直接确认，中低置信度要求连续两帧位置一致
        let confirmed: Bool
        if detection.score >= highConfidenceThreshold {
            confirmed = true
        } else if let prevCenter = pendingCandidateCenter,
                  now.timeIntervalSince(pendingCandidateDate) <= 0.55 {
            let dx = detection.cropRect.midX - prevCenter.x
            let dy = detection.cropRect.midY - prevCenter.y
            confirmed = hypot(dx, dy) <= 0.14
        } else {
            confirmed = false
        }

        pendingCandidateCenter = CGPoint(x: detection.cropRect.midX, y: detection.cropRect.midY)
        pendingCandidateDate = now

        guard confirmed else {
            return .none
        }

        lastConfirmedDetectionDate = now
        let focusPoint = detection.sensorFocusPoint

        // 二维码已足够清晰/较大，仅锁定对焦即可
        let size = detection.dominantSizeInCrop
        guard size < zoomTriggerSizeThreshold else {
            return .focusOnly(sensorFocusPoint: focusPoint)
        }

        // 冷却期内只微调对焦，不重复打断当前变焦斜坡
        guard now.timeIntervalSince(lastZoomActionDate) >= zoomStepCooldown else {
            return .focusOnly(sensorFocusPoint: focusPoint)
        }

        let safeMax = max(1.0, maxAutoDisplayZoom)
        guard currentDisplayZoom < safeMax - 0.08 else {
            return .focusOnly(sensorFocusPoint: focusPoint)
        }

        let rawScale = desiredSizeInCrop / max(size, 0.045)
        let stepMultiplier = min(max(rawScale, 1.0), maxSingleStepMultiplier)
        let targetZoom = min(safeMax, currentDisplayZoom * stepMultiplier)

        guard targetZoom - currentDisplayZoom >= minimumZoomDelta else {
            return .focusOnly(sensorFocusPoint: focusPoint)
        }

        lastZoomActionDate = now
        isAutoZoomActive = true
        return .focusAndZoom(targetDisplayZoom: targetZoom, sensorFocusPoint: focusPoint)
    }
}
