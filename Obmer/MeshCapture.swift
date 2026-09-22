import ARKit
import Foundation
import Metal
import simd

/// Сырая геометрия от лидара, снятая параллельно с RoomPlan.
///
/// RoomPlan натягивает на данные лидара прямоугольники и выбрасывает всё,
/// что в них не укладывается: балки, скосы откосов, кривизну стен, края проёмов.
/// Меш не упрощает ничего. Мерить по нему приходится самим, зато меряется
/// настоящая поверхность, а не её схема.
final class MeshCapture: NSObject, ObservableObject, ARSessionDelegate {

    /// Кусок меша, скопированный из ARMeshAnchor в обычные массивы.
    /// Копия обязательна: ARKit переиспользует буферы анкоров, и читать их
    /// после остановки сеанса нельзя.
    struct Chunk {
        var vertices: [SIMD3<Float>]   // мировые координаты, метры
        var faces: [SIMD3<UInt32>]     // индексы внутри куска
        var classes: [UInt8]           // ARMeshClassification, по одной на грань
    }

    /// Высотный профиль помещения — первое, что меш даёт, а RoomPlan не даёт вовсе.
    struct Profile {
        let heightMM: Int            // пол → основной уровень потолка
        let lowestClearMM: Int       // пол → низ балки или короба
        let dropMM: Int              // насколько потолок опускается
        let loweredAreaM2: Double    // площадь опущенного участка
        let ceilingFaces: Int        // по скольким граням посчитан потолок
        /// Где именно потолок опускается, в мировых координатах.
        /// Нужно, чтобы назвать место словами: «непонятно где» —
        /// бесполезное предупреждение.
        let loweredCentre: SIMD3<Float>?

        /// Опущенный участок бывает трёх сортов, и различать их обязательно:
        /// крошечный — данных не хватило; нормальный — это балка или короб;
        /// огромный — это уже не балка, а другой уровень потолка или соседняя
        /// комната, затесавшаяся в скан.
        enum Verdict { case tooLittleData, beam, notABeam, flat }

        var verdict: Verdict {
            if dropMM < 40 { return .flat }
            if loweredAreaM2 < 0.10 { return .tooLittleData }
            if loweredAreaM2 > 1.00 { return .notABeam }
            return .beam
        }
    }

    /// Сессия ARKit живёт здесь, а не на экране сканирования: после обхода
    /// экран закрывается, а досъёмка должна продолжиться в той же системе
    /// координат — иначе новый меш не сойдётся со старым.
    let session = ARSession()

    /// Растёт при каждом снимке. По нему экран результата понимает,
    /// что пора пересчитать размеры.
    @Published private(set) var revision = 0

    /// Пришёл ли хоть один ARMeshAnchor. Если нет — sceneReconstruction
    /// не включился, и весь разговор про меш беспредметен.
    @Published private(set) var isReceivingMesh = false
    @Published private(set) var liveTriangleCount = 0

    private var anchors: [UUID: ARMeshAnchor] = [:]
    /// Куски, которые ARKit уже выбросил. Он удерживает поверхность только
    /// вокруг камеры и удаляет дальние анкоры по мере того, как уходишь —
    /// поэтому геометрию надо снимать в момент удаления, иначе от обхода
    /// останется только его хвост.
    private var retired: [UUID: Chunk] = [:]
    private(set) var chunks: [Chunk] = []

    // MARK: - Приём анкоров

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { absorb(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { absorb(anchors) }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for case let mesh as ARMeshAnchor in anchors {
            if let saved = self.anchors.removeValue(forKey: mesh.identifier) {
                retired[saved.identifier] = chunk(from: saved)
            }
        }
        recount()
    }

    /// Приём кусков меша. Публичный намеренно: делегат у ARSession всего один,
    /// и если RoomPlan заберёт его себе, анкоры будут доставляться опросом кадра.
    func absorb(_ incoming: [ARAnchor]) {
        var changed = false
        for case let mesh as ARMeshAnchor in incoming {
            anchors[mesh.identifier] = mesh
            changed = true
        }
        guard changed else { return }
        if !isReceivingMesh { isReceivingMesh = true }
        recount()
    }

    private func recount() {
        let live = anchors.values.reduce(0) { $0 + $1.geometry.faces.count }
        let saved = retired.values.reduce(0) { $0 + $1.faces.count }
        liveTriangleCount = live + saved
    }

    // MARK: - Снимок

    /// Копирует всё, что накопилось, в обычные массивы. Вызывать сразу после
    /// остановки сеанса: дальше буферы анкоров считать уже нельзя.
    func snapshot() {
        chunks = Array(retired.values) + anchors.values.map(chunk(from:))
        revision += 1
    }

    /// Конфигурация с реконструкцией поверхности. Одна на оба режима —
    /// и на первый обход, и на досъёмку.
    func makeConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        return configuration
    }

    /// Продолжить сбор меша после того, как RoomPlan уже отдал модель.
    /// options пустые намеренно: сбрасывать трекинг нельзя, иначе досъёмка
    /// ляжет в другую систему координат.
    func resume() {
        session.delegate = self
        session.run(makeConfiguration(), options: [])
    }

    func pause() { session.pause() }

    /// Копия геометрии анкора в мировых координатах.
    private func chunk(from anchor: ARMeshAnchor) -> Chunk {
        let geometry = anchor.geometry
        let transform = anchor.transform

        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(geometry.vertices.count)
        for index in 0..<geometry.vertices.count {
            let local = geometry.vertex(at: index)
            let world = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
            vertices.append(SIMD3<Float>(world.x, world.y, world.z))
        }

        var faces: [SIMD3<UInt32>] = []
        faces.reserveCapacity(geometry.faces.count)
        for index in 0..<geometry.faces.count {
            faces.append(geometry.face(at: index))
        }

        var classes = [UInt8](repeating: 0, count: geometry.faces.count)
        if let source = geometry.classification {
            let base = source.buffer.contents().advanced(by: source.offset)
            for index in 0..<min(source.count, classes.count) {
                classes[index] = base.advanced(by: source.stride * index)
                    .assumingMemoryBound(to: UInt8.self).pointee
            }
        }

        return Chunk(vertices: vertices, faces: faces, classes: classes)
    }

    var isEmpty: Bool { chunks.allSatisfy { $0.faces.isEmpty } }

    var triangleCount: Int { chunks.reduce(0) { $0 + $1.faces.count } }

    /// Сколько граней каждого класса. Ключ — сырое значение ARMeshClassification.
    func faceCounts() -> [UInt8: Int] {
        var counts: [UInt8: Int] = [:]
        for chunk in chunks {
            for value in chunk.classes { counts[value, default: 0] += 1 }
        }
        return counts
    }

    // MARK: - Высотный профиль

    /// Считает высоту по граням, размеченным как пол и потолок.
    /// Основной уровень потолка берётся по верхней части распределения,
    /// самая низкая точка — по нижней: балка занимает малую долю площади,
    /// поэтому среднее её просто размажет, а перцентили — нет.
    func profile() -> Profile? {
        var floorHeights: [Float] = []
        var ceiling: [(height: Float, area: Float, centre: SIMD3<Float>)] = []

        for chunk in chunks {
            for (index, face) in chunk.faces.enumerated() {
                let category = index < chunk.classes.count ? chunk.classes[index] : 0
                guard category == 2 || category == 3 else { continue }
                let a = chunk.vertices[Int(face.x)]
                let b = chunk.vertices[Int(face.y)]
                let c = chunk.vertices[Int(face.z)]
                let y = (a.y + b.y + c.y) / 3
                if category == 2 {
                    floorHeights.append(y)
                } else {
                    ceiling.append((y,
                                    simd_length(simd_cross(b - a, c - a)) / 2,
                                    (a + b + c) / 3))
                }
            }
        }

        // Меньше сотни граней — это шум, а не поверхность.
        guard floorHeights.count > 100, ceiling.count > 100 else { return nil }

        floorHeights.sort()
        let floor = floorHeights[floorHeights.count / 2]

        // Основной уровень потолка — по верхней части распределения: балка
        // занимает малую долю площади и среднее бы утянула вниз.
        let sortedHeights = ceiling.map(\.height).sorted()
        let main = sortedHeights[Int(Double(sortedHeights.count - 1) * 0.9)]

        // Всё, что ниже основного уровня больше чем на 80 мм, — опущенный участок.
        // Его понижение берём медианой, а не минимумом: минимум цепляет одиночные
        // выбросы и от прохода к проходу скачет на десятки миллиметров.
        let lowered = ceiling.filter { main - $0.height > 0.08 }
        let drops = lowered.map { main - $0.height }.sorted()
        let drop = drops.isEmpty ? Float(0) : drops[drops.count / 2]
        let area = lowered.reduce(Float(0)) { $0 + $1.area }

        var centre: SIMD3<Float>?
        if !lowered.isEmpty {
            var sum = SIMD3<Float>(repeating: 0)
            var weight: Float = 0
            for item in lowered {
                sum += item.centre * item.area
                weight += item.area
            }
            if weight > 0 { centre = sum / weight }
        }

        let heightMM = mm(main - floor)
        let dropMM = mm(drop)

        return Profile(
            heightMM: heightMM,
            lowestClearMM: heightMM - dropMM,
            dropMM: dropMM,
            loweredAreaM2: Double(area),
            ceilingFaces: ceiling.count,
            loweredCentre: centre
        )
    }

    private func mm(_ meters: Float) -> Int { Int((meters * 1000).rounded()) }

    // MARK: - Экспорт

    /// OBJ с разбивкой на группы по классам: стены, пол, потолок отдельно.
    /// Открывается любым просмотрщиком — можно глазами проверить, что балка
    /// в данных есть, до того как писать её распознавание.
    func exportOBJ(to url: URL) throws {
        var text = "# Обмер — сырой меш лидара\n"
        text += "# треугольников: \(triangleCount)\n"

        var offsets: [Int] = []
        var running = 0
        for chunk in chunks {
            offsets.append(running)
            for vertex in chunk.vertices {
                text += "v \(vertex.x) \(vertex.y) \(vertex.z)\n"
            }
            running += chunk.vertices.count
        }

        for (category, name) in Self.classNames {
            var body = ""
            for (chunkIndex, chunk) in chunks.enumerated() {
                let offset = offsets[chunkIndex] + 1   // OBJ считает вершины с единицы
                for (faceIndex, face) in chunk.faces.enumerated() {
                    let value = faceIndex < chunk.classes.count ? chunk.classes[faceIndex] : 0
                    guard value == category else { continue }
                    body += "f \(Int(face.x) + offset) \(Int(face.y) + offset) \(Int(face.z) + offset)\n"
                }
            }
            if !body.isEmpty {
                text += "g \(name)\n" + body
            }
        }

        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Значения ARMeshClassification и латинские имена для групп OBJ.
    static let classNames: [(UInt8, String)] = [
        (1, "wall"), (2, "floor"), (3, "ceiling"),
        (4, "table"), (5, "seat"), (6, "window"), (7, "door"), (0, "none")
    ]

    static func label(for category: UInt8) -> String {
        switch category {
        case 1: return String(localized: "Стены")
        case 2: return String(localized: "Пол")
        case 3: return String(localized: "Потолок")
        case 4: return String(localized: "Столы")
        case 5: return String(localized: "Сиденья")
        case 6: return String(localized: "Окна")
        case 7: return String(localized: "Двери")
        default: return String(localized: "Не распознано")
        }
    }
}

// MARK: - Чтение буферов ARKit

private extension ARMeshGeometry {

    /// Вершины лежат упакованными по три Float. Читаем покомпонентно:
    /// SIMD3<Float> в Swift выровнен по 16 байтам, а в буфере шаг обычно 12,
    /// и приведение указателя к SIMD3 молча съезжает.
    func vertex(at index: Int) -> SIMD3<Float> {
        let pointer = vertices.buffer.contents()
            .advanced(by: vertices.offset + vertices.stride * index)
            .assumingMemoryBound(to: Float.self)
        return SIMD3<Float>(pointer[0], pointer[1], pointer[2])
    }

    func face(at index: Int) -> SIMD3<UInt32> {
        let pointer = faces.buffer.contents()
            .advanced(by: faces.bytesPerIndex * faces.indexCountPerPrimitive * index)
            .assumingMemoryBound(to: UInt32.self)
        return SIMD3<UInt32>(pointer[0], pointer[1], pointer[2])
    }
}
