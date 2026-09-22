import SwiftUI
import RoomPlan

/// RoomCaptureView — готовый экран сканирования от Apple: картинка с камеры,
/// подсказки и контур комнаты, который достраивается на глазах.
/// Здесь он завёрнут в SwiftUI и посажен на нашу сессию ARKit,
/// чтобы параллельно с прямоугольниками RoomPlan сохранялся сырой меш лидара.
struct RoomScannerView: UIViewRepresentable {

    let controller: ScanController

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero, arSession: controller.arSession)
        view.delegate = context.coordinator
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}

    func makeCoordinator() -> ScanCoordinator {
        ScanCoordinator(controller: controller)
    }
}

/// Приёмник событий RoomPlan.
/// Вынесен на верхний уровень намеренно: RoomCaptureViewDelegate наследует NSCoding,
/// а вложенный в структуру класс не имеет стабильного имени для Objective-C.
final class ScanCoordinator: NSObject, RoomCaptureViewDelegate {

    private let controller: ScanController

    init(controller: ScanController) {
        self.controller = controller
        super.init()
    }

    /// Пользователь остановил съёмку. true — просим RoomPlan обработать данные
    /// и показать итоговую модель прямо в этом же виде.
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error {
            controller.fail(error)
            return false
        }
        return true
    }

    /// Готовая параметрическая модель: стены, двери, окна, проёмы с размерами.
    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error {
            controller.fail(error)
            return
        }
        controller.finish(with: processedResult)
    }

    // MARK: - NSCoding
    // RoomCaptureViewDelegate наследует NSCoding, но координатор никогда
    // не архивируется — это обязательные заглушки, как в примерах Apple.

    required init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {}
}
