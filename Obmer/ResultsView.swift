import SwiftUI
import RoomPlan

struct ResultsView: View {

    let room: CapturedRoom
    @ObservedObject var mesh: MeshCapture

    @State private var usdzURL: URL?
    @State private var jsonURL: URL?
    @State private var objURL: URL?
    @State private var correctionsURL: URL?
    @State private var exportError: String?
    @State private var isToppingUp = false
    @State private var isMeasuring = false
    @State private var refining: MeasuredItem?
    @State private var target: MeasureTarget?

    private var summary: RoomSummary { RoomSummary(room: room, mesh: mesh) }

    var body: some View {
        List {
            Section("Помещение") {
                row("Периметр", String(localized: "\(summary.perimeterMM) мм"))
                row("Высота потолка", String(localized: "\(summary.ceilingHeightMM) мм"))
                row("Габаритная площадь", String(format: String(localized: "%.2f м²"), summary.boundingAreaM2))
            }

            if !summary.completenessIssues.isEmpty {
                Section {
                    ForEach(summary.completenessIssues, id: \.self) { issue in
                        Label {
                            Text(verbatim: issue)
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.octagon.fill")
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Обмер похож на незавершённый")
                } footer: {
                    Text("Размеры ниже показаны как есть, но полагаться на них нельзя. Просканируйте помещение целиком: обойдите по периметру и ведите камерой по стенам снизу вверх.")
                }
            }

            if summary.lowConfidenceCount > 0 {
                Section {
                    Label(
                        "\(summary.lowConfidenceCount) элем. измерены с низкой достоверностью — проверьте их вручную перед использованием.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(summary.walls) { item in
                    measuredRow(item)
                }
            } header: {
                Text("Стены — \(summary.walls.count)")
            } footer: {
                Text("Длины по лидару: плоскость стены строится по видимой части, а углы достраиваются пересечением с соседними стенами — поэтому мебель в углу больше не укорачивает стену. Где лидару не хватило данных, размер помечен как приблизительный.")
            }

            if !summary.openings.isEmpty {
                Section {
                    ForEach(summary.openings) { item in
                        measuredRow(item)
                    }
                } header: {
                    Text("Проёмы — \(summary.openings.count)")
                } footer: {
                    if summary.openings.contains(where: { $0.offsets != nil }) {
                        Text("«От углов» — расстояния от концов стены до краёв проёма. Считаются автоматически: углы строит солвер стен, положение проёма даёт RoomPlan. Вместе с шириной они должны сойтись с длиной стены.")
                    }
                }
            }

            lidarSection

            Section {
                Button {
                    isToppingUp = true
                } label: {
                    Label("Доснять помещение", systemImage: "camera.viewfinder")
                }
                Button {
                    isMeasuring = true
                } label: {
                    Label("Промерить вручную", systemImage: "ruler")
                }
            } footer: {
                Text("«Доснять» — вернуться в камеру и добавить то, что не попало в обход; размеры пересчитаются. «Промерить» — замерить расстояние между двумя точками лидаром: дверные проёмы, балку за шкафом и всё, что автоматика не разобрала.")
            }

            Section("Экспорт") {
                if let usdzURL {
                    ShareLink(item: usdzURL) {
                        Label("Модель USDZ (параметрическая)", systemImage: "square.and.arrow.up")
                    }
                }
                if let jsonURL {
                    ShareLink(item: jsonURL) {
                        Label("Размеры JSON", systemImage: "curlybraces")
                    }
                }
                if let objURL {
                    ShareLink(item: objURL) {
                        Label("Сырой меш OBJ", systemImage: "cube.transparent")
                    }
                }
                if let correctionsURL {
                    ShareLink(item: correctionsURL) {
                        Label("Ручные уточнения", systemImage: "ruler")
                    }
                }
                if let exportError {
                    Text(verbatim: exportError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Text("Габаритная площадь считается по описанному прямоугольнику и для непрямоугольных комнат завышена. Точный контур появится вместе с уточнением размеров.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Результат")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $isToppingUp) {
            TopUpScreen(mesh: mesh) { isToppingUp = false }
        }
        .fullScreenCover(isPresented: $isMeasuring) {
            MeasureScreen(mesh: mesh) { isMeasuring = false }
        }
        .fullScreenCover(item: $target) { chosen in
            MeasureScreen(mesh: mesh, target: chosen) { target = nil }
        }
        .confirmationDialog(refining?.name ?? "", isPresented: .init(
            get: { refining != nil },
            set: { if !$0 { refining = nil } }
        ), titleVisibility: .visible) {
            if let item = refining {
                Button("Уточнить ширину промером") {
                    target = MeasureTarget(element: item.id, kind: .width,
                                           title: String(localized: "\(item.name), ширина"))
                    refining = nil
                }
                Button("Уточнить высоту промером") {
                    target = MeasureTarget(element: item.id, kind: .height,
                                           title: String(localized: "\(item.name), высота"))
                    refining = nil
                }
                if item.isCorrected {
                    Button("Убрать уточнение", role: .destructive) {
                        CorrectionStore.shared.remove(for: item.id, .width)
                        CorrectionStore.shared.remove(for: item.id, .height)
                        refining = nil
                    }
                }
                Button("Отмена", role: .cancel) { refining = nil }
            }
        } message: {
            Text("Замер заменит размер этого элемента в обмере и в экспорте.")
        }
        .onChange(of: mesh.revision) { _, _ in
            Task { await export() }
        }
        .onChange(of: CorrectionStore.shared.items.count) { _, _ in
            Task { await export() }
        }
        .onDisappear { mesh.pause() }
        .task { await export() }
    }

    /// Что удалось снять с лидара помимо прямоугольников RoomPlan.
    /// Высота здесь считается по потолку, а не по стенам, поэтому показывает
    /// балки и короба — то, для чего в модели RoomPlan нет категории.
    @ViewBuilder
    private var lidarSection: some View {
        if mesh.isEmpty {
            Section {
                Label(
                    "Сырая поверхность не записалась: sceneReconstruction не включился. Размеры ниже — только от RoomPlan.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            } header: {
                Text("Лидар")
            }
        } else {
            Section {
                row("Треугольников", String(localized: "\(mesh.triangleCount)"))

                ForEach(sortedFaceCounts, id: \.0) { category, count in
                    row(LocalizedStringKey(MeshCapture.label(for: category)), String(localized: "\(count)"))
                }

                if let profile = mesh.profile() {
                    row("Высота по потолку", String(localized: "\(profile.heightMM) мм"))

                    switch profile.verdict {
                    case .beam:
                        row("Под балкой", String(localized: "\(profile.lowestClearMM) мм"))
                        Label(
                            "Потолок опускается на \(profile.dropMM) мм \(Self.place(summary.loweredNearWall)). Балка или короб, площадь \(Self.area(profile.loweredAreaM2)) м². RoomPlan такое не показывает.",
                            systemImage: "arrow.down.to.line"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)

                    case .tooLittleData:
                        // Понижение посчитано по клочку потолка — такое число
                        // выглядит уверенно и при этом может врать на 70 мм.
                        Label(
                            "Похоже на понижение потолка на \(profile.dropMM) мм, но снято всего \(Self.area(profile.loweredAreaM2)) м² — этого мало. Нажмите «Доснять» и проведите камерой по потолку \(Self.place(summary.loweredNearWall)).",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)

                    case .notABeam:
                        Label(
                            "Потолок разной высоты на площади \(Self.area(profile.loweredAreaM2)) м² — это уже не балка, а другой уровень или соседнее помещение в скане. Высота по помещению недостоверна.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.red)

                    case .flat:
                        Text("Потолок ровный: понижений не найдено.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Пол и потолок размечены слишком редко, чтобы считать высоту по мешу.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Лидар — сырая поверхность")
            } footer: {
                Text("Меш сохраняет то, что RoomPlan выбрасывает: балки, скосы откосов, кривизну стен. Выгрузите OBJ, чтобы посмотреть поверхность целиком.")
            }
        }
    }

    /// Файлы переписываются после каждой досъёмки: иначе выгрузишь обмер,
    /// который уже не совпадает с тем, что на экране.
    private func export() async {
        let name = Exporter.defaultName()
        do {
            usdzURL = try Exporter.usdz(room, name: name)
            jsonURL = try Exporter.json(room, name: name)
            if !mesh.isEmpty {
                objURL = try Exporter.obj(mesh, name: name)
            }
            correctionsURL = try Exporter.corrections(name: name)
        } catch {
            exportError = String(localized: "Не удалось сохранить файл: \(error.localizedDescription)")
        }
    }

    private static func place(_ wall: String?) -> String {
        guard let wall else { return String(localized: "в помещении") }
        return String(localized: "рядом с элементом «\(wall)» в списке ниже")
    }

    private static func area(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private var sortedFaceCounts: [(UInt8, Int)] {
        mesh.faceCounts()
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func measuredRow(_ item: MeasuredItem) -> some View {
        Button { refining = item } label: { rowBody(item) }
            .buttonStyle(.plain)
    }

    private func rowBody(_ item: MeasuredItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                if item.isCorrected {
                    Text("уточнено вручную")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if item.isApproximate {
                    Text("приблизительно — лидар не построил, размер от RoomPlan")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text("достоверность: \(item.confidence.localizedLabel)")
                        .font(.caption2)
                        .foregroundStyle(item.confidence == .low ? .orange : .secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.dimensions)
                    .foregroundStyle(item.isCorrected ? .green : (item.isApproximate ? .orange : .secondary))
                    .monospacedDigit()

                if let offsets = item.offsets {
                    Text(verbatim: offsets)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if let byMesh = item.byMesh {
                    Text("по лидару \(byMesh)")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .monospacedDigit()

                    if let coverage = item.meshCoverage, coverage < 0.5 {
                        Text("проём просканирован не целиком")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}
