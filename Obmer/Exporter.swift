import Foundation
import RoomPlan

/// Сохранение результата на диск.
/// USDZ в режиме .parametric — это стены, двери и окна как объекты с размерами,
/// а не сплошная сетка. Именно из него дальше будет собираться IFC для ArchiCAD.
enum Exporter {

    static func usdz(_ room: CapturedRoom, name: String) throws -> URL {
        let url = directory().appendingPathComponent("\(name).usdz")
        try? FileManager.default.removeItem(at: url)
        try room.export(to: url, exportOptions: .parametric)
        return url
    }

    /// Полный дамп модели: пригодится для отладки солвера и для бэкенда.
    static func json(_ room: CapturedRoom, name: String) throws -> URL {
        let url = directory().appendingPathComponent("\(name).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(room)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Сырой меш лидара в OBJ, с разбивкой на группы по классам.
    /// Открывается штатным просмотрщиком: можно глазами убедиться, что балка
    /// и скосы откосов в данных есть, прежде чем писать их распознавание.
    static func obj(_ mesh: MeshCapture, name: String) throws -> URL {
        let url = directory().appendingPathComponent("\(name).obj")
        try? FileManager.default.removeItem(at: url)
        try mesh.exportOBJ(to: url)
        return url
    }

    static func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return String(localized: "Обмер") + "_" + formatter.string(from: Date())
    }

    private static func directory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Сканы", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
