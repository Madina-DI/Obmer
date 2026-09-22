import ARKit
import SwiftUI
import simd

/// Замер по застывшему кадру.
///
/// Живой прицел заставляет поворачивать телефон между первой и второй точкой,
/// а за это время ARKit успевает уточнить своё положение в пространстве —
/// отсюда и разброс, который растёт с каждым замером. Здесь обе точки берутся
/// из одного кадра: телефон в этот момент был в одном положении, пересчитывать
/// нечего, и дрейфу взяться неоткуда.
struct FrozenMeasure {

    let image: UIImage
    let depth: CVPixelBuffer
    let confidence: CVPixelBuffer?
    let cameraTransform: simd_float4x4
    let intrinsics: simd_float3x3
    let imageSize: CGSize

    /// Снимок текущего кадра вместе с глубиной.
    static func capture(from session: ARSession) -> FrozenMeasure? {
        guard let frame = session.currentFrame, let scene = frame.sceneDepth else { return nil }

        let pixels = frame.capturedImage
        let size = CGSize(width: CVPixelBufferGetWidth(pixels),
                          height: CVPixelBufferGetHeight(pixels))

        // Кадр с камеры лежит горизонтально независимо от того, как держат
        // телефон, поэтому для вертикального экрана его поворачиваем.
        let ci = CIImage(cvPixelBuffer: pixels).oriented(.right)
        let context = CIContext()
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }

        return FrozenMeasure(
            image: UIImage(cgImage: cg),
            depth: copy(scene.depthMap),
            confidence: scene.confidenceMap.map(copy),
            cameraTransform: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            imageSize: size
        )
    }

    /// Точка кадра в мировых координатах.
    /// `spot` — доля от размера повёрнутого изображения, от левого верхнего угла.
    func world(at spot: CGPoint) -> (point: SIMD3<Float>, spread: Float)? {
        // Обратный поворот: из повёрнутого кадра обратно в исходный.
        let rotatedX = spot.x * imageSize.height
        let rotatedY = spot.y * imageSize.width
        let originalX = rotatedY
        let originalY = imageSize.height - rotatedX
        guard originalX >= 0, originalX < imageSize.width,
              originalY >= 0, originalY < imageSize.height else { return nil }

        let depthWidth = CVPixelBufferGetWidth(depth)
        let depthHeight = CVPixelBufferGetHeight(depth)
        let dx = Int(originalX / imageSize.width * CGFloat(depthWidth))
        let dy = Int(originalY / imageSize.height * CGFloat(depthHeight))

        // Глубина груба: 256×192, с двух метров одна точка — около сантиметра.
        // Поэтому не берём её в лоб, а строим по окрестности плоскость и пускаем
        // луч через ровно ту точку снимка, куда ткнули. Направление луча задаёт
        // картинка в 1920 точек, то есть в семь раз подробнее глубины.
        guard let plane = fitPlane(around: dx, dy) else { return nil }

        let fx = intrinsics[0][0], fy = intrinsics[1][1]
        let cx = intrinsics[2][0], cy = intrinsics[2][1]
        let ray = simd_normalize(SIMD3<Float>(Float(originalX - CGFloat(cx)) / fx,
                                              -Float(originalY - CGFloat(cy)) / fy,
                                              -1))
        let denominator = simd_dot(plane.normal, ray)
        guard abs(denominator) > 0.15 else { return nil }
        let distance = plane.offset / denominator
        guard distance > 0.05, distance < 6 else { return nil }

        let camera = SIMD4<Float>(ray.x * distance, ray.y * distance, ray.z * distance, 1)
        let world = cameraTransform * camera
        return (SIMD3<Float>(world.x, world.y, world.z), plane.residual)
    }

    /// Плоскость поверхности вокруг точки, в координатах камеры.
    /// Выбросы отбрасываются: у ребра в окно попадают сразу две поверхности,
    /// и без отсева плоскость встанет между ними.
    private func fitPlane(around x: Int, _ y: Int) -> (normal: SIMD3<Float>, offset: Float, residual: Float)? {
        guard let cloud = neighbourhood(around: x, y), cloud.count >= 25 else { return nil }

        var points = cloud
        var normal = SIMD3<Float>(0, 0, 1)
        var offset: Float = 0
        var residual: Float = 0

        for _ in 0..<3 {
            var centroid = SIMD3<Float>(repeating: 0)
            for point in points { centroid += point }
            centroid /= Float(points.count)

            // Нормаль — наименьшая ось разброса, через ковариацию.
            var xx: Float = 0, xy: Float = 0, xz: Float = 0, yy: Float = 0, yz: Float = 0, zz: Float = 0
            for point in points {
                let d = point - centroid
                xx += d.x * d.x; xy += d.x * d.y; xz += d.x * d.z
                yy += d.y * d.y; yz += d.y * d.z; zz += d.z * d.z
            }
            let a = SIMD3<Float>(yy * zz - yz * yz, xz * yz - xy * zz, xy * yz - xz * yy)
            let b = SIMD3<Float>(xz * yz - xy * zz, xx * zz - xz * xz, xy * xz - yz * xx)
            let c = SIMD3<Float>(xy * yz - xz * yy, xy * xz - yz * xx, xx * yy - xy * xy)
            let best = [a, b, c].max { simd_length($0) < simd_length($1) } ?? a
            guard simd_length(best) > 1e-9 else { return nil }
            normal = simd_normalize(best)
            offset = simd_dot(normal, centroid)

            let deviations = points.map { abs(simd_dot(normal, $0) - offset) }
            let sorted = deviations.sorted()
            residual = sorted[Int(Float(sorted.count - 1) * 0.9)]
            let cut = max(0.012, residual)
            let kept = zip(points, deviations).filter { $0.1 <= cut }.map(\.0)
            if kept.count < 25 { break }
            if kept.count == points.count { break }
            points = kept
        }

        return (normal, offset, residual)
    }

    /// Точки глубины вокруг пикселя, в координатах камеры.
    private func neighbourhood(around x: Int, _ y: Int) -> [SIMD3<Float>]? {
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }

        let width = CVPixelBufferGetWidth(depth)
        let height = CVPixelBufferGetHeight(depth)
        let stride = CVPixelBufferGetBytesPerRow(depth)
        let scaleX = Float(width) / Float(imageSize.width)
        let scaleY = Float(height) / Float(imageSize.height)
        let fx = intrinsics[0][0] * scaleX, fy = intrinsics[1][1] * scaleY
        let cx = intrinsics[2][0] * scaleX, cy = intrinsics[2][1] * scaleY

        var confidenceBase: UnsafeMutableRawPointer?
        var confidenceStride = 0
        if let confidence {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            confidenceBase = CVPixelBufferGetBaseAddress(confidence)
            confidenceStride = CVPixelBufferGetBytesPerRow(confidence)
        }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }

        var cloud: [SIMD3<Float>] = []
        let radius = 6
        for dy in -radius...radius {
            for dx in -radius...radius {
                let px = x + dx, py = y + dy
                guard px >= 0, px < width, py >= 0, py < height else { continue }
                if let confidenceBase {
                    let level = confidenceBase.advanced(by: py * confidenceStride + px)
                        .assumingMemoryBound(to: UInt8.self).pointee
                    guard level >= ARConfidenceLevel.medium.rawValue else { continue }
                }
                let value = base.advanced(by: py * stride + px * MemoryLayout<Float32>.size)
                    .assumingMemoryBound(to: Float32.self).pointee
                guard value > 0.05, value < 6 else { continue }
                cloud.append(SIMD3<Float>((Float(px) - cx) * value / fx,
                                          -(Float(py) - cy) * value / fy,
                                          -value))
            }
        }
        return cloud
    }

    private func sample(around x: Int, _ y: Int) -> (median: Float, spread: Float)? {
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }

        let width = CVPixelBufferGetWidth(depth)
        let height = CVPixelBufferGetHeight(depth)
        let stride = CVPixelBufferGetBytesPerRow(depth)

        var confidenceBase: UnsafeMutableRawPointer?
        var confidenceStride = 0
        if let confidence {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            confidenceBase = CVPixelBufferGetBaseAddress(confidence)
            confidenceStride = CVPixelBufferGetBytesPerRow(confidence)
        }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }

        var values: [Float] = []
        for dy in -2...2 {
            for dx in -2...2 {
                let px = x + dx, py = y + dy
                guard px >= 0, px < width, py >= 0, py < height else { continue }
                if let confidenceBase {
                    let level = confidenceBase.advanced(by: py * confidenceStride + px)
                        .assumingMemoryBound(to: UInt8.self).pointee
                    guard level >= ARConfidenceLevel.medium.rawValue else { continue }
                }
                let value = base.advanced(by: py * stride + px * MemoryLayout<Float32>.size)
                    .assumingMemoryBound(to: Float32.self).pointee
                if value > 0.05, value < 6 { values.append(value) }
            }
        }
        guard values.count >= 6 else { return nil }
        values.sort()
        let low = values[Int(Float(values.count - 1) * 0.1)]
        let high = values[Int(Float(values.count - 1) * 0.9)]
        return (values[values.count / 2], high - low)
    }

    /// Буферы кадра ARKit переиспользует, поэтому глубину копируем себе.
    private static func copy(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)

        var copy: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format, nil, &copy)
        guard let copy else { return buffer }

        CVPixelBufferLockBaseAddress(copy, [])
        if let from = CVPixelBufferGetBaseAddress(buffer),
           let to = CVPixelBufferGetBaseAddress(copy) {
            memcpy(to, from, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(copy, [])
        return copy
    }
}
