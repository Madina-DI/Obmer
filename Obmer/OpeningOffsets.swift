import Foundation
import RoomPlan
import simd

/// Расстояния от углов стены до краёв проёма.
///
/// Для планировки они нужнее ширины: без них план не начертить — непонятно,
/// где дверь стоит на стене. Считаются из того, что уже есть: углы даёт солвер
/// стен с ошибкой в единицы миллиметров, положение проёма — RoomPlan.
/// Наводить пальцем ничего не нужно.
enum OpeningOffsets {

    struct Offsets {
        /// От начала стены до ближнего края проёма.
        let beforeMM: Int
        /// От дальнего края проёма до конца стены.
        let afterMM: Int
        /// Ширина проёма по тем же данным — для проверки:
        /// before + ширина + after должно сойтись с длиной стены.
        let widthMM: Int
    }

    static func compute(for room: CapturedRoom, solution: WallSolver.Solution) -> [UUID: Offsets] {
        guard !solution.placements.isEmpty else { return [:] }

        let cosine = cos(-solution.angle), sine = sin(-solution.angle)
        var result: [UUID: Offsets] = [:]

        for surface in room.doors + room.windows + room.openings {
            let transform = surface.transform
            let x = transform.columns.3.x, z = transform.columns.3.z
            let u = x * cosine - z * sine
            let v = x * sine + z * cosine

            let axis3 = SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
            guard simd_length(axis3) > 0.001 else { continue }
            let axis = simd_normalize(axis3)
            let flat = SIMD2<Float>(axis.x, axis.z)
            guard simd_length(flat) > 0.001 else { continue }
            let direction = simd_normalize(flat)
            let au = direction.x * cosine - direction.y * sine
            let av = direction.x * sine + direction.y * cosine

            // Проём лежит в той же стене, значит и семейство у него то же.
            let family: WallSolver.Family
            let across: Float      // поперёк стены — по нему ищем саму стену
            let along: Float       // вдоль стены — по нему считаем расстояния
            if abs(av) > 0.87 { family = .along; across = u; along = v }
            else if abs(au) > 0.87 { family = .across; across = v; along = u }
            else { continue }

            let candidates = solution.placements.values.filter { $0.family == family }
            guard let wall = candidates.min(by: {
                abs($0.position - across) < abs($1.position - across)
            }), abs(wall.position - across) < 0.30 else { continue }

            let half = surface.dimensions.x / 2
            let near = along - half
            let far = along + half
            let before = near - wall.low
            let after = wall.high - far
            // Отрицательное значит, что проём вылез за найденный угол —
            // отдавать такое нельзя, это признак несошедшейся геометрии.
            guard before > -0.05, after > -0.05 else { continue }

            result[surface.identifier] = Offsets(
                beforeMM: Int((max(before, 0) * 1000).rounded()),
                afterMM: Int((max(after, 0) * 1000).rounded()),
                widthMM: Int((surface.dimensions.x * 1000).rounded())
            )
        }
        return result
    }
}
