import Foundation

/// Результат поиска по одной категории.
struct JunkGroup: Identifiable, Sendable {
    let category: JunkCategory
    var items: [JunkItem]

    var id: String { category.id }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { items.filter(\.isSelected).reduce(0) { $0 + $1.size } }
    var selectedCount: Int { items.filter(\.isSelected).count }
}

/// Применяет правила из JunkRules к диску.
final class JunkFinder: @unchecked Sendable {
    private let cancelled = Atomic(false)

    func cancel() { cancelled.value = true }

    func findAll(progress: @Sendable (String) -> Void = { _ in }) -> [JunkGroup] {
        cancelled.value = false
        var groups: [JunkGroup] = []
        for category in JunkRules.categories {
            if cancelled.value { break }
            progress(category.title)
            let items = find(category: category)
            if !items.isEmpty {
                groups.append(JunkGroup(category: category, items: items.sorted { $0.size > $1.size }))
            }
        }
        return groups.sorted { $0.totalSize > $1.totalSize }
    }

    private func find(category: JunkCategory) -> [JunkItem] {
        var results: [JunkItem] = []
        let cutoff = category.minAgeDays > 0
            ? Date().addingTimeInterval(-Double(category.minAgeDays) * 86400)
            : nil

        for root in category.roots {
            let rootURL = URL(fileURLWithPath: root)
            guard FileManager.default.fileExists(atPath: root) else { continue }

            if category.depth == 0 {
                // Категория указывает на конкретную папку — берём её целиком.
                appendIfMatches(rootURL, category: category, cutoff: cutoff, into: &results)
            } else {
                collect(in: rootURL, category: category, cutoff: cutoff, depth: category.depth, into: &results)
            }
        }
        return results
    }

    private func collect(
        in directory: URL,
        category: JunkCategory,
        cutoff: Date?,
        depth: Int,
        into results: inout [JunkItem]
    ) {
        if cancelled.value || depth <= 0 { return }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        )) ?? []

        for url in contents {
            if cancelled.value { return }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            let isDir = values?.isDirectory == true

            let nameMatches = category.matchDirectoryNames.contains(url.lastPathComponent)
            let extMatches = category.matchExtensions.contains(url.pathExtension.lowercased())
            // Категория без фильтров по имени перечисляет всё содержимое корня —
            // так работают Caches, Logs, DerivedData.
            let takesEverything = category.matchDirectoryNames.isEmpty && category.matchExtensions.isEmpty

            if (isDir && nameMatches) || (!isDir && extMatches) || takesEverything {
                appendIfMatches(url, category: category, cutoff: cutoff, into: &results)
                // Внутрь совпавшей папки не спускаемся: node_modules внутри
                // node_modules учитывать дважды нельзя.
                if isDir && nameMatches { continue }
            }

            if isDir && !nameMatches {
                collect(in: url, category: category, cutoff: cutoff, depth: depth - 1, into: &results)
            }
        }
    }

    private func appendIfMatches(
        _ url: URL,
        category: JunkCategory,
        cutoff: Date?,
        into results: inout [JunkItem]
    ) {
        guard !SafeDelete.isProtected(url) else { return }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
        let modified = values?.contentModificationDate

        if let cutoff, let modified, modified > cutoff { return }

        let size = directorySize(url)
        guard size >= category.minSize else { return }

        results.append(JunkItem(
            url: url,
            size: size,
            modified: modified,
            categoryID: category.id,
            isSelected: false
        ))
    }

    /// Суммарный размер на диске. Для файла — его размер, для папки — обход вглубь.
    private func directorySize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey])
        if values?.isDirectory != true {
            return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }

        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let child = enumerator?.nextObject() as? URL {
            if cancelled.value { break }
            let v = try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey])
            guard v?.isRegularFile == true else { continue }
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }
}
