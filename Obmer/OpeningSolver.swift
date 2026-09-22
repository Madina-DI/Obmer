import Foundation
import RoomPlan
import simd

/// Измерение проёма по сырому мешу вместо прямоугольника RoomPlan.
///
/// RoomPlan обводит только уверенно распознанную часть проёма и обрубает края:
/// на контрольном обмере коридора это дало от 149 до 201 мм занижения по каждой
/// из трёх дверей. Здесь у RoomPlan берётся только положение — где искать проём,
/// а размеры считаются по лидару: что там на самом деле.
///
/// Идея простая. В системе координат проёма стена лежит в плоскости z = 0.
/// Там, где проём, поверхности на этой плоскости нет: либо пусто (открытый проход),
/// либо она утоплена (закрытое полотно, ниша со скосами). Значит проём — это
/// связная область, где поверхность отступает от плоскости стены или отсутствует.
enum OpeningSolver {

    struct Measurement {
        let widthMM: Int
        let heightMM: Int
        /// Доля ячеек проёма, по которым были данные. Низкая — часть проёма
        /// не попала в скан, размер считать нельзя.
        let coverage: Double
    }

    /// Сторона ячейки сетки. 20 мм — мельче шума лидара, но крупнее дыр в меше.
    private static let cell: Float = 0.02
    /// Отступ поверхности от плоскости стены, начиная с которого это уже проём.
    private static let depthThreshold: Float = 0.03
    /// Насколько шире прямоугольника RoomPlan имеет смысл искать.
    private static let searchScale: Float = 1.9

    static func measure(_ surface: CapturedRoom.Surface, in mesh: MeshCapture) -> Measurement? {
        let inverse = surface.transform.inverse
        let halfWidth = surface.dimensions.x * searchScale / 2
        let halfHeight = surface.dimensions.y * searchScale / 2

        let columns = Int((halfWidth * 2 / cell).rounded(.up)) + 1
        let rows = Int((halfHeight * 2 / cell).rounded(.up)) + 1
        guard columns > 4, rows > 4, columns * rows < 2_000_000 else { return nil }

        // Для каждой ячейки — ближайшая к плоскости стены точка поверхности.
        // Берём именно ближайшую: наличник или откос выступают вперёд, и если
        // усреднять, край проёма размажется ровно так же, как у RoomPlan.
        var depth = [Float](repeating: .nan, count: columns * rows)

        for chunk in mesh.chunks {
            for vertex in chunk.vertices {
                let local = inverse * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1)
                guard abs(local.z) < 0.5,
                      abs(local.x) < halfWidth,
                      abs(local.y) < halfHeight else { continue }

                let column = Int((local.x + halfWidth) / cell)
                let row = Int((local.y + halfHeight) / cell)
                guard column >= 0, column < columns, row >= 0, row < rows else { continue }

                let index = row * columns + column
                let current = depth[index]
                if current.isNaN || abs(local.z) < abs(current) {
                    depth[index] = local.z
                }
            }
        }

        // Плоскость стены — по краям области поиска: там заведомо стена, а не проём.
        var edges: [Float] = []
        for row in 0..<rows {
            for column in 0..<columns where column < 2 || column >= columns - 2 {
                let value = depth[row * columns + column]
                if !value.isNaN { edges.append(value) }
            }
        }
        guard edges.count > 20 else { return nil }
        edges.sort()
        let wallZ = edges[edges.count / 2]

        // Ячейка принадлежит проёму, если поверхность отступила от плоскости стены
        // или её там нет вовсе.
        var isOpening = [Bool](repeating: false, count: columns * rows)
        var hasData = [Bool](repeating: false, count: columns * rows)
        for index in 0..<depth.count {
            let value = depth[index]
            if value.isNaN {
                isOpening[index] = true
            } else {
                hasData[index] = true
                isOpening[index] = abs(value - wallZ) > depthThreshold
            }
        }

        // Разливаемся из центра — там, где RoomPlan нашёл проём.
        let start = (rows / 2) * columns + columns / 2
        guard isOpening[start] else { return nil }

        var visited = [Bool](repeating: false, count: columns * rows)
        var stack = [start]
        visited[start] = true

        var minColumn = columns, maxColumn = 0
        var minRow = rows, maxRow = 0
        var filled = 0
        var withData = 0

        while let index = stack.popLast() {
            let row = index / columns
            let column = index % columns
            filled += 1
            if hasData[index] { withData += 1 }
            minColumn = min(minColumn, column); maxColumn = max(maxColumn, column)
            minRow = min(minRow, row); maxRow = max(maxRow, row)

            for (dc, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nc = column + dc, nr = row + dr
                guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                let next = nr * columns + nc
                guard !visited[next], isOpening[next] else { continue }
                visited[next] = true
                stack.append(next)
            }
        }

        // Область упёрлась в границы поиска — значит утекла через дыру в меше
        // и обвела уже не проём, а полстены.
        guard minColumn > 0, maxColumn < columns - 1, minRow > 0 else { return nil }

        let width = Float(maxColumn - minColumn + 1) * cell
        let height = Float(maxRow - minRow + 1) * cell

        return Measurement(
            widthMM: Int((width * 1000).rounded()),
            heightMM: Int((height * 1000).rounded()),
            coverage: filled > 0 ? Double(withData) / Double(filled) : 0
        )
    }
}
