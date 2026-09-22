import SwiftUI
import RoomPlan

/// Обёртка, чтобы результат сканирования можно было положить в navigationDestination:
/// CapturedRoom сам по себе не Identifiable.
struct ScanResult: Identifiable, Hashable {
    let id = UUID()
    let room: CapturedRoom
    let mesh: MeshCapture

    // CapturedRoom не Hashable, поэтому сравниваем результаты по идентификатору.
    static func == (lhs: ScanResult, rhs: ScanResult) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ContentView: View {

    @State private var isScanning = false
    @State private var result: ScanResult?

    var body: some View {
        NavigationStack {
            Group {
                if RoomCaptureSession.isSupported {
                    startScreen
                } else {
                    unsupportedScreen
                }
            }
            .navigationTitle("Обмер")
            .navigationDestination(item: $result) { result in
                ResultsView(room: result.room, mesh: result.mesh)
            }
        }
        .fullScreenCover(isPresented: $isScanning) {
            ScanScreen(
                onFinish: { room, mesh in
                    isScanning = false
                    result = ScanResult(room: room, mesh: mesh)
                },
                onCancel: { isScanning = false }
            )
        }
    }

    private var startScreen: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "arkit")
                .font(.system(size: 68, weight: .light))
                .foregroundStyle(.tint)

            VStack(spacing: 10) {
                Text("Обмер помещения")
                    .font(.title2.weight(.semibold))
                Text("Обойдите комнату по периметру, направляя камеру на стены. Приложение построит стены, двери и окна с размерами.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    isScanning = true
                } label: {
                    Text("Начать сканирование")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.borderedProminent)

                Text("Снимите шторы с окон и по возможности отодвиньте мебель от стен — закрытые участки приложение достроит предположением.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private var unsupportedScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.orange)
            Text("Устройство не поддерживается")
                .font(.title3.weight(.semibold))
            Text("Для сканирования нужен LiDAR — он есть в iPhone Pro (12 Pro и новее) и iPad Pro с 2020 года.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
