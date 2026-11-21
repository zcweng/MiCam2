import AppKit
import Foundation

/// 用预览 JPEG 做廉价动静检测：缩放到小灰度图 + 亮度归一化差分，削弱「只是光线变化」。
final class MotionDetector {
    private let width = 160
    private let height = 90
    private var previous: [Float]?
    private var quietSince: Date?
    private var motionSince: Date?
    private(set) var desiredMode: RecordMode = .motion
    private(set) var lastScore: Double = 0

    func reset(to mode: RecordMode = .motion) {
        previous = nil
        quietSince = nil
        motionSince = nil
        desiredMode = mode
        lastScore = 0
    }

    /// 喂入一帧预览；更新 `desiredMode`（带进出防抖）。
    func ingest(_ image: NSImage, config: RecorderConfig) {
        guard config.idleSparseEnabled else {
            reset(to: .motion)
            return
        }

        guard let frame = grayscaleNormalized(image) else { return }
        defer { previous = frame }

        guard let prev = previous, prev.count == frame.count else {
            // 第一帧：保持当前期望，不立刻判静止
            return
        }

        var sum: Float = 0
        for i in 0..<frame.count {
            sum += abs(frame[i] - prev[i])
        }
        let score = Double(sum) / Double(frame.count)
        lastScore = score

        let now = Date()
        let moving = score > max(config.motionThreshold, 0.001)
        if moving {
            if motionSince == nil { motionSince = now }
            quietSince = nil
            let need = TimeInterval(max(config.motionExitAfterSec, 0))
            if desiredMode != .motion,
               let t = motionSince,
               now.timeIntervalSince(t) >= need {
                desiredMode = .motion
            }
        } else {
            if quietSince == nil { quietSince = now }
            motionSince = nil
            let need = TimeInterval(max(config.idleEnterAfterSec, 1))
            if desiredMode != .idle,
               let t = quietSince,
               now.timeIntervalSince(t) >= need {
                desiredMode = .idle
            }
        }
    }

    // MARK: - 图像

    private func grayscaleNormalized(_ image: NSImage) -> [Float]? {
        let w = width
        let h = height
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: w * 4,
            bitsPerPixel: 32
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            image.draw(in: NSRect(x: 0, y: 0, width: w, height: h),
                       from: .zero,
                       operation: .copy,
                       fraction: 1.0)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return nil }
        var gray = [Float](repeating: 0, count: w * h)
        var mean: Float = 0
        for i in 0..<(w * h) {
            let o = i * 4
            let r = Float(data[o])
            let g = Float(data[o + 1])
            let b = Float(data[o + 2])
            // Rec.709 luma
            let y = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
            gray[i] = y
            mean += y
        }
        mean /= Float(w * h)
        let denom = max(mean, 0.05) // 避免暗场除零放大噪声
        for i in 0..<gray.count {
            gray[i] /= denom
        }
        return gray
    }
}
