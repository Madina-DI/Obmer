import SwiftUI
import RoomPlan

/// Полноэкранный режим сканирования с кнопками поверх камеры.
struct ScanScreen: View {

    let onFinish: (CapturedRoom, MeshCapture) -> Void
    let onCancel: () -> Void

    @StateObject private var controller = ScanController(mesh: MeshCapture())

    var body: some View {
        ZStack(alignment: .bottom) {
            RoomScannerView(controller: controller)
                .ignoresSafeArea()

            controls
        }
        .onAppear {
            controller.onFinish = onFinish
            controller.start()
        }
        .overlay(alignment: .top) { statusBar }
    }

    @ViewBuilder
    private var statusBar: some View {
        switch controller.phase {
        case .scanning:
            banner(MeshProgressLabel(mesh: controller.mesh))
        case .processing:
            banner(Label("Считаю модель…", systemImage: "gearshape.2"))
        case .failed(let message):
            // Текст системной ошибки уже переведён iOS — выводим как есть.
            banner(
                Label {
                    Text(verbatim: message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                },
                tint: .orange
            )
        case .idle:
            EmptyView()
        }
    }

    private func banner<Content: View>(_ label: Content, tint: Color = .white) -> some View {
        label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.top, 8)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button("Отмена") {
                controller.cancel()
                onCancel()
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 52)
            .background(.black.opacity(0.45), in: Capsule())

            Button {
                controller.stop()
            } label: {
                Text("Готово")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.phase != .scanning)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
    }
}


/// Счётчик треугольников поверх камеры.
/// Вынесен в отдельный вид, потому что MeshCapture — самостоятельный
/// ObservableObject: наблюдения за ScanController для его обновлений мало.
private struct MeshProgressLabel: View {

    @ObservedObject var mesh: MeshCapture

    var body: some View {
        if mesh.isReceivingMesh {
            Label("Обойдите комнату · лидар \(mesh.liveTriangleCount) тр.", systemImage: "figure.walk")
        } else {
            Label("Обойдите комнату по периметру", systemImage: "figure.walk")
        }
    }
}
