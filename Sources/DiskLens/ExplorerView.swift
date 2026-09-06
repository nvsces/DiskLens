import SwiftUI
import AppKit

struct ExplorerView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if model.isScanning {
                scanningState
            } else if let node = model.currentNode {
                breadcrumbs
                Divider()
                fileList(node)
            } else {
                emptyState
            }
        }
        .navigationTitle("Папки")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                model.goUp()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(model.currentNode?.parent == nil)
            .help("На уровень выше")

            Text(model.scanRootPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button("Выбрать папку…") { chooseFolder() }

            if model.isScanning {
                Button("Отмена", role: .cancel) { model.cancelScan() }
            } else {
                Button {
                    model.startScan()
                } label: {
                    Label("Сканировать", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.currentNode?.pathComponentsFromRoot ?? []) { node in
                    Button {
                        model.currentNode = node
                    } label: {
                        Text(node.name)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(node.id == model.currentNode?.id ? .primary : .secondary)

                    if node.id != model.currentNode?.id {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func fileList(_ node: FileNode) -> some View {
        let children = node.sortedChildren
        return List {
            Section {
                ForEach(children) { child in
                    FileRow(node: child, parentSize: node.size)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.drillInto(child) }
                        .contextMenu {
                            Button("Показать в Finder") { model.reveal(child.url) }
                            if child.isDirectory && !child.children.isEmpty {
                                Button("Открыть здесь") { model.drillInto(child) }
                            }
                        }
                }
            } header: {
                HStack {
                    Text("\(children.count) объектов")
                    Spacer()
                    Text(formatBytes(node.size)).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .listStyle(.inset)
    }

    private var scanningState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Сканирую…")
                .font(.headline)
            Text("\(model.scanProgress.scannedFiles) файлов · \(formatBytes(model.scanProgress.totalBytes))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(model.scanProgress.currentPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 46))
                .foregroundStyle(.tertiary)
            Text("Папки ещё не просканированы")
                .font(.headline)
            Text("Начните с домашней папки — там обычно и лежит основной объём.")
                .foregroundStyle(.secondary)
            Button("Сканировать \(URL(fileURLWithPath: model.scanRootPath).lastPathComponent)") {
                model.startScan()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: model.scanRootPath)
        if panel.runModal() == .OK, let url = panel.url {
            model.startScan(path: url.path)
        }
    }
}

/// Строка списка: иконка Finder, имя, полоса доли и размер.
struct FileRow: View {
    let node: FileNode
    let parentSize: Int64

    private var fraction: Double {
        parentSize > 0 ? Double(node.size) / Double(parentSize) : 0
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                .resizable()
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if node.isDirectory && !node.children.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(formatBytes(node.size))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary.opacity(0.5))
                        Capsule()
                            .fill(paletteColor(for: node.name).gradient)
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
                .frame(height: 4)
            }

            Text("\(Int(fraction * 100))%")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}
