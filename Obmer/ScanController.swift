import ARKit
import Foundation
import RoomPlan

/// Состояние сеанса сканирования и мост к RoomCaptureView.
/// Все методы вызываются с главного потока: делегат RoomPlan приходит именно туда.
final class ScanController: ObservableObject {

    enum Phase: Equatable {
        case idle          // вид создан, съёмка ещё не запущена
        case scanning      // идёт обход комнаты
        case processing    // RoomPlan считает модель после остановки
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Вызывается, когда RoomPlan отдал готовую модель комнаты.
    /// Вместе с ней уходит и сырой меш: параметрическая модель теряет
    /// балки, скосы и кривизну, а меш их сохраняет.
    var onFinish: ((CapturedRoom, MeshCapture) -> Void)?

    /// Меш и сессия ARKit, на которой он собирается. Сессия принадлежит
    /// MeshCapture, чтобы пережить закрытие этого экрана: после обхода
    /// досъёмка должна идти в той же системе координат.
    let mesh: MeshCapture
    var arSession: ARSession { mesh.session }

    init(mesh: MeshCapture) {
        self.mesh = mesh
    }

    private weak var captureView: RoomCaptureView?
    private var meshPoll: Timer?
    private var didRetryConfiguration = false

    func attach(_ view: RoomCaptureView) {
        captureView = view
    }

    func start() {
        guard phase == .idle, let captureView else { return }
        arSession.delegate = mesh
        applyMeshConfiguration()
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        phase = .scanning
        startMeshPoll()
    }

    func stop() {
        guard phase == .scanning else { return }
        phase = .processing
        stopMeshPoll()
        // pauseARSession: false — сеанс ARKit должен пережить остановку RoomPlan,
        // иначе буферы анкоров освободятся раньше, чем мы снимем с них копию.
        captureView?.captureSession.stop(pauseARSession: false)
    }

    func cancel() {
        stopMeshPoll()
        captureView?.captureSession.stop(pauseARSession: false)
        arSession.pause()
        phase = .idle
    }

    func finish(with room: CapturedRoom) {
        mesh.snapshot()
        // Сессию не останавливаем: с экрана результата можно вернуться
        // и доснять то, чего не хватило.
        onFinish?(room, mesh)
    }

    func fail(_ error: Error) {
        stopMeshPoll()
        phase = .failed(error.localizedDescription)
    }

    // MARK: - Меш

    private func applyMeshConfiguration() {
        // Без options: перезапуск конфигурации не должен сбрасывать трекинг,
        // иначе RoomPlan потеряет уже собранную часть комнаты.
        arSession.run(mesh.makeConfiguration())
    }

    /// RoomPlan запускает сеанс своей конфигурацией и может забрать делегата себе.
    /// Поэтому анкоры дублируются опросом кадра, а если меш так и не пошёл —
    /// конфигурация накатывается ещё раз, уже поверх запущенного RoomPlan.
    private func startMeshPoll() {
        meshPoll?.invalidate()
        let started = Date()
        meshPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let anchors = self.arSession.currentFrame?.anchors {
                self.mesh.absorb(anchors)
            }
            if !self.mesh.isReceivingMesh,
               !self.didRetryConfiguration,
               Date().timeIntervalSince(started) > 3 {
                self.didRetryConfiguration = true
                self.applyMeshConfiguration()
            }
        }
    }

    private func stopMeshPoll() {
        meshPoll?.invalidate()
        meshPoll = nil
    }
}
