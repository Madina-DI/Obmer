import Foundation

/// Ручные уточнения размеров.
///
/// Ради этого промер и существует. Отдельное число, как в эппловской рулетке,
/// для проекта бесполезно: его всё равно переписывать руками. Здесь замер
/// заменяет собой неверный размер конкретного элемента и дальше едет вместе
/// с обмером — в список, в экспорт, на план.
struct Correction: Codable, Identifiable {

    enum Kind: String, Codable {
        case width, height
        /// Расстояние от угла до края проёма — для планировки оно нужнее ширины.
        case offset
    }

    let id: UUID
    /// Элемент RoomPlan, к которому относится уточнение.
    let element: UUID
    let kind: Kind
    let millimetres: Int
    let recordedAt: Date
}

@MainActor
final class CorrectionStore: ObservableObject {

    static let shared = CorrectionStore()

    @Published private(set) var items: [Correction] = []

    private init() { items = load() }

    func value(for element: UUID, _ kind: Correction.Kind) -> Int? {
        items.last { $0.element == element && $0.kind == kind }?.millimetres
    }

    func set(_ millimetres: Int, for element: UUID, _ kind: Correction.Kind) {
        items.removeAll { $0.element == element && $0.kind == kind }
        items.append(Correction(id: UUID(), element: element, kind: kind,
                                millimetres: millimetres, recordedAt: Date()))
        save()
    }

    func remove(for element: UUID, _ kind: Correction.Kind) {
        items.removeAll { $0.element == element && $0.kind == kind }
        save()
    }

    // MARK: - Хранение
    // Уточнения живут в пределах одного обмера: RoomPlan выдаёт элементам
    // новые идентификаторы на каждом скане, и перенести их на следующий
    // обход без сопоставления по геометрии нельзя. На диск пишем ради
    // экспорта и чтобы не потерять при закрытии приложения.

    private static let fileName = "Уточнения.json"

    private func url() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Сканы", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(Self.fileName)
    }

    private func load() -> [Correction] {
        guard let data = try? Data(contentsOf: url()) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Correction].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(items).write(to: url(), options: .atomic)
    }
}
