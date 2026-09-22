import Foundation
import RoomPlan
import simd

/// Одна измеренная позиция для таблицы результатов.
struct MeasuredItem: Identifiable {
    let id: UUID
    let name: String
    let dimensions: String
    let confidence: CapturedRoom.Confidence
    /// Тот же размер, посчитанный по сырому мешу лидара. Для проёмов
    /// показывается второй строкой: там расхождение ещё не сверено с рулеткой.
    /// Для стен меш стал основным размером и сюда не пишется.
    var byMesh: String? = nil
    /// Размер взят у RoomPlan, потому что меш его не дал. На контрольных
    /// обмерах RoomPlan мажет на 150–190 мм там, где лидар даёт 20, —
    /// такую строку нельзя показывать наравне с остальными.
    var isApproximate = false
    /// Насколько размер по мешу заслуживает доверия: доля обмеренной площади проёма.
    var meshCoverage: Double? = nil
}

/// Разбирает CapturedRoom в человекочитаемые размеры.
/// Все длины переводятся в миллиметры: дизайнер работает в них, не в метрах.
struct RoomSummary {

    let walls: [MeasuredItem]
    let openings: [MeasuredItem]
    let perimeterMM: Int
    let ceilingHeightMM: Int
    /// Габаритная площадь — по описанному вокруг помещения прямоугольнику.
    /// Для Г-образных комнат она завышена: точный полигон появится вместе с солвером.
    let boundingAreaM2: Double
    let lowConfidenceCount: Int
    /// Что удалось построить по мешу и чего не хватило.
    let meshReport: WallSolver.Report

    /// Ближайшая к понижению потолка стена — чтобы сказать, куда идти доснимать.
    let loweredNearWall: String?

    /// Признаки того, что обход не завершён и обмеру нельзя доверять.
    /// RoomPlan помечает высокой достоверностью даже заведомо неполные сканы,
    /// поэтому осмысленность результата приходится проверять самим.
    let completenessIssues: [String]

    init(room: CapturedRoom, mesh: MeshCapture? = nil) {
        var wallItems: [MeasuredItem] = []
        var lengths: [Float] = []
        var heights: [Float] = []
        var corners: [SIMD2<Float>] = []

        // Длины стен считаются по мешу сразу для всех: угол принадлежит двум
        // стенам одновременно, поодиночке его не построить.
        let solution: WallSolver.Solution
        if let mesh, !mesh.isEmpty {
            solution = WallSolver.solve(walls: room.walls, mesh: mesh)
        } else {
            solution = WallSolver.Solution(lengths: [:],
                                           report: .init(planesFound: 0, wallsMeasured: 0, unmeasured: []))
        }
        let byMesh = solution.lengths
        let meshHeightMM = mesh?.profile()?.heightMM

        for (index, wall) in room.walls.enumerated() {
            let length = wall.dimensions.x
            let height = wall.dimensions.y
            lengths.append(length)
            heights.append(height)

            // Длина по лидару — основной размер: на контрольном обмере
            // солвер давал 0–22 мм против 149–186 у RoomPlan.
            // Размер RoomPlan остаётся только как запасной, и с пометкой.
            let ceilingMM = meshHeightMM ?? Self.mm(height)
            var item: MeasuredItem
            if let solved = byMesh[wall.identifier] {
                item = MeasuredItem(
                    id: wall.identifier,
                    name: String(localized: "Стена \(index + 1)"),
                    dimensions: String(localized: "\(solved) × \(ceilingMM) мм"),
                    confidence: wall.confidence
                )
            } else {
                item = MeasuredItem(
                    id: wall.identifier,
                    name: String(localized: "Стена \(index + 1)"),
                    dimensions: String(localized: "\(Self.mm(length)) × \(Self.mm(height)) мм"),
                    confidence: wall.confidence
                )
                item.isApproximate = true
            }
            wallItems.append(item)

            // Концы стены в мировых координатах: центр ± половина длины
            // вдоль собственной оси X стены. Из них считается габарит помещения.
            let transform = wall.transform
            let center = SIMD2<Float>(transform.columns.3.x, transform.columns.3.z)
            let axis3 = simd_normalize(SIMD3<Float>(transform.columns.0.x,
                                                    transform.columns.0.y,
                                                    transform.columns.0.z))
            let axis = SIMD2<Float>(axis3.x, axis3.z)
            corners.append(center + axis * (length / 2))
            corners.append(center - axis * (length / 2))
        }

        var openingItems: [MeasuredItem] = []
        for surface in room.doors + room.windows + room.openings {
            var item = MeasuredItem(
                id: surface.identifier,
                name: Self.label(for: surface.category),
                dimensions: String(localized: "\(Self.mm(surface.dimensions.x)) × \(Self.mm(surface.dimensions.y)) мм"),
                confidence: surface.confidence
            )

            // Проёмы — то, на чём RoomPlan промахивается сильнее всего,
            // поэтому по мешу пересчитываются в первую очередь именно они.
            if let mesh, !mesh.isEmpty,
               let measured = OpeningSolver.measure(surface, in: mesh) {
                item.byMesh = String(localized: "\(measured.widthMM) × \(measured.heightMM) мм")
                item.meshCoverage = measured.coverage
            }

            openingItems.append(item)
        }

        let wallSum = lengths.reduce(0, +)
        let ceiling = heights.max() ?? 0

        var width: Float = 0
        var depth: Float = 0
        if !corners.isEmpty {
            let xs = corners.map(\.x)
            let zs = corners.map(\.y)
            width = (xs.max() ?? 0) - (xs.min() ?? 0)
            depth = (zs.max() ?? 0) - (zs.min() ?? 0)
        }
        let boundingPerimeter = 2 * (width + depth)

        self.walls = wallItems
        self.openings = openingItems
        self.perimeterMM = Self.mm(wallSum)
        self.ceilingHeightMM = Self.mm(ceiling)
        self.boundingAreaM2 = Double(width * depth)
        self.lowConfidenceCount = (wallItems + openingItems).filter { $0.confidence == .low }.count

        // --- проверка осмысленности ---
        var issues: [String] = []

        if wallItems.count < 4 {
            issues.append(String(localized: "Найдено стен: \(wallItems.count). У замкнутой комнаты их обычно не меньше четырёх — обход не завершён."))
        }

        let ceilingMM = Self.mm(ceiling)
        if ceilingMM < 2100 {
            issues.append(String(localized: "Высота потолка \(ceilingMM) мм неправдоподобно мала — верх стен не попал в скан."))
        } else if ceilingMM > 4500 {
            issues.append(String(localized: "Высота потолка \(ceilingMM) мм неправдоподобно велика — вероятно, склеились два уровня."))
        }

        let shortWalls = lengths.filter { $0 < 0.4 }.count
        if shortWalls > 0 {
            issues.append(String(localized: "Коротких стен, меньше 400 мм: \(shortWalls). Обычно это обрывки, а не настоящие стены."))
        }

        if boundingPerimeter > 0.5, wallSum < boundingPerimeter * 0.8 {
            issues.append(String(localized: "Контур не замкнут: суммарная длина стен заметно меньше периметра помещения."))
        }

        // --- чего не хватило мешу ---
        // Отдельно от проверок RoomPlan: там речь про незавершённый обход,
        // здесь — про то, каким стенам не досталось углов.
        if !solution.report.unmeasured.isEmpty, solution.report.wallsMeasured > 0 {
            let names = solution.report.unmeasured.joined(separator: ", ")
            issues.append(String(localized: "По лидару не удалось построить: \(names). У этих стен не нашлось обоих углов — пройдите вдоль них ещё раз, захватывая полосу стены над мебелью."))
        }

        // Место понижения называем по ближайшей стене: «в этом месте»
        // ничего не значит для того, кто стоит в помещении.
        var near: String?
        if let centre = mesh?.profile()?.loweredCentre {
            var best: (String, Float)?
            for (index, wall) in room.walls.enumerated() {
                let t = wall.transform
                let distance = simd_distance(SIMD2<Float>(t.columns.3.x, t.columns.3.z),
                                             SIMD2<Float>(centre.x, centre.z))
                if distance < (best?.1 ?? .greatestFiniteMagnitude) {
                    best = (String(localized: "Стена \(index + 1)"), distance)
                }
            }
            near = best?.0
        }
        self.loweredNearWall = near

        self.meshReport = solution.report
        self.completenessIssues = issues
    }

    /// Метры → миллиметры, округление до целого.
    private static func mm(_ meters: Float) -> Int {
        Int((meters * 1000).rounded())
    }

    private static func label(for category: CapturedRoom.Surface.Category) -> String {
        switch category {
        case .wall:    return String(localized: "Стена")
        case .door:    return String(localized: "Дверь")
        case .window:  return String(localized: "Окно")
        case .opening: return String(localized: "Проём")
        case .floor:   return String(localized: "Пол")
        @unknown default: return String(localized: "Элемент")
        }
    }
}

extension CapturedRoom.Confidence {
    var localizedLabel: String {
        switch self {
        case .high:   return String(localized: "высокая")
        case .medium: return String(localized: "средняя")
        case .low:    return String(localized: "низкая")
        @unknown default: return "—"
        }
    }
}
