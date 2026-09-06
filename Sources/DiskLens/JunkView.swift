import SwiftUI

struct JunkView: View {
    @EnvironmentObject var model: AppModel
    @State private var expanded: Set<String> = []
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if model.isFindingJunk {
                searchingState
            } else if model.junkGroups.isEmpty {
                emptyState
            } else {
                groupList
                Divider()
                actionBar
            }
        }
        .navigationTitle("Очистка")
        .onAppear {
            if CommandLine.arguments.contains("--junk"), model.junkGroups.isEmpty, !model.isFindingJunk {
                model.findJunk(); expanded = ["build-dirs"]
            }
        }
        .confirmationDialog(
            model.permanentDelete ? "Удалить безвозвратно?" : "Переместить в Корзину?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button(
                model.permanentDelete ? "Удалить навсегда" : "В Корзину",
                role: .destructive
            ) {
                model.deleteSelected()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(model.permanentDelete
                 ? "\(model.selectedJunkCount) объектов (\(formatBytes(model.selectedJunkSize))) будут стёрты без возможности восстановления."
                 : "\(model.selectedJunkCount) объектов (\(formatBytes(model.selectedJunkSize))) отправятся в Корзину. Вернуть их можно оттуда.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if model.junkGroups.isEmpty {
                Text("Поиск ненужных файлов по типовым местам их накопления")
                    .foregroundStyle(.secondary)
            } else {
                Text("Найдено \(formatBytes(model.totalJunkSize))")
                    .font(.headline)
                    .monospacedDigit()
            }

            Spacer()

            if !model.junkGroups.isEmpty {
                Toggle("Скрыть изменённые за 7 дней", isOn: $model.hideRecentJunk)
                    .toggleStyle(.checkbox).font(.caption)
                    .onChange(of: model.hideRecentJunk) { _, hide in if hide { model.deselectRecent() } }
            }

            if model.isFindingJunk {
                Button("Отмена", role: .cancel) { model.cancelJunkSearch() }
            } else {
                Button {
                    model.findJunk()
                } label: {
                    Label(model.junkGroups.isEmpty ? "Найти мусор" : "Искать заново",
                          systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
    }

    private var groupList: some View {
        List {
            ForEach(model.junkGroups) { group in
                GroupHeader(
                    group: group,
                    isExpanded: expanded.contains(group.id),
                    onToggleExpand: { toggleExpand(group.id) },
                    onSelectAll: { model.setSelection(groupID: group.id, selected: $0) }
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))

                if expanded.contains(group.id) {
                    ForEach(model.visibleItems(group)) { item in
                        JunkRow(item: item)
                            .onTapGesture { model.toggle(item: item) }
                            .contextMenu {
                                Button("Показать в Finder") { model.reveal(item.url) }
                            }
                    }
                }
            }
        }
        .listStyle(.inset)
        .animation(.easeInOut(duration: 0.15), value: expanded)
    }

    private func toggleExpand(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            if let outcome = model.lastOutcome {
                OutcomeBanner(outcome: outcome, permanent: model.permanentDelete)
            }

            HStack(spacing: 12) {
                Button("Выбрать безопасное") { model.selectSafeOnly() }
                Button("Снять выбор") { model.deselectAll() }
                    .disabled(model.selectedJunkCount == 0)

                Spacer()

                if model.selectedJunkCount > 0 {
                    Text("\(model.selectedJunkCount) выбрано · \(formatBytes(model.selectedJunkSize))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Button {
                    confirming = true
                } label: {
                    Label(
                        model.permanentDelete ? "Удалить" : "В Корзину",
                        systemImage: "trash"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.selectedJunkCount == 0)
            }
        }
        .padding(12)
    }

    private var searchingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(model.junkStatus).font(.headline)
            Text("Считаю размеры папок — это занимает время на больших проектах.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 46))
                .foregroundStyle(.tertiary)
            Text(model.junkStatus.isEmpty ? "Мусор ещё не искали" : model.junkStatus)
                .font(.headline)
            Text("Проверю кэши, сборки, логи, старые загрузки и другие типовые накопители.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Найти мусор") { model.findJunk() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct GroupHeader: View {
    let group: JunkGroup
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onSelectAll: (Bool) -> Void

    private var allSelected: Bool {
        !group.items.isEmpty && group.selectedCount == group.items.count
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { allSelected },
                set: { onSelectAll($0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            Image(systemName: group.category.symbol)
                .foregroundStyle(group.category.safety.color)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(group.category.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    SafetyBadge(safety: group.category.safety)
                }
                Text(group.category.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 1) {
                Text(formatBytes(group.totalSize))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                Text("\(group.items.count) объектов")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .textCase(nil)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleExpand)
    }
}

struct SafetyBadge: View {
    let safety: JunkSafety

    var body: some View {
        Text(safety.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(safety.color.opacity(0.15), in: Capsule())
            .foregroundStyle(safety.color)
    }
}

struct JunkRow: View {
    let item: JunkItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(item.isSelected ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.contextName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isRecent {
                        Text("Активный")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                            .help("Менялся за последние 7 дней — проект, скорее всего, в работе")
                    }
                }
                Text(item.displayPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let modified = item.modified {
                Text(modified, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(formatBytes(item.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .padding(.leading, 22)
        .contentShape(Rectangle())
    }
}

struct OutcomeBanner: View {
    let outcome: SafeDelete.Outcome
    let permanent: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: outcome.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(outcome.failures.isEmpty ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Освобождено \(formatBytes(outcome.freedBytes)) · \(outcome.deletedCount) объектов")
                    .font(.callout.weight(.medium))
                if !outcome.failures.isEmpty {
                    Text("Не удалось удалить: \(outcome.failures.count). \(outcome.failures.first?.reason ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !permanent && outcome.deletedCount > 0 {
                    Text("Место освободится полностью после очистки Корзины.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
