import ARKit
import SwiftUI
import simd

/// Ручной промер: навёл перекрестие на один косяк, отметил, навёл на другой —
/// получил расстояние.
///
/// Нужен потому, что автоматика берёт не всё. Закрытая дверь геометрически
/// почти не отличается от стены: полотно стоит в той же плоскости, и в меше
/// на её месте не дыра, а ровная поверхность. Балку за шкафом, проём,
/// загороженный мебелью, скос откоса — всё это меряет человек, а не солвер.
///
/// Точка берётся из карты глубины напрямую, без меша: это ближе всего
/// к тому, что реально измерил лидар.
struct MeasureScreen: View {

    @ObservedObject var mesh: MeshCapture
    let onClose: () -> Void

    @State private var first: SIMD3<Float>?
    @State private var result: Int?
    @State private var liveDistance: Float?
    @State private var failure: String?
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            CameraLayer(session: mesh.session).ignoresSafeArea()

            crosshair

            VStack {
                hint
                Spacer()
                panel
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .onAppear {
            mesh.resume()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                liveDistance = DepthProbe.distance(in: mesh.session)
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private var crosshair: some View {
        ZStack {
            Circle()
                .stroke(first == nil ? Color.white : Color.green, lineWidth: 2)
                .frame(width: 26, height: 26)
            Circle()
                .fill(first == nil ? Color.white : Color.green)
                .frame(width: 4, height: 4)
        }
        .shadow(radius: 3)
    }

    private var hint: some View {
        Text(first == nil
             ? "Наведите перекрестие на первую точку"
             : "Теперь на вторую — расстояние посчитается между ними")
            .font(.footnote)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(12)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var panel: some View {
        VStack(spacing: 14) {
            if let result {
                Text("\(result) мм")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
            } else if let liveDistance {
                Text("до поверхности \(Int((liveDistance * 1000).rounded())) мм")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
            }

            if let failure {
                Text(verbatim: failure)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button("Закрыть") { onClose() }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 52)
                    .background(.black.opacity(0.45), in: Capsule())

                Button(first == nil ? "Первая точка" : "Вторая точка") { mark() }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .buttonStyle(.borderedProminent)

                if first != nil || result != nil {
                    Button("Сброс") {
                        first = nil; result = nil; failure = nil
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .background(.black.opacity(0.45), in: Capsule())
                }
            }
        }
    }

    private func mark() {
        guard let point = DepthProbe.point(in: mesh.session) else {
            failure = String(localized: "Не удалось замерить: наведите на поверхность в 0,5–4 м и держите телефон неподвижно.")
            return
        }
        failure = nil
        if let start = first {
            result = Int((simd_distance(start, point) * 1000).rounded())
            first = nil
        } else {
            first = point
            result = nil
        }
    }
}

/// Замер по центру кадра прямо из карты глубины лидара.
enum DepthProbe {

    /// Точка под перекрестием в мировых координатах.
    static func point(in session: ARSession) -> SIMD3<Float>? {
        guard let frame = session.currentFrame,
              let depth = frame.sceneDepth,
              let metres = sample(depth) else { return nil }

        let map = depth.depthMap
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)

        // Матрица камеры посчитана для полного кадра, а глубина приходит
        // уменьшенной — коэффициенты надо пересчитать под её размер.
        let resolution = frame.camera.imageResolution
        let scaleX = Float(width) / Float(resolution.width)
        let scaleY = Float(height) / Float(resolution.height)
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics[0][0] * scaleX
        let fy = intrinsics[1][1] * scaleY
        let cx = intrinsics[2][0] * scaleX
        let cy = intrinsics[2][1] * scaleY

        let u = Float(width) / 2
        let v = Float(height) / 2

        // Камера в ARKit смотрит вдоль −Z, а строки кадра идут сверху вниз.
        let camera = SIMD4<Float>((u - cx) * metres / fx,
                                  -(v - cy) * metres / fy,
                                  -metres,
                                  1)
        let world = frame.camera.transform * camera
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    /// Расстояние до поверхности под перекрестием — для живой подсказки.
    static func distance(in session: ARSession) -> Float? {
        guard let depth = session.currentFrame?.sceneDepth else { return nil }
        return sample(depth)
    }

    /// Медиана по окну вокруг центра: одиночный пиксель глубины шумит,
    /// а на краях предметов ещё и «улетает» между ближним и дальним планом.
    private static func sample(_ depth: ARDepthData) -> Float? {
        let map = depth.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let stride = CVPixelBufferGetBytesPerRow(map)

        var confidence: UnsafeMutableRawPointer?
        var confidenceStride = 0
        if let confidenceMap = depth.confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            confidence = CVPixelBufferGetBaseAddress(confidenceMap)
            confidenceStride = CVPixelBufferGetBytesPerRow(confidenceMap)
        }
        defer {
            if let confidenceMap = depth.confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
        }

        var values: [Float] = []
        let radius = 3
        for dy in -radius...radius {
            for dx in -radius...radius {
                let x = width / 2 + dx
                let y = height / 2 + dy
                guard x >= 0, x < width, y >= 0, y < height else { continue }

                if let confidence {
                    let level = confidence.advanced(by: y * confidenceStride + x)
                        .assumingMemoryBound(to: UInt8.self).pointee
                    guard level >= ARConfidenceLevel.medium.rawValue else { continue }
                }

                let value = base.advanced(by: y * stride + x * MemoryLayout<Float32>.size)
                    .assumingMemoryBound(to: Float32.self).pointee
                if value > 0.05, value < 6 { values.append(value) }
            }
        }

        guard values.count >= 8 else { return nil }
        values.sort()
        return values[values.count / 2]
    }
}

private struct CameraLayer: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = true
        return view
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
