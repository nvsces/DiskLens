import SwiftUI

struct DockerView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmRemove = false
    @State private var confirmPrune = false
    @State private var expanded: Set<String> = ["images", "containers", "volumes"]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            switch model.dockerState {
            case .unknown: loading
            case .notInstalled: message("Docker не установлен", "Раздел работает через docker CLI из Docker Desktop.", symbol: "shippingbox")
            case .daemonDown: daemonDown
            case .starting: message("Запускаю Docker Desktop…", "Демон обычно поднимается за 10–30 секунд.", symbol: "hourglass", spinner: true)
            case .ready:
                list
                Divider()
                actionBar
            }
        }
        .navigationTitle("Docker")
        .onAppear { if model.dockerState == .unknown { model.loadDocker() } }
        .alert("Ошибка docker", isPresented: Binding(get: { model.dockerError != nil }, set: { if !$0 { model.dockerError = nil } })) {
            Button("OK") { model.dockerError = nil }
        } message: { Text(model.dockerError ?? "") }
        .confirmationDialog("Удалить \(model.selectedDockerCount) объектов?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { model.removeSelectedDocker() }
            Button("Отмена", role: .cancel) {}
        } message: { Text(removeMessage) }
        .confirmationDialog("Очистить кэш сборки?", isPresented: $confirmPrune, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) { model.pruneDockerBuildCache() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Освободится \(formatBytes(model.docker.buildCacheUnused)). Следующая сборка образов пройдёт с нуля и займёт больше времени; образы и данные не затрагиваются.")
        }
    }

    // MARK: - Шапка и состояния

    private var toolbar: some View {
        HStack(spacing: 10) {
            if model.dockerState == .ready {
                Text("Занято \(formatBytes(model.docker.total))").font(.headline).monospacedDigit()
                Text("· можно освободить \(formatBytes(model.docker.imagesReclaimable + model.docker.volumesReclaimable + model.docker.buildCacheUnused)) · образы \(formatBytes(model.docker.imagesSize)) · тома \(formatBytes(model.docker.volumesSize)) · кэш сборки \(formatBytes(model.docker.buildCacheSize))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Образы, контейнеры, тома и кэш сборки Docker Desktop").foregroundStyle(.secondary)
            }
            Spacer()
            if model.isWorkingDocker {
                ProgressView().controlSize(.small)
                Text(model.dockerStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if model.dockerState == .ready {
                Button { model.loadDocker() } label: { Label("Обновить", systemImage: "arrow.clockwise") }
            }
        }
        .padding(12)
    }

    private var loading: some View {
        VStack(spacing: 12) { ProgressView().controlSize(.large); Text(model.dockerStatus).font(.headline) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var daemonDown: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox").font(.system(size: 46)).foregroundStyle(.tertiary)
            Text("Docker не запущен").font(.headline)
            Text("Содержимое Docker.raw знает только демон. Запустите Docker Desktop, чтобы увидеть разбивку по образам и томам.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack {
                Button("Запустить Docker Desktop") { model.startDocker() }.buttonStyle(.borderedProminent)
                Button("Проверить снова") { model.loadDocker() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private func message(_ title: String, _ text: String, symbol: String, spinner: Bool = false) -> some View {
        VStack(spacing: 12) {
            if spinner { ProgressView().controlSize(.large) } else {
                Image(systemName: symbol).font(.system(size: 46)).foregroundStyle(.tertiary)
            }
            Text(title).font(.headline)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    // MARK: - Список

    private var list: some View {
        List {
            section(id: "images", title: "Образы", count: model.docker.images.count, size: model.docker.imagesSize,
                    hint: "\(model.docker.images.filter { !$0.inUse }.count) без контейнеров") {
                ForEach(model.docker.images) { image in
                    ImageRow(image: image, selected: model.dockerSelection.contains(image.id))
                        .contentShape(Rectangle()).onTapGesture { toggle(image.id) }
                }
            }
            section(id: "containers", title: "Контейнеры", count: model.docker.containers.count, size: model.docker.containersSize,
                    hint: "\(model.docker.containers.filter(\.isRunning).count) запущено") {
                ForEach(model.docker.containers) { container in
                    ContainerRow(container: container, selected: model.dockerSelection.contains(container.id))
                        .contentShape(Rectangle()).onTapGesture { toggle(container.id) }
                }
            }
            section(id: "volumes", title: "Тома", count: model.docker.volumes.count, size: model.docker.volumesSize,
                    hint: "\(model.docker.volumes.filter { !$0.inUse }.count) не подключены") {
                ForEach(model.docker.volumes) { volume in
                    VolumeRow(volume: volume, selected: model.dockerSelection.contains(volume.id))
                        .contentShape(Rectangle()).onTapGesture { if !volume.inUse { toggle(volume.id) } }
                }
            }
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "hammer").foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Кэш сборки").font(.body.weight(.medium))
                        Text("\(model.docker.buildCacheEntries) записей · не используется \(formatBytes(model.docker.buildCacheUnused)) · пересоздаётся при сборке")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formatBytes(model.docker.buildCacheSize)).monospacedDigit().foregroundStyle(.secondary)
                    Button("Очистить") { confirmPrune = true }
                        .controlSize(.small).disabled(model.docker.buildCacheUnused == 0 || model.isWorkingDocker)
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.inset)
    }

    private func section<Content: View>(id: String, title: String, count: Int, size: Int64, hint: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        Section {
            if expanded.contains(id) { content() }
        } header: {
            HStack(spacing: 8) {
                Button { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } } label: {
                    Image(systemName: expanded.contains(id) ? "chevron.down" : "chevron.right").font(.caption).frame(width: 12)
                }.buttonStyle(.plain)
                Text(title).font(.headline).foregroundStyle(.primary)
                Text("\(count) · \(hint)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(formatBytes(size)).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            .textCase(nil)
        }
    }

    private func toggle(_ id: String) {
        if model.dockerSelection.contains(id) { model.dockerSelection.remove(id) } else { model.dockerSelection.insert(id) }
    }

    // MARK: - Нижняя панель

    private var actionBar: some View {
        VStack(spacing: 8) {
            if model.dockerFreed > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Освобождено около \(formatBytes(model.dockerFreed)). Docker.raw сожмётся сам через минуту-две.")
                        .font(.callout)
                    Spacer()
                }
                .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 12) {
                Menu("Выбрать") {
                    Button("Образы без контейнеров старше 30 дней") { model.selectUnusedDockerImages(days: 30) }
                    Button("Образы без контейнеров старше 90 дней") { model.selectUnusedDockerImages(days: 90) }
                    Button("Все образы без контейнеров") { model.selectUnusedDockerImages(days: -1) }
                    Divider()
                    Button("Остановленные контейнеры") { model.selectStoppedContainers() }
                    Button("Неподключённые тома") { model.selectUnusedVolumes() }
                }
                .fixedSize()
                Button("Снять выбор") { model.dockerSelection = [] }.disabled(model.dockerSelection.isEmpty)
                Spacer()
                if !model.dockerSelection.isEmpty {
                    Text("\(model.selectedDockerCount) выбрано · \(formatBytes(model.selectedDockerSize))")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Button { confirmRemove = true } label: { Label("Удалить", systemImage: "trash") }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(model.dockerSelection.isEmpty || model.isWorkingDocker)
            }
        }
        .padding(12)
    }

    private var removeMessage: String {
        var parts: [String] = []
        let images = model.selectedDockerImages, containers = model.selectedDockerContainers, volumes = model.selectedDockerVolumes
        if !images.isEmpty {
            parts.append("Образы (\(images.count)): нужный образ придётся скачать заново. Образы, которые держит контейнер, docker удалить откажется.")
        }
        if !containers.isEmpty {
            let running = containers.filter(\.isRunning).count
            parts.append("Контейнеры (\(containers.count)\(running > 0 ? ", из них \(running) запущено — будут остановлены" : "")): их записываемый слой пропадёт, тома останутся.")
        }
        if !volumes.isEmpty {
            parts.append("Тома (\(volumes.count)): ЭТО ДАННЫЕ — базы, загрузки, состояние. Восстановить будет нельзя.")
        }
        return "Освободится около \(formatBytes(model.selectedDockerSize)).\n\n" + parts.joined(separator: "\n")
    }
}

// MARK: - Строки

private func checkbox(_ selected: Bool, disabled: Bool = false) -> some View {
    Image(systemName: selected ? "checkmark.square.fill" : "square")
        .foregroundStyle(disabled ? Color.secondary.opacity(0.3) : selected ? Color.accentColor : .secondary)
}

private func tagBadge(_ text: String, _ color: Color) -> some View {
    Text(text).font(.caption2.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
}

struct ImageRow: View {
    let image: DockerImage
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            checkbox(selected)
            Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(image.title).lineLimit(1).truncationMode(.middle)
                    if image.inUse { tagBadge("Используется", .green) }
                    if image.isDangling { tagBadge("Без тега", .gray) }
                    if image.tags.count > 1 { tagBadge("+\(image.tags.count - 1) тег.", .blue) }
                }
                Text("создан \(image.createdAt.map { $0.formatted(.relative(presentation: .named)) } ?? image.createdSince)\(image.sharedSize > 0 ? " · общих слоёв \(formatBytes(image.sharedSize))" : "")")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(formatBytes(image.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .help(image.tags.joined(separator: "\n"))
    }
}

struct ContainerRow: View {
    let container: DockerContainer
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            checkbox(selected)
            Image(systemName: "cube").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(container.name)
                    tagBadge(container.isRunning ? "Запущен" : "Остановлен", container.isRunning ? .green : .gray)
                }
                Text("\(container.image) · \(container.status)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Text(formatBytes(container.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

struct VolumeRow: View {
    let volume: DockerVolume
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            checkbox(selected, disabled: volume.inUse)
            Image(systemName: "externaldrive").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(volume.title).lineLimit(1).truncationMode(.middle)
                    if volume.inUse { tagBadge("Подключён", .green) } else { tagBadge("Данные", .orange) }
                }
                Text(volume.inUse ? "используется контейнером — удалить нельзя" : "не подключён ни к одному контейнеру")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(formatBytes(volume.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .opacity(volume.inUse ? 0.6 : 1)
    }
}
