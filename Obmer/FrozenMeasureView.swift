import SwiftUI
import simd

/// Экран замера по застывшему кадру: тычешь пальцем в две точки на фотографии.
/// Целиться прицелом не надо, поворачивать телефон между точками — тоже,
/// поэтому и дрейфа между замерами нет.
struct FrozenMeasureView: View {

    let frozen: FrozenMeasure
    var target: MeasureTarget?
    let onRetake: () -> Void
    let onClose: () -> Void

    @State private var spots: [CGPoint] = []      // доли от размера кадра
    @State private var points: [SIMD3<Float>] = []
    @State private var result: Int?
    @State private var warning: String?
    /// Точка, которую сейчас тащат пальцем, и её место на снимке.
    @State private var dragging: Int?
    @State private var loupe: CGPoint?

    /// Кадр с камеры горизонтальный, на вертикальном экране он повёрнут:
    /// ширина показанного снимка — это высота исходного, и наоборот.
    private var shownWidth: CGFloat { frozen.imageSize.height }
    private var shownHeight: CGFloat { frozen.imageSize.width }

    private var step: LocalizedStringKey {
        switch spots.count {
        case 0: return "Шаг 1 из 2 — прижмите палец к первой точке, над ним появится лупа"
        case 1: return "Шаг 2 из 2 — то же со второй точкой"
        default: return "Готово. Точку можно подвинуть пальцем, не ставя заново"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let frame = fitted(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Color.black
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    Image(uiImage: frozen.image)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)

                    ForEach(Array(spots.enumerated()), id: \.offset) { index, spot in
                        marker(index: index)
                            .position(x: frame.minX + spot.x * frame.width,
                                      y: frame.minY + spot.y * frame.height)
                    }

                    if spots.count == 2 {
                        Path { path in
                            path.move(to: CGPoint(x: frame.minX + spots[0].x * frame.width,
                                                  y: frame.minY + spots[0].y * frame.height))
                            path.addLine(to: CGPoint(x: frame.minX + spots[1].x * frame.width,
                                                     y: frame.minY + spots[1].y * frame.height))
                        }
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    // Точка ставится и двигается одним жестом: пока палец
                    // на экране, над ним висит лупа, и попадание задаёт
                    // увеличенная картинка, а не размер пальца.
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard frame.contains(value.location) else { return }
                            loupe = value.location
                            if dragging == nil { dragging = beginDrag(at: value.location, in: frame) }
                            if let index = dragging { moveSpot(index, to: value.location, in: frame) }
                        }
                        .onEnded { value in
                            if let index = dragging, frame.contains(value.location) {
                                commit(index, at: value.location, in: frame)
                            }
                            dragging = nil
                            loupe = nil
                        }
                )

                if let loupe, let frame = Optional(frame) {
                    LoupeView(image: frozen.image, frame: frame, at: loupe)
                        .position(x: loupe.x, y: max(loupe.y - 90, 70))
                        .allowsHitTesting(false)
                }
            }

            controls
        }
        .background(Color.black.ignoresSafeArea())
    }

    /// Снимок показывается целиком, без обрезки. Живая картинка обрезана
    /// по краям — экран уже кадра, — и если обрезать так же, часть снятого
    /// пропадёт безвозвратно. Лучше показать шире, чем потерять нужный угол;
    /// точность всё равно даёт лупа, а не размер картинки.
    private func fitted(in size: CGSize) -> CGRect {
        let scale = min(size.width / shownWidth, size.height / shownHeight)
        let width = shownWidth * scale
        let height = shownHeight * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }

    private func marker(index: Int) -> some View {
        ZStack {
            Circle().stroke(Color.green, lineWidth: 2).frame(width: 22, height: 22)
            Circle().fill(Color.green).frame(width: 5, height: 5)
            Text("\(index + 1)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .offset(x: 16, y: -12)
        }
        .shadow(radius: 3)
    }

    /// Какую точку тащим: уже стоящую рядом или новую.
    private func beginDrag(at location: CGPoint, in frame: CGRect) -> Int? {
        for (index, spot) in spots.enumerated() {
            let place = CGPoint(x: frame.minX + spot.x * frame.width,
                                y: frame.minY + spot.y * frame.height)
            if hypot(place.x - location.x, place.y - location.y) < 44 { return index }
        }
        guard spots.count < 2 else { return nil }
        spots.append(spotValue(location, in: frame))
        points.append(SIMD3<Float>(repeating: 0))
        return spots.count - 1
    }

    private func moveSpot(_ index: Int, to location: CGPoint, in frame: CGRect) {
        guard index < spots.count else { return }
        spots[index] = spotValue(location, in: frame)
    }

    private func spotValue(_ location: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: (location.x - frame.minX) / frame.width,
                y: (location.y - frame.minY) / frame.height)
    }

    /// Считаем координату только когда палец отпущен: во время движения
    /// это лишняя работа, а результат всё равно виден только в конце.
    private func commit(_ index: Int, at location: CGPoint, in frame: CGRect) {
        let spot = spotValue(location, in: frame)
        guard let reading = frozen.world(at: spot) else {
            warning = String(localized: "В этой точке лидар ничего не видит — подвиньте чуть в сторону.")
            spots.remove(at: index)
            points.remove(at: index)
            result = nil
            return
        }
        warning = reading.spread > 0.04
            ? String(localized: "Точка на ребре: глубина скачет. Лучше поставить её на ровное место рядом.")
            : nil

        spots[index] = spot
        points[index] = reading.point

        if points.count == 2 {
            let value = Int((simd_distance(points[0], points[1]) * 1000).rounded())
            if value < 30 {
                warning = String(localized: "Точки почти в одном месте — размер \(value) мм. Подвиньте вторую дальше.")
            }
            result = value
            MeasurementLog.record(value)
        } else {
            result = nil
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            // Шаг всегда написан явно: раньше по экрану было не понять,
            // сколько точек уже стоит.
            Text(step)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))

            if let result {
                Text("\(result) мм")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }

            if let warning {
                Text(verbatim: warning)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if let target, let result {
                Button {
                    CorrectionStore.shared.set(result, for: target.element, target.kind)
                    onClose()
                } label: {
                    Label("Записать в обмер", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }

            if !spots.isEmpty {
                Button {
                    spots.removeLast()
                    points.removeLast()
                    result = nil
                    warning = nil
                } label: {
                    Label("Убрать точку", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }

            HStack(spacing: 12) {
                Button("Закрыть") { onClose() }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 50)
                    .background(.white.opacity(0.15), in: Capsule())

                Button("Снять заново") { onRetake() }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 24)
    }
}


/// Увеличенный кусок снимка над пальцем.
/// Палец накрывает на экране около пятидесяти миллиметров объекта — без лупы
/// точнее в точку не попасть, и это стало главной оставшейся погрешностью.
private struct LoupeView: View {

    let image: UIImage
    let frame: CGRect
    let at: CGPoint

    private let size: CGFloat = 150
    // Снимок показан уменьшенным, поэтому лупе нужно больше увеличения,
    // чтобы палец попадал точнее, чем позволяет экран.
    private let zoom: CGFloat = 9

    var body: some View {
        ZStack {
            Image(uiImage: image)
                .resizable()
                .frame(width: frame.width * zoom, height: frame.height * zoom)
                .offset(x: (frame.midX - at.x) * zoom, y: (frame.midY - at.y) * zoom)
                .frame(width: size, height: size)
                .clipShape(Circle())

            Circle().stroke(Color.white, lineWidth: 3)
            Path { path in
                path.move(to: CGPoint(x: size / 2 - 12, y: size / 2))
                path.addLine(to: CGPoint(x: size / 2 + 12, y: size / 2))
                path.move(to: CGPoint(x: size / 2, y: size / 2 - 12))
                path.addLine(to: CGPoint(x: size / 2, y: size / 2 + 12))
            }
            .stroke(Color.green, lineWidth: 1.5)
        }
        .frame(width: size, height: size)
        .shadow(radius: 6)
    }
}
