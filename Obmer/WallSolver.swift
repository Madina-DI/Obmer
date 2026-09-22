import Foundation
import RoomPlan
import simd

/// Длины стен по сырому мешу лидара, без опоры на разбиение RoomPlan.
///
/// Ключевое правило: **конец стены задаёт не то, докуда мы её увидели, а
/// перпендикулярная стена, в которую она упирается.** У стены 1 контрольного
/// коридора оба угла закрыты шкафами, RoomPlan обрубал её по краю мебели и
/// терял 160–200 мм. Здесь угол не наблюдается, а вычисляется — и та же стена
/// выходит с ошибкой 12 мм.
///
/// Порядок работы:
/// 1. Берём вертикальные грани в полосе над мебелью, но ниже потолка.
/// 2. Находим преобладающее направление стен и разворачиваем план по нему.
/// 3. Каждое семейство параллельных стен даёт пики в гистограмме удалений —
///    это и есть плоскости.
/// 4. Длина стены — размах перпендикулярных плоскостей, которые до неё
///    дотягиваются, обрезанный её собственной видимой частью.
enum WallSolver {

    /// Полоса высот, в которой собираются грани стен. Низ отсекает плинтусы
    /// и большую часть мебели, верх — потолок и карнизы.
    private static let bandLow: Float = 1.20
    private static let bandHigh: Float = 2.45
    private static let ceilingGap: Float = 0.08
    /// Грань считается вертикальной, пока её нормаль не задрана выше этого.
    private static let maxTilt: Float = 0.30
    /// Насколько нормаль должна совпасть с осью, чтобы стену отнесли к семейству.
    private static let axisMatch: Float = 0.87
    private static let binSize: Float = 0.05
    private static let minArea: Float = 0.25
    private static let mergeDistance: Float = 0.12
    private static let slab: Float = 0.09
    /// Допуск, с которым перпендикулярная стена считается дотянувшейся.
    private static let reachTolerance: Float = 0.35
    /// Насколько угол может выйти за видимую часть стены. Это и есть запас
    /// на спрятанный за мебелью угол; больше — и стена начинает прирастать
    /// соседней комнатой.
    private static let cornerMargin: Float = 0.40

    /// Что удалось построить. Нужно, чтобы отличить «стена короткая»
    /// от «стену не сняли»: без этого приложение молча выдаёт заниженный
    /// размер и выглядит уверенно.
    struct Report {
        let planesFound: Int
        let wallsMeasured: Int
        /// Стены RoomPlan, для которых меш не дал размера: у них не нашлось
        /// двух углов, то есть какую-то из соседних стен не сняли.
        let unmeasured: [String]
    }

    struct Solution {
        let lengths: [UUID: Int]
        let report: Report
    }

    private enum Family { case along, across }

    private struct Plane {
        let family: Family
        let position: Float
        let lo: Float
        let hi: Float
        let area: Float
    }

    private struct Face {
        let u: Float
        let v: Float
        let family: Family
        let area: Float
    }

    /// Длины стен в миллиметрах по идентификаторам стен RoomPlan.
    /// У RoomPlan берётся только положение — какую плоскость с какой стеной
    /// сопоставить. Сам размер целиком из меша.
    static func solve(walls: [CapturedRoom.Surface], mesh: MeshCapture) -> Solution {
        let empty = Solution(lengths: [:], report: Report(planesFound: 0, wallsMeasured: 0, unmeasured: []))
        guard !walls.isEmpty, !mesh.isEmpty else { return empty }
        guard let (faces, angle) = project(mesh) else { return empty }

        let along = planes(of: .along, in: faces)
        let across = planes(of: .across, in: faces)
        guard !along.isEmpty, !across.isEmpty else { return empty }

        var sizes: [(Family, Float, Int)] = []
        for plane in along {
            if let length = extent(of: plane, crossing: across) { sizes.append((.along, plane.position, length)) }
        }
        for plane in across {
            if let length = extent(of: plane, crossing: along) { sizes.append((.across, plane.position, length)) }
        }
        guard !sizes.isEmpty else {
            return Solution(lengths: [:], report: Report(planesFound: along.count + across.count,
                                                         wallsMeasured: 0, unmeasured: []))
        }

        // Сопоставление с RoomPlan: у стены берём центр и направление,
        // переводим в ту же систему координат и ищем ближайшую плоскость.
        let cosine = cos(-angle), sine = sin(-angle)
        var result: [UUID: Int] = [:]
        var missed: [String] = []
        for (number, wall) in walls.enumerated() {
            let transform = wall.transform
            let x = transform.columns.3.x, z = transform.columns.3.z
            let u = x * cosine - z * sine
            let v = x * sine + z * cosine

            let name = String(localized: "Стена \(number + 1)")

            let axis3 = SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
            guard simd_length(axis3) > 0.001 else { missed.append(name); continue }
            let axis = simd_normalize(axis3)
            let flat = SIMD2<Float>(axis.x, axis.z)
            guard simd_length(flat) > 0.001 else { missed.append(name); continue }
            let direction = simd_normalize(flat)
            let au = direction.x * cosine - direction.y * sine
            let av = direction.x * sine + direction.y * cosine

            // Стена, вытянутая вдоль v, принадлежит семейству с нормалью вдоль u.
            let family: Family
            let position: Float
            if abs(av) > axisMatch { family = .along; position = u }
            else if abs(au) > axisMatch { family = .across; position = v }
            else { missed.append(name); continue }

            let candidates = sizes.filter { $0.0 == family }
            guard let nearest = candidates.min(by: { abs($0.1 - position) < abs($1.1 - position) }),
                  abs(nearest.1 - position) < 0.30 else { missed.append(name); continue }
            result[wall.identifier] = nearest.2
        }

        return Solution(
            lengths: result,
            report: Report(planesFound: along.count + across.count,
                           wallsMeasured: result.count,
                           unmeasured: missed)
        )
    }

    // MARK: - Подготовка

    /// Вертикальные грани в полосе высот, развёрнутые по главному направлению стен.
    private static func project(_ mesh: MeshCapture) -> ([Face], Float)? {
        var floorHeights: [Float] = []
        var ceilingHeights: [Float] = []
        for chunk in mesh.chunks {
            for (index, face) in chunk.faces.enumerated() {
                let category = index < chunk.classes.count ? chunk.classes[index] : 0
                guard category == 2 || category == 3 else { continue }
                let y = (chunk.vertices[Int(face.x)].y + chunk.vertices[Int(face.y)].y + chunk.vertices[Int(face.z)].y) / 3
                if category == 2 { floorHeights.append(y) } else { ceilingHeights.append(y) }
            }
        }
        guard floorHeights.count > 100, ceilingHeights.count > 100 else { return nil }
        floorHeights.sort(); ceilingHeights.sort()
        let floor = floorHeights[floorHeights.count / 2]
        let ceiling = ceilingHeights[Int(Double(ceilingHeights.count - 1) * 0.9)]

        let low = floor + bandLow
        let high = min(floor + bandHigh, ceiling - ceilingGap)
        guard high > low else { return nil }

        var raw: [(SIMD2<Float>, SIMD2<Float>, Float)] = []
        for chunk in mesh.chunks {
            for (index, face) in chunk.faces.enumerated() {
                let category = index < chunk.classes.count ? chunk.classes[index] : 0
                guard category != 2, category != 3 else { continue }
                let a = chunk.vertices[Int(face.x)]
                let b = chunk.vertices[Int(face.y)]
                let c = chunk.vertices[Int(face.z)]
                let height = (a.y + b.y + c.y) / 3
                guard height > low, height < high else { continue }
                let normal = simd_cross(b - a, c - a)
                let doubled = simd_length(normal)
                guard doubled > 1e-7 else { continue }
                let unit = normal / doubled
                guard abs(unit.y) <= maxTilt else { continue }
                let flat = SIMD2<Float>(unit.x, unit.z)
                guard simd_length(flat) > 1e-6 else { continue }
                raw.append((SIMD2<Float>((a.x + b.x + c.x) / 3, (a.z + b.z + c.z) / 3),
                            simd_normalize(flat),
                            doubled / 2))
            }
        }
        guard raw.count > 500 else { return nil }

        // Главное направление: нормали сводятся по модулю 90°, потому что
        // в прямоугольном помещении два семейства стен отличаются ровно на прямой угол.
        var histogram = [Float](repeating: 0, count: 90)
        for (_, normal, area) in raw {
            var degrees = atan2(normal.y, normal.x) * 180 / .pi
            degrees = degrees.truncatingRemainder(dividingBy: 90)
            if degrees < 0 { degrees += 90 }
            histogram[min(Int(degrees), 89)] += area
        }
        var peak = 0
        var peakValue: Float = -1
        for index in 0..<90 {
            let value = histogram[(index + 89) % 90] + histogram[index] + histogram[(index + 1) % 90]
            if value > peakValue { peakValue = value; peak = index }
        }
        var numerator: Float = 0, denominator: Float = 0
        for offset in -2...2 {
            let weight = histogram[((peak + offset) % 90 + 90) % 90]
            numerator += weight * Float(peak + offset)
            denominator += weight
        }
        let angle = (denominator > 0 ? numerator / denominator : Float(peak)) * .pi / 180

        let cosine = cos(-angle), sine = sin(-angle)
        var faces: [Face] = []
        for (centre, normal, area) in raw {
            let u = centre.x * cosine - centre.y * sine
            let v = centre.x * sine + centre.y * cosine
            let nu = normal.x * cosine - normal.y * sine
            let nv = normal.x * sine + normal.y * cosine
            if abs(nu) > axisMatch { faces.append(Face(u: u, v: v, family: .along, area: area)) }
            else if abs(nv) > axisMatch { faces.append(Face(u: u, v: v, family: .across, area: area)) }
        }
        return (faces, angle)
    }

    // MARK: - Плоскости

    /// Пики гистограммы удалений. Семейство `.along` собирается по координате u,
    /// `.across` — по v.
    private static func planes(of family: Family, in faces: [Face]) -> [Plane] {
        let members = faces.filter { $0.family == family }
        guard members.count > 40 else { return [] }
        let value: (Face) -> Float = family == .along ? { $0.u } : { $0.v }
        let span: (Face) -> Float = family == .along ? { $0.v } : { $0.u }

        let origin = members.map(value).min() ?? 0
        var buckets: [Int: Float] = [:]
        for face in members {
            buckets[Int((value(face) - origin) / binSize), default: 0] += face.area
        }
        guard let first = buckets.keys.min(), let last = buckets.keys.max() else { return [] }

        var smoothed: [Int: Float] = [:]
        for key in first...last {
            smoothed[key] = 0.25 * (buckets[key - 1] ?? 0) + 0.5 * (buckets[key] ?? 0) + 0.25 * (buckets[key + 1] ?? 0)
        }

        var found: [(Float, Float)] = []
        for key in first...last {
            let weight = smoothed[key] ?? 0
            guard weight >= minArea else { continue }
            let isPeak = [-2, -1, 1, 2].allSatisfy { (smoothed[key + $0] ?? 0) <= weight }
            guard isPeak else { continue }
            var numerator: Float = 0, denominator: Float = 0
            for offset in -2...2 {
                let bucket = buckets[key + offset] ?? 0
                numerator += bucket * (origin + (Float(key + offset) + 0.5) * binSize)
                denominator += bucket
            }
            guard denominator > 0 else { continue }
            found.append((numerator / denominator, denominator))
        }
        found.sort { $0.0 < $1.0 }

        var merged: [(Float, Float)] = []
        for candidate in found {
            if let previous = merged.last, abs(candidate.0 - previous.0) < mergeDistance {
                merged[merged.count - 1] = (candidate.1 > previous.1 ? candidate.0 : previous.0, previous.1 + candidate.1)
            } else {
                merged.append(candidate)
            }
        }

        var result: [Plane] = []
        for (position, area) in merged {
            let own = members.filter { abs(value($0) - position) < slab }.map(span).sorted()
            guard own.count >= 20 else { continue }
            let trim = max(1, own.count / 100)
            result.append(Plane(family: family, position: position,
                                lo: own[trim], hi: own[own.count - trim - 1], area: area))
        }
        return result
    }

    /// Длина стены: размах перпендикулярных плоскостей, которые до неё дотягиваются,
    /// обрезанный её собственной видимой частью с запасом на спрятанный угол.
    private static func extent(of plane: Plane, crossing others: [Plane]) -> Int? {
        let hits = others.filter { other in
            other.lo - reachTolerance <= plane.position
            && plane.position <= other.hi + reachTolerance
            && plane.lo - cornerMargin <= other.position
            && other.position <= plane.hi + cornerMargin
        }.map(\.position)

        guard hits.count >= 2, let low = hits.min(), let high = hits.max() else { return nil }
        let length = high - low
        guard length > 0.5 else { return nil }
        return Int((length * 1000).rounded())
    }
}
