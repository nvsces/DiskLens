import Foundation

/// Узел дерева файловой системы. Класс, а не структура: дерево большое,
/// и мы хотим ссылочную семантику при агрегации размеров вверх по иерархии.
final class FileNode: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool

    /// Размер, реально занимаемый на диске (с учётом разреженных файлов и сжатия APFS).
    var size: Int64
    var fileCount: Int
    var modified: Date?

    weak var parent: FileNode?
    var children: [FileNode]

    init(
        url: URL,
        name: String? = nil,
        isDirectory: Bool,
        size: Int64 = 0,
        fileCount: Int = 0,
        modified: Date? = nil,
        children: [FileNode] = []
    ) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isDirectory = isDirectory
        self.size = size
        self.fileCount = fileCount
        self.modified = modified
        self.children = children
    }

    /// Дети, отсортированные по убыванию размера — именно так их показываем везде.
    var sortedChildren: [FileNode] {
        children.sorted { $0.size > $1.size }
    }

    /// Доля узла в размере родителя, 0...1. Используется для полосок в списке.
    var fractionOfParent: Double {
        guard let parent, parent.size > 0 else { return 1 }
        return Double(size) / Double(parent.size)
    }

    var pathComponentsFromRoot: [FileNode] {
        var chain: [FileNode] = []
        var current: FileNode? = self
        while let node = current {
            chain.append(node)
            current = node.parent
        }
        return chain.reversed()
    }
}
