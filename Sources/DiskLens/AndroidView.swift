import SwiftUI

struct AndroidView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirm: AppModel.AndroidAction?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !model.androidInstalled {
                empty("Android SDK не найден", "Ожидался в ~/Library/Android/sdk или по ANDROID_HOME.")
            } else if !model.androidLoaded {
                VStack(spacing: 12) { ProgressView().controlSize(.large); Text(model.androidStatus).font(.headline) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
                Divider()
                actionBar
            }
        }
        .navigationTitle("Android")
        .onAppear { if !model.androidLoaded { model.loadAndroid() } }
        .alert("Ошибка", isPresented: Binding(get: { model.androidError != nil }, set: { if !$0 { model.androidError = nil } })) {
            Button("OK") { model.androidError = nil }
        } message: { Text(model.androidError ?? "") }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button(confirmButton, role: .destructive) { if let c = confirm { model.applyAndroidAction(c) }; confirm = nil }
            Button("Отмена", role: .cancel) { confirm = nil }
        } message: { Text(confirmMessage) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if model.androidLoaded {
                Text("Занято \(formatBytes(model.android.total))").font(.headline).monospacedDigit()
                Text("· устройства \(formatBytes(model.android.avdsSize)) · SDK-пакеты \(formatBytes(model.android.packagesSize))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if model.android.emulatorRunning {
                    Text("Эмулятор запущен").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.15), in: Capsule()).foregroundStyle(.green)
                }
            } else {
                Text("Эмуляторы Android, системные образы и версии SDK").foregroundStyle(.secondary)
            }
            Spacer()
            if model.isWorkingAndroid {
                ProgressView().controlSize(.small)
                Text(model.androidStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Button { model.loadAndroid() } label: { Label("Обновить", systemImage: "arrow.clockwise") }
            }
        }
        .padding(12)
    }

    private func empty(_ title: String, _ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "smartphone").font(.system(size: 46)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Список

    private var list: some View {
        List {
            Section {
                ForEach(model.android.avds) { avd in
                    AVDRow(avd: avd, selected: model.androidSelection.contains(avd.id))
                        .contentShape(Rectangle()).onTapGesture { toggle(avd.id) }
                        .contextMenu {
                            Button("Открыть в Папках") { model.tab = .explorer; model.startScan(path: avd.path) }
                            Button("Показать в Finder") { model.reveal(URL(fileURLWithPath: avd.path)) }
                        }
                }
                if model.android.avds.isEmpty {
                    Text("Виртуальных устройств нет").font(.caption).foregroundStyle(.tertiary)
                }
            } header: {
                header("Виртуальные устройства", count: model.android.avds.count, size: model.android.avdsSize,
                       hint: "данные и снапшоты эмулятора")
            }

            ForEach(AndroidPackage.Kind.allCases, id: \.self) { kind in
                let packages = model.android.packages(of: kind)
                if !packages.isEmpty {
                    Section {
                        ForEach(packages) { package in
                            PackageRow(package: package, selected: model.androidSelection.contains(package.id))
                                .contentShape(Rectangle()).onTapGesture { if !package.inUse { toggle(package.id) } }
                                .contextMenu { Button("Показать в Finder") { model.reveal(URL(fileURLWithPath: package.path)) } }
                        }
                    } header: {
                        header(kind.rawValue, count: packages.count, size: packages.reduce(0) { $0 + $1.size }, hint: hint(for: kind))
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func header(_ title: String, count: Int, size: Int64, hint: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.headline).foregroundStyle(.primary)
            Text("\(count) · \(hint)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(formatBytes(size)).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
        .textCase(nil)
    }

    private func hint(for kind: AndroidPackage.Kind) -> String {
        switch kind {
        case .systemImage: return "нужны только те, на которых есть AVD"
        case .ndk: return "Gradle берёт версию из проекта; остальные — мёртвый груз"
        case .buildTools: return "обычно достаточно самой новой"
        case .platform: return "compileSdk проектов; старые редко нужны"
        case .sources: return "исходники для навигации в IDE"
        case .cmake: return "нативные сборки"
        }
    }

    private func toggle(_ id: String) {
        if model.androidSelection.contains(id) { model.androidSelection.remove(id) } else { model.androidSelection.insert(id) }
    }

    // MARK: - Нижняя панель

    private var actionBar: some View {
        let hasAVDs = !model.selectedAVDs.isEmpty
        let hasPackages = !model.selectedAndroidPackages.isEmpty
        return VStack(spacing: 8) {
            if model.androidFreed > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Освобождено \(formatBytes(model.androidFreed))").font(.callout.weight(.medium))
                    Spacer()
                }
                .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 12) {
                Button("Выбрать устаревшее") { model.selectOldAndroidVersions() }
                    .help("Все версии NDK, build-tools, platforms кроме самой новой; образы без AVD; остатки загрузок")
                Button("Снять выбор") { model.androidSelection = [] }.disabled(model.androidSelection.isEmpty)
                Spacer()
                if !model.androidSelection.isEmpty {
                    Text("\(model.androidSelection.count) выбрано · \(formatBytes(model.selectedAndroidSize))")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Button { confirm = .deleteSnapshots } label: { Label("Снапшоты", systemImage: "camera") }
                    .disabled(!hasAVDs || model.isWorkingAndroid)
                    .help("Удалить только снимки состояния выбранных устройств")
                Button { confirm = .wipeData } label: { Label("Сбросить", systemImage: "eraser") }
                    .disabled(!hasAVDs || model.isWorkingAndroid)
                    .help("Wipe Data: устройство остаётся, данные приложений удаляются")
                Button { confirm = .delete } label: { Label("Удалить", systemImage: "trash") }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(!(hasAVDs || hasPackages) || model.isWorkingAndroid)
            }
        }
        .padding(12)
    }

    private var confirmTitle: String {
        switch confirm {
        case .deleteSnapshots: return "Удалить снапшоты \(model.selectedAVDs.count) устройств?"
        case .wipeData: return "Сбросить \(model.selectedAVDs.count) устройств?"
        case .delete: return "Удалить \(model.androidSelection.count) объектов?"
        case nil: return ""
        }
    }

    private var confirmButton: String {
        switch confirm {
        case .deleteSnapshots: return "Удалить снапшоты"
        case .wipeData: return "Сбросить"
        case .delete: return "Удалить"
        case nil: return ""
        }
    }

    private var confirmMessage: String {
        let avds = model.selectedAVDs, packages = model.selectedAndroidPackages
        switch confirm {
        case .deleteSnapshots:
            return "Освободится \(formatBytes(avds.reduce(0) { $0 + $1.snapshotsSize })). Эмулятор будет стартовать «с холодной загрузки» вместо мгновенного восстановления — приложения и данные не затрагиваются."
        case .wipeData:
            return "Освободится \(formatBytes(avds.reduce(0) { $0 + $1.snapshotsSize + $1.userDataSize })). То же, что Wipe Data в Device Manager: устройство остаётся, установленные приложения и их данные удаляются."
        case .delete:
            var parts: [String] = []
            if !avds.isEmpty { parts.append("Устройства (\(avds.count)): исчезнут из Device Manager вместе с данными. Системный образ не затрагивается.") }
            if !packages.isEmpty {
                let images = packages.filter { $0.kind == .systemImage }.count
                parts.append("SDK-пакеты (\(packages.count)): удаляются через sdkmanager, при необходимости скачиваются заново в SDK Manager." + (images > 0 ? " Системные образы без AVD — безопасно." : ""))
            }
            return "Освободится \(formatBytes(model.selectedAndroidSize)).\n\n" + parts.joined(separator: "\n")
        case nil: return ""
        }
    }
}

// MARK: - Строки

private func tagBadge(_ text: String, _ color: Color) -> some View {
    Text(text).font(.caption2.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
}

struct AVDRow: View {
    let avd: AndroidAVD
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            Image(systemName: "smartphone").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(avd.displayName)
                    if !avd.apiLevel.isEmpty { tagBadge(avd.apiLevel, .blue) }
                    if avd.snapshotsSize > 500 * 1024 * 1024 { tagBadge("снапшоты \(formatBytes(avd.snapshotsSize))", .orange) }
                }
                Text("\(avd.systemImage.replacingOccurrences(of: "system-images/", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))) · данные \(formatBytes(avd.userDataSize))\(avd.modified.map { " · менялся \($0.formatted(.relative(presentation: .named)))" } ?? "")")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Text(formatBytes(avd.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

struct PackageRow: View {
    let package: AndroidPackage
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .foregroundStyle(package.inUse ? Color.secondary.opacity(0.3) : selected ? Color.accentColor : .secondary)
            Image(systemName: package.kind == .systemImage ? "opticaldisc" : "shippingbox").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(package.title)
                    if package.inUse { tagBadge("AVD: \(package.usedBy.joined(separator: ", "))", .green) }
                    if !package.isRegistered { tagBadge("Остаток загрузки", .orange) }
                }
                Text(package.id).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(formatBytes(package.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .opacity(package.inUse ? 0.6 : 1)
    }
}
