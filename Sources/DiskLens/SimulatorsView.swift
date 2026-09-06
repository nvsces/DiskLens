import SwiftUI

struct SimulatorsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirm: PendingAction?

    enum PendingAction: Identifiable {
        case erase, delete, runtime(SimRuntime), keyboard(SimDevice)
        var id: String {
            switch self {
            case .erase: return "erase"
            case .delete: return "delete"
            case .runtime(let r): return "runtime-\(r.id)"
            case .keyboard(let d): return "keyboard-\(d.id)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.isLoadingSims && model.simGroups.isEmpty {
                loading
            } else if model.simGroups.isEmpty {
                empty
            } else {
                list
                Divider()
                actionBar
            }
        }
        .navigationTitle("Симуляторы")
        .onAppear { if model.simGroups.isEmpty { model.loadSimulators() } }
        .alert("Ошибка simctl", isPresented: Binding(get: { model.simError != nil }, set: { if !$0 { model.simError = nil } })) {
            Button("OK") { model.simError = nil }
        } message: { Text(model.simError ?? "") }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button(confirmButton, role: .destructive) {
                switch confirm {
                case .erase: model.applySimAction(delete: false)
                case .delete: model.applySimAction(delete: true)
                case .runtime(let r): model.deleteRuntime(r)
                case .keyboard(let d): model.clearKeyboardCache(d)
                case nil: break
                }
                confirm = nil
            }
            Button("Отмена", role: .cancel) { confirm = nil }
        } message: { Text(confirmMessage) }
    }

    // MARK: - Тулбар и состояния

    private var toolbar: some View {
        HStack(spacing: 10) {
            if model.simGroups.isEmpty {
                Text("Устройства и рантаймы CoreSimulator").foregroundStyle(.secondary)
            } else {
                Text("Занято \(formatBytes(model.simTotalSize))").font(.headline).monospacedDigit()
                Text("· все операции через simctl, реестр Xcode остаётся согласованным")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isWorkingSims {
                ProgressView().controlSize(.small)
                Text(model.simStatus).font(.caption).foregroundStyle(.secondary)
            } else {
                Button { model.loadSimulators() } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                    .disabled(model.isLoadingSims)
            }
        }
        .padding(12)
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Опрашиваю simctl…").font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.slash").font(.system(size: 46)).foregroundStyle(.tertiary)
            Text("Симуляторы не найдены").font(.headline)
            Text("Нужен установленный Xcode с инструментами командной строки.")
                .foregroundStyle(.secondary)
            Button("Проверить снова") { model.loadSimulators() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Список

    private var list: some View {
        List {
            ForEach(model.simGroups) { group in
                Section {
                    ForEach(group.devices) { device in
                        DeviceRow(device: device, selected: model.simSelection.contains(device.id))
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(device.id) }
                            .contextMenu {
                                Button("Открыть в Папках") { model.exploreSimulator(device) }
                                Button("Показать в Finder") {
                                    model.reveal(URL(fileURLWithPath: device.dataPath).deletingLastPathComponent())
                                }
                                if device.keyboardCacheSize > 0 {
                                    Divider()
                                    Button("Удалить кэш клавиатуры (\(formatBytes(device.keyboardCacheSize)))") {
                                        confirm = .keyboard(device)
                                    }
                                }
                            }
                    }
                    ForEach(group.runtimes) { runtime in
                        RuntimeRow(runtime: runtime,
                                   isDuplicate: group.duplicateRuntimes.contains { $0.id == runtime.id },
                                   devicesCount: group.devices.count) {
                            confirm = .runtime(runtime)
                        }
                    }
                } header: {
                    HStack {
                        Text(group.title).font(.headline).foregroundStyle(.primary)
                        Spacer()
                        Text("устройства \(formatBytes(group.devicesSize)) · рантайм \(formatBytes(group.runtimeSize))")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Button(allSelected(group) ? "Снять" : "Выбрать с данными") {
                            let ids = group.devices.filter { !$0.isStub }.map(\.id)
                            if allSelected(group) { ids.forEach { model.simSelection.remove($0) } }
                            else { model.simSelection.formUnion(ids) }
                        }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.inset)
    }

    private func allSelected(_ group: SimGroup) -> Bool {
        let withData = group.devices.filter { !$0.isStub }
        return !withData.isEmpty && withData.allSatisfy { model.simSelection.contains($0.id) }
    }

    private func toggle(_ id: String) {
        if model.simSelection.contains(id) { model.simSelection.remove(id) } else { model.simSelection.insert(id) }
    }

    // MARK: - Нижняя панель

    private var actionBar: some View {
        VStack(spacing: 8) {
            if model.simFreed > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Освобождено \(formatBytes(model.simFreed))").font(.callout.weight(.medium))
                    Spacer()
                }
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 12) {
                Menu("Неиспользуемые") {
                    Button("Дольше 30 дней") { model.selectStaleSimulators(days: 30) }
                    Button("Дольше 90 дней") { model.selectStaleSimulators(days: 90) }
                    Button("Все с данными") { model.selectStaleSimulators(days: -1) }
                }
                .fixedSize()
                Button("Снять выбор") { model.simSelection = [] }.disabled(model.simSelection.isEmpty)
                Button("Недоступные") { model.deleteUnavailableSimulators() }
                    .help("Устройства, чей рантайм уже удалён")

                Spacer()

                if !model.simSelection.isEmpty {
                    Text("\(model.simSelection.count) выбрано · \(formatBytes(model.selectedSimSize))")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Button { confirm = .erase } label: { Label("Стереть", systemImage: "eraser") }
                    .disabled(model.simSelection.isEmpty || model.isWorkingSims)
                    .help("Устройство остаётся, данные приложений удаляются. Самый безопасный вариант.")
                Button { confirm = .delete } label: { Label("Удалить", systemImage: "trash") }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(model.simSelection.isEmpty || model.isWorkingSims)
            }
        }
        .padding(12)
    }

    // MARK: - Тексты подтверждений

    private var confirmTitle: String {
        switch confirm {
        case .erase: return "Стереть содержимое \(model.simSelection.count) устройств?"
        case .delete: return "Удалить \(model.simSelection.count) устройств?"
        case .runtime(let r): return "Удалить рантайм \(r.title)?"
        case .keyboard(let d): return "Удалить кэш клавиатуры у \(d.name)?"
        case nil: return ""
        }
    }

    private var confirmButton: String {
        switch confirm {
        case .erase: return "Стереть"
        case .delete: return "Удалить"
        case .runtime: return "Удалить рантайм"
        case .keyboard: return "Удалить кэш"
        case nil: return ""
        }
    }

    private var confirmMessage: String {
        switch confirm {
        case .erase:
            return "Освободится \(formatBytes(model.selectedSimSize)). Устройства останутся в Xcode как новые: приложения, настройки и данные внутри них будут удалены. Запущенные симуляторы будут выключены."
        case .delete:
            return "Освободится \(formatBytes(model.selectedSimSize)). Устройства исчезнут из Xcode. Если нужна та же модель — Xcode создаст её заново за секунды, рантайм не затрагивается."
        case .runtime(let r):
            let count = model.simGroups.first { $0.id == r.runtimeIdentifier }?.devices.filter { !$0.isStub }.count ?? 0
            let warn = count > 0 ? " \(count) устройств с данными на этом рантайме перестанут запускаться — сначала удалите их." : ""
            return "Освободится \(formatBytes(r.size)). Чтобы снова тестировать на \(r.platform) \(r.version), образ придётся скачать в Xcode заново.\(warn)"
        case .keyboard(let d):
            return "Освободится \(formatBytes(d.keyboardCacheSize)). Это превью клавиатуры, которые симулятор пересоздаёт по мере надобности — приложения и их данные не затрагиваются. Запущенный симулятор будет выключен."
        case nil: return ""
        }
    }
}

struct DeviceRow: View {
    let device: SimDevice
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            Image(systemName: device.deviceType.contains("iPad") ? "ipad" : device.deviceType.contains("Watch") ? "applewatch" : "iphone")
                .foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(device.name)
                    if device.isBooted { badge("Запущен", .green) }
                    if !device.isAvailable { badge("Недоступен", .red) }
                    if device.isStub { badge("Пустая заготовка", .gray) }
                    if device.keyboardCacheSize > 1024 * 1024 * 1024 {
                        badge("Кэш клавиатуры \(formatBytes(device.keyboardCacheSize))", .orange)
                    }
                }
                Text(device.lastBooted.map { "запускался \($0.formatted(.relative(presentation: .named)))" } ?? "ни разу не запускался")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(formatBytes(device.size)).monospacedDigit()
                .foregroundStyle(device.isStub ? .tertiary : .secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .opacity(device.isStub ? 0.6 : 1)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}

struct RuntimeRow: View {
    let runtime: SimRuntime
    let isDuplicate: Bool
    let devicesCount: Int
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "opticaldisc").foregroundStyle(.secondary).frame(width: 16)
                .padding(.leading, 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Рантайм \(runtime.title)")
                    if isDuplicate {
                        Text("Старый билд, не используется").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule()).foregroundStyle(.orange)
                    }
                }
                Text(runtime.lastUsed.map { "использовался \($0.formatted(.relative(presentation: .named)))" } ?? "")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(formatBytes(runtime.size)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Button("Удалить", role: .destructive, action: onDelete)
                .disabled(!runtime.deletable)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}
