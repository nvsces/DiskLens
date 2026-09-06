import SwiftUI

struct DevToolsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirm = false
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !model.devLoaded {
                VStack(spacing: 12) { ProgressView().controlSize(.large); Text(model.devStatus).font(.headline) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
                Divider()
                actionBar
            }
        }
        .navigationTitle("Инструменты")
        .onAppear { if !model.devLoaded { model.loadDevTools() } }
        .alert("Ошибка", isPresented: Binding(get: { model.devError != nil }, set: { if !$0 { model.devError = nil } })) {
            Button("OK") { model.devError = nil }
        } message: { Text(model.devError ?? "") }
        .confirmationDialog("Очистить \(model.devSelection.count) объектов?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) { model.cleanupSelectedDev() }
            Button("Отмена", role: .cancel) {}
        } message: { Text(confirmMessage) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if model.devLoaded {
                Text("Занято \(formatBytes(model.devTotal))").font(.headline).monospacedDigit()
                Text("· индексы, кэши и тулчейны инструментов разработки").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Индексы, кэши и тулчейны инструментов разработки").foregroundStyle(.secondary)
            }
            Spacer()
            if model.isWorkingDev {
                ProgressView().controlSize(.small)
                Text(model.devStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Button { model.loadDevTools() } label: { Label("Обновить", systemImage: "arrow.clockwise") }
            }
        }
        .padding(12)
    }

    private var list: some View {
        List {
            ForEach(model.devGroups) { group in
                Section {
                    if !collapsed.contains(group.id) {
                        ForEach(group.entries) { entry in
                            DevRow(entry: entry, selected: model.devSelection.contains(entry.id))
                                .contentShape(Rectangle())
                                .onTapGesture { toggle(entry.id) }
                                .contextMenu {
                                    Button("Показать в Finder") { model.reveal(URL(fileURLWithPath: entry.path)) }
                                    if case .trash = entry.cleanup {
                                        Button("Открыть в Папках") { model.tab = .explorer; model.startScan(path: entry.path) }
                                    }
                                }
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        Button { if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) } } label: {
                            Image(systemName: collapsed.contains(group.id) ? "chevron.right" : "chevron.down").font(.caption).frame(width: 12)
                        }.buttonStyle(.plain)
                        Image(systemName: group.symbol).foregroundStyle(.secondary)
                        Text(group.id).font(.headline).foregroundStyle(.primary)
                        Text("\(group.entries.count)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(formatBytes(group.size)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.inset)
    }

    private func toggle(_ id: String) {
        if model.devSelection.contains(id) { model.devSelection.remove(id) } else { model.devSelection.insert(id) }
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            if model.devFreed > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Освобождено около \(formatBytes(model.devFreed)). Перемещённое в Корзину освободится после её очистки.").font(.callout)
                    Spacer()
                }
                .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 12) {
                Button("Выбрать безопасное") { model.selectSafeDev() }
                    .help("Всё с пометкой «Безопасно», что не используется")
                Button("Снять выбор") { model.devSelection = [] }.disabled(model.devSelection.isEmpty)
                Spacer()
                if !model.devSelection.isEmpty {
                    Text("\(model.devSelection.count) выбрано · \(formatBytes(model.selectedDevSize))").monospacedDigit().foregroundStyle(.secondary)
                }
                Button { confirm = true } label: { Label("Очистить", systemImage: "trash") }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(model.devSelection.isEmpty || model.isWorkingDev)
            }
        }
        .padding(12)
    }

    private var confirmMessage: String {
        let entries = model.selectedDevEntries
        let commands = entries.compactMap(\.commandText)
        var text = "Освободится около \(formatBytes(model.selectedDevSize)).\n\n"
        let trashed = entries.filter { if case .trash = $0.cleanup { return true }; return false }.count
        if trashed > 0 { text += "\(trashed) объектов — в Корзину.\n" }
        if !commands.isEmpty { text += "Родными командами инструментов:\n" + commands.prefix(6).map { "  " + $0 }.joined(separator: "\n") + (commands.count > 6 ? "\n  …" : "") + "\n" }
        let risky = entries.filter { $0.safety == .risky }
        if !risky.isEmpty { text += "\n⚠️ Отмечено как «Осторожно»: " + risky.map(\.title).joined(separator: ", ") }
        return text
    }
}

struct DevRow: View {
    let entry: DevEntry
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .foregroundStyle(selected ? Color.accentColor : .secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title).fontWeight(.medium)
                    SafetyBadge(safety: entry.safety)
                    if entry.inUse {
                        Text(entry.usedBy.isEmpty ? "Активен" : "Используют: \(entry.usedBy.joined(separator: ", "))")
                            .font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green.opacity(0.15), in: Capsule()).foregroundStyle(.green)
                    }
                }
                Text(entry.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    Text(entry.displayPath).lineLimit(1).truncationMode(.middle)
                    if let cmd = entry.commandText {
                        Text("· \(cmd)").font(.caption2.monospaced()).lineLimit(1)
                    }
                }.font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(formatBytes(entry.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}
