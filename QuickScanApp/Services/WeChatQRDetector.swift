import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision

/// 微信开源 SSD 模型检测到的二维码位置与置信度
public struct QRDetectionResult: Equatable, Sendable {
    public let score: Float
    /// 在正方形 `.centerCrop` 区域内的归一化坐标（原点左上角）
    public let cropRect: CGRect
    /// 映射回竖屏完整画面后的归一化坐标（原点左上角）
    public let fullFrameRect: CGRect

    public init(score: Float, cropRect: CGRect, fullFrameRect: CGRect) {
        self.score = score
        self.cropRect = cropRect
        self.fullFrameRect = fullFrameRect
    }

    /// 在正方形取景视野中的主导边长占比（用于计算自动变焦倍率）
    public var dominantSizeInCrop: CGFloat {
        max(cropRect.width, cropRect.height)
    }

    /// 映射到相机传感器坐标系（竖屏后置摄像头 sensorX = portraitY, sensorY = 1 - portraitX）的对焦点
    public var sensorFocusPoint: CGPoint {
        CGPoint(
            x: max(0.05, min(0.95, fullFrameRect.midY)),
            y: max(0.05, min(0.95, 1.0 - fullFrameRect.midX))
        )
    }
}

/// 封装转换后的微信开源 `WeChatQRDetector.mlmodel`（957 KB，Apple Neural Engine 加速）
public final class WeChatQRSSDDetector: @unchecked Sendable {
    private struct HeadSpec {
        let clsKey: String
        let locKey: String
        let step: Float
        let priorSizes: [(Float, Float)]

        init(clsKey: String, locKey: String, minSize: Float, maxSize: Float, step: Float) {
            self.clsKey = clsKey
            self.locKey = locKey
            self.step = step

            var sizes: [(Float, Float)] = [
                (minSize / 384.0, minSize / 384.0),
                (sqrt(minSize * maxSize) / 384.0, sqrt(minSize * maxSize) / 384.0)
            ]
            let aspectRatios: [Float] = [2.0, 0.5, 3.0, 0.33333334]
            for ar in aspectRatios {
                let root = sqrt(ar)
                sizes.append((minSize * root / 384.0, minSize / root / 384.0))
            }
            self.priorSizes = sizes
        }
    }

    private static let heads: [HeadSpec] = [
        HeadSpec(clsKey: "cls1", locKey: "loc1", minSize: 50,  maxSize: 100, step: 16),
        HeadSpec(clsKey: "cls2", locKey: "loc2", minSize: 100, maxSize: 150, step: 32),
        HeadSpec(clsKey: "cls3", locKey: "loc3", minSize: 150, maxSize: 200, step: 32),
        HeadSpec(clsKey: "cls4", locKey: "loc4", minSize: 200, maxSize: 300, step: 32),
        HeadSpec(clsKey: "cls5", locKey: "loc5", minSize: 300, maxSize: 400, step: 32)
    ]

    private let visionModel: VNCoreMLModel

    public init?(bundle: Bundle = .main) {
        guard let modelURL = bundle.url(forResource: "WeChatQRDetector", withExtension: "mlmodelc") else {
            return nil
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all

        guard let mlModel = try? MLModel(contentsOf: modelURL, configuration: config),
              let vnModel = try? VNCoreMLModel(for: mlModel) else {
            return nil
        }
        self.visionModel = vnModel
    }

    /// 对实时相机视频帧执行远距离二维码检测（自动按竖屏 `.right` 方向中心裁剪，避免拉伸畸变）
    public func detect(in pixelBuffer: CVPixelBuffer, minimumScore: Float = 0.26) -> QRDetectionResult? {
        let sensorWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let sensorHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        // 后置竖屏下，原始传感器缓冲为横屏（宽 > 高），旋转 .right 后竖屏宽 = sensorHeight、高 = sensorWidth
        let portraitWidth = min(sensorWidth, sensorHeight)
        let portraitHeight = max(sensorWidth, sensorHeight)

        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        return decodeBestDetection(
            from: request.results as? [VNCoreMLFeatureValueObservation],
            portraitWidth: portraitWidth,
            portraitHeight: portraitHeight,
            minimumScore: minimumScore
        )
    }

    /// 对静态 `CGImage` 执行检测（用于单元测试与图片验证）
    public func detect(in cgImage: CGImage, minimumScore: Float = 0.26) -> QRDetectionResult? {
        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        return decodeBestDetection(
            from: request.results as? [VNCoreMLFeatureValueObservation],
            portraitWidth: CGFloat(cgImage.width),
            portraitHeight: CGFloat(cgImage.height),
            minimumScore: minimumScore
        )
    }

    // MARK: - SSD PriorBox Decode

    private func decodeBestDetection(
        from observations: [VNCoreMLFeatureValueObservation]?,
        portraitWidth: CGFloat,
        portraitHeight: CGFloat,
        minimumScore: Float
    ) -> QRDetectionResult? {
        guard let observations, !observations.isEmpty else {
            return nil
        }

        var arrays: [String: MLMultiArray] = [:]
        arrays.reserveCapacity(10)
        for obs in observations {
            if let multiArray = obs.featureValue.multiArrayValue {
                arrays[obs.featureName] = multiArray
            }
        }

        var bestScore: Float = minimumScore
        var bestCropRect: CGRect?

        for head in Self.heads {
            guard let clsArr = arrays[head.clsKey],
                  let locArr = arrays[head.locKey],
                  clsArr.shape.count >= 3,
                  locArr.shape.count >= 3 else {
                continue
            }

            let fh = clsArr.shape[clsArr.shape.count - 2].intValue
            let fw = clsArr.shape[clsArr.shape.count - 1].intValue

            let clsS0 = clsArr.strides[clsArr.strides.count - 3].intValue
            let clsS1 = clsArr.strides[clsArr.strides.count - 2].intValue
            let clsS2 = clsArr.strides[clsArr.strides.count - 1].intValue

            let locS0 = locArr.strides[locArr.strides.count - 3].intValue
            let locS1 = locArr.strides[locArr.strides.count - 2].intValue
            let locS2 = locArr.strides[locArr.strides.count - 1].intValue

            let clsPtr = clsArr.dataPointer.assumingMemoryBound(to: Float.self)
            let locPtr = locArr.dataPointer.assumingMemoryBound(to: Float.self)

            for y in 0..<fh {
                let cy = (Float(y) + 0.5) * head.step / 384.0
                let clsRowBase = y * clsS1
                let locRowBase = y * locS1

                for x in 0..<fw {
                    let cx = (Float(x) + 0.5) * head.step / 384.0
                    let clsCellBase = clsRowBase + x * clsS2
                    let locCellBase = locRowBase + x * locS2

                    for a in 0..<6 {
                        let bg = clsPtr[(a * 2) * clsS0 + clsCellBase]
                        let fg = clsPtr[(a * 2 + 1) * clsS0 + clsCellBase]
                        let diff = bg - fg
                        // 快速剪枝：softmax 概率小于当前 bestScore 时直接跳过 exp 计算
                        if diff > 1.2 && bestScore > 0.25 {
                            continue
                        }
                        let score = 1.0 / (1.0 + exp(diff))
                        guard score > bestScore else { continue }

                        let dx = locPtr[(a * 4 + 0) * locS0 + locCellBase]
                        let dy = locPtr[(a * 4 + 1) * locS0 + locCellBase]
                        let dw = locPtr[(a * 4 + 2) * locS0 + locCellBase]
                        let dh = locPtr[(a * 4 + 3) * locS0 + locCellBase]

                        let (pw, ph) = head.priorSizes[a]
                        let dcx = cx + dx * 0.1 * pw
                        let dcy = cy + dy * 0.1 * ph
                        let ddw = pw * exp(dw * 0.2)
                        let ddh = ph * exp(dh * 0.2)

                        let x0 = max(0.0, min(1.0, dcx - ddw * 0.5))
                        let y0 = max(0.0, min(1.0, dcy - ddh * 0.5))
                        let x1 = max(0.0, min(1.0, dcx + ddw * 0.5))
                        let y1 = max(0.0, min(1.0, dcy + ddh * 0.5))

                        let w = x1 - x0
                        let h = y1 - y0
                        guard w > 0.015, h > 0.015 else { continue }

                        bestScore = score
                        bestCropRect = CGRect(
                            x: CGFloat(x0),
                            y: CGFloat(y0),
                            width: CGFloat(w),
                            height: CGFloat(h)
                        )
                    }
                }
            }
        }

        guard let cropRect = bestCropRect else {
            return nil
        }

        let fullRect = mapCenterCropRectToFullFrame(
            cropRect,
            imageWidth: portraitWidth,
            imageHeight: portraitHeight
        )
        return QRDetectionResult(score: bestScore, cropRect: cropRect, fullFrameRect: fullRect)
    }

    private func mapCenterCropRectToFullFrame(
        _ cropRect: CGRect,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return cropRect }

        if imageHeight >= imageWidth {
            let cropFractionY = imageWidth / imageHeight
            let offsetY = (1.0 - cropFractionY) * 0.5
            return CGRect(
                x: cropRect.minX,
                y: offsetY + cropRect.minY * cropFractionY,
                width: cropRect.width,
                height: cropRect.height * cropFractionY
            )
        } else {
            let cropFractionX = imageHeight / imageWidth
            let offsetX = (1.0 - cropFractionX) * 0.5
            return CGRect(
                x: offsetX + cropRect.minX * cropFractionX,
                y: cropRect.minY,
                width: cropRect.width * cropFractionX,
                height: cropRect.height
            )
        }
    }
}
