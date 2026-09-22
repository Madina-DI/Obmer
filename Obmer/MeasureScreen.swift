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
/// Что именно уточняем. nil — свободный промер, просто расстояние.
struct MeasureTarget: Identifiable {
    var id: String { "\(element)-\(kind.rawValue)" }
    let element: UUID
    let kind: Correction.Kind
    let title: String
}

struct MeasureScreen: View {

    @ObservedObject var mesh: MeshCapture
    var target: MeasureTarget? = nil
    let onClose: () -> Void

    @State private var first: SIMD3<Float>?
    @State private var result: Int?
    /// Последние замеры остаются на экране: обычно меряют подряд несколько
    /// размеров одного проёма и сравнивают их между собой.
    @State private var history: [Int] = []
    @State private var liveDistance: Float?
    @State private var onEdge = false
    @State private var failure: String?
    @State private var timer: Timer?
    @State private var frozen: FrozenMeasure?
    @State private var isSampling = false
    @State private var progress: Double = 0

    var body: some View {
        ZStack {
            if let frozen {
                FrozenMeasureView(frozen: frozen, target: target,
                                  onRetake: { self.frozen = nil },
                                  onClose: onClose)
                    .ignoresSafeArea()
            } else {
                liveView
            }
        }
    }

    private var liveView: some View {
        ZStack {
            CameraLayer(session: mesh.session).ignoresSafeArea()

            crosshair

            VStack {
                if let target {
                    Text("Уточняем: \(target.title)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(.bottom, 6)
                }
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
                let reading = DepthProbe.reading(in: mesh.session)
                liveDistance = reading?.median
                onEdge = (reading?.spread ?? 0) > DepthProbe.edgeSpread
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private var crosshair: some View {
        VStack(spacing: 10) {
            crosshairMark
            Text(canMeasure ? "можно замерять" : "не видно ровной поверхности")
                .font(.caption2.weight(.medium))
                .foregroundStyle(canMeasure ? Color.green : Color.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.5), in: Capsule())
        }
    }

    private var crosshairMark: some View {
        ZStack {
            Circle()
                .stroke(crosshairColour, lineWidth: 2)
                .frame(width: 26, height: 26)
            Circle()
                .fill(crosshairColour)
                .frame(width: 4, height: 4)
        }
        .shadow(radius: 3)
    }

    private var hint: some View {
        Text(hintText)
            .font(.footnote)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(12)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    /// У прицела ровно один смысл: можно ли сейчас брать замер.
    /// Раньше цвет означал заодно и «поставлена ли первая точка» —
    /// два смысла в одном цвете читаются как случайные мигания.
    private var canMeasure: Bool { liveDistance != nil && !onEdge }
    private var crosshairColour: Color { canMeasure ? .green : .red }

    private var hintText: LocalizedStringKey {
        if first != nil { return "Первая точка стоит. Наведите на вторую и нажмите прицел" }
        if result != nil { return "Готово" }
        return "Наведите на то, что меряете, и нажмите «Снять кадр» — точки поставите пальцем на снимке"
    }

    private var buttonTitle: LocalizedStringKey {
        if first != nil { return "Вторая точка" }
        if result != nil { return "Новый замер" }
        return "Первая точка"
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
            } else if let liveDistance, !onEdge {
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

            // Ради этой кнопки промер и отличается от обычной рулетки:
            // число не остаётся в воздухе, а встаёт в обмер вместо неверного.
            if let target, let result {
                Button {
                    CorrectionStore.shared.set(result, for: target.element, target.kind)
                    onClose()
                } label: {
                    Label("Записать в обмер", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }

            if first != nil {
                Label("Первая точка поставлена", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
            }

            if !history.isEmpty {
                HStack(spacing: 8) {
                    Text("до этого:")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    ForEach(history.prefix(4), id: \.self) { value in
                        Text("\(value)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.45), in: Capsule())
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Закрыть") { onClose() }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 52)
                    .background(.black.opacity(0.45), in: Capsule())

                // Прицел оставлен на случай, когда обе точки в один кадр
                // не помещаются: длинная стена, замер через всё помещение.
                Button { mark() } label: {
                    Image(systemName: isSampling ? "waveform" : "scope")
                        .font(.headline)
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(isSampling)

                // Снимок — основной способ: на контрольном промежутке он дал
                // разброс 5 мм против 121 мм у живого прицела.
                Button {
                    frozen = FrozenMeasure.capture(from: mesh.session)
                    if frozen == nil {
                        failure = String(localized: "Кадр не снялся: подождите, пока камера наведётся.")
                    }
                } label: {
                    Label("Снять кадр", systemImage: "camera.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.borderedProminent)

                // Отменить имеет смысл только пока первая точка уже стоит,
                // а вторая ещё нет: в остальных случаях отменять нечего.
                if first != nil {
                    Button("Отменить") { first = nil; failure = nil }
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
        // «Новый замер» только убирает прошлый результат. Раньше он заодно
        // ставил первую точку — в тот момент, куда телефон случайно смотрел,
        // и следующий замер считался от случайного места.
        if first == nil, let previous = result {
            history.insert(previous, at: 0)
            result = nil
            failure = nil
            return
        }
        guard !isSampling else { return }
        collect()
    }

    /// Точка считается не по одному кадру, а по серии за полсекунды.
    /// Один кадр даёт разброс порядка 6 мм, серия — порядка 2 мм: случайный
    /// шум глубины усредняется. То же самое делал человек, нажимая трижды,
    /// только теперь это внутри одного нажатия.
    private func collect() {
        isSampling = true
        progress = 0
        failure = nil

        var points: [SIMD3<Float>] = []
        var origin: SIMD3<Float>?
        let deadline = Date().addingTimeInterval(0.9)

        Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { sampler in
            guard let frame = mesh.session.currentFrame else { return }
            let camera = frame.camera.transform.columns.3
            let here = SIMD3<Float>(camera.x, camera.y, camera.z)

            // Телефон увели в сторону — серия уже не про одну точку.
            if let origin, simd_distance(origin, here) > 0.03 {
                sampler.invalidate()
                finish(points, moved: true)
                return
            }
            if origin == nil { origin = here }

            if let point = DepthProbe.point(in: mesh.session) { points.append(point) }
            progress = min(1, Double(points.count) / 12)

            if points.count >= 12 || Date() > deadline {
                sampler.invalidate()
                finish(points, moved: false)
            }
        }
    }

    private func finish(_ points: [SIMD3<Float>], moved: Bool) {
        isSampling = false
        progress = 0

        guard points.count >= 6 else {
            failure = moved
                ? String(localized: "Телефон сдвинулся во время замера. Держите его неподвижно и нажмите ещё раз.")
                : String(localized: "Замер не взят: прицел на ребре или поверхность не видна. Сместитесь на ровное место рядом, в 0,5–4 м.")
            return
        }

        // Медиана покоординатно: устойчивее среднего, одиночный выброс её не тянет.
        let point = SIMD3<Float>(median(points.map(\.x)),
                                 median(points.map(\.y)),
                                 median(points.map(\.z)))

        if let start = first {
            result = Int((simd_distance(start, point) * 1000).rounded())
            first = nil
            if let value = result { MeasurementLog.record(value) }
        } else {
            first = point
            result = nil
        }
    }

    private func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// Замер по центру кадра прямо из карты глубины лидара.
enum DepthProbe {

    /// Насколько по-разному считалась глубина внутри окна замера.
    /// На ровной поверхности это единицы миллиметров, а на ребре окно
    /// накрывает сразу ближний и дальний план, и разброс взлетает.
    static let edgeSpread: Float = 0.04

    /// Точка под перекрестием в мировых координатах.
    /// nil, если прицел стоит на ребре: такой замер выглядит нормальным,
    /// а врёт на сотню миллиметров — лучше не отдавать его вовсе.
    static func point(in session: ARSession) -> SIMD3<Float>? {
        guard let frame = session.currentFrame,
              let depth = frame.sceneDepth,
              let reading = sample(depth),
              reading.spread <= edgeSpread else { return nil }
        let metres = reading.median

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

    /// Расстояние до поверхности и разброс — для живой подсказки.
    static func reading(in session: ARSession) -> (median: Float, spread: Float)? {
        guard let depth = session.currentFrame?.sceneDepth else { return nil }
        return sample(depth)
    }

    /// Медиана по окну вокруг центра: одиночный пиксель глубины шумит,
    /// а на краях предметов ещё и «улетает» между ближним и дальним планом.
    private static func sample(_ depth: ARDepthData) -> (median: Float, spread: Float)? {
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
        let low = values[Int(Float(values.count - 1) * 0.1)]
        let high = values[Int(Float(values.count - 1) * 0.9)]
        return (values[values.count / 2], high - low)
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
