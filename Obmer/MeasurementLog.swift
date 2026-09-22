import Foundation

/// Журнал ручных промеров.
///
/// Раньше замер жил только на экране: закрыл режим — и числа нет.
/// Для обмера это никуда не годится, их переписывают на бумажку и теряют.
/// Теперь каждый промер сразу ложится на диск, рядом со сканами.
enum MeasurementLog {

    static func record(_ millimetres: Int) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date()))\t\(millimetres)\n"
        append(line)
    }

    static func url() -> URL {
        directory().appendingPathComponent("Промеры.txt")
    }

    static func contents() -> String {
        (try? String(contentsOf: url(), encoding: .utf8)) ?? ""
    }

    private static func append(_ line: String) {
        let target = url()
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: target) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            let header = "# Ручные промеры лидаром, миллиметры\n"
            try? (header + line).write(to: target, atomically: true, encoding: .utf8)
        }
    }

    private static func directory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Сканы", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
