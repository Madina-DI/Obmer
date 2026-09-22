import ARKit
import SwiftUI

/// Досъёмка: возврат в камеру после того, как обмер уже показан.
///
/// Нужна потому, что предупреждение «здесь данных не хватило» бесполезно,
/// если по нему нельзя ничего сделать. Сессия ARKit с первого обхода не
/// останавливалась, поэтому новый меш ложится в ту же систему координат
/// и просто дополняет старый.
struct TopUpScreen: View {

    @ObservedObject var mesh: MeshCapture
    let onFinish: () -> Void

    @State private var startedAt = Date()

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraView(session: mesh.session)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Text("Доснято \(mesh.liveTriangleCount - startTriangles) треугольников")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.55), in: Capsule())

                Button {
                    mesh.snapshot()
                    onFinish()
                } label: {
                    Text("Готово")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 28)
        }
        .overlay(alignment: .top) {
            Text("Ведите камерой по тому месту, где данных не хватило. Держитесь в полутора-двух метрах от поверхности.")
                .font(.footnote)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(12)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)
                .padding(.top, 8)
        }
        .onAppear {
            startTriangles = mesh.liveTriangleCount
            mesh.resume()
        }
    }

    @State private var startTriangles = 0
}

/// Картинка с камеры поверх уже запущенной сессии.
/// Своей сессии не заводит намеренно: новая означала бы новую систему
/// координат и несовместимый меш.
private struct CameraView: UIViewRepresentable {

    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = true
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
