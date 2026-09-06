import Foundation

/// Прогресс сканирования, чтобы UI показывал живой отклик на больших деревьях.
struct ScanProgress: Sendable {
    var scannedFiles: Int = 0
    var totalBytes: Int64 = 0
    var currentPath: String = ""
}

/// Обходчик файловой системы. Считает размер на диске, не логический размер:
/// для APFS со сжатием и разреженных файлов разница бывает кратной.
final class DiskScanner: @unchecked Sendable {
    private let keys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .isVolumeKey,
        .volumeIdentifierKey,
    ]

    private let cancelled = Atomic(false)
    private let counter = Atomic(0)
    private let bytes = Atomic64(0)

    /// Тома, отличные от стартового, не пересекаем — иначе внешний диск
    /// или сетевая шара утянут скан на часы.
    private var rootVolumeID: NSObject?

    private let onProgress: @Sendable (ScanProgress) -> Void

    init(onProgress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) {
        self.onProgress = onProgress
    }

    func cancel() { cancelled.value = true }

    func scan(root: URL) -> FileNode? {
        cancelled.value = false
        counter.value = 0
        bytes.value = 0
        rootVolumeID = volumeIdentifier(of: root)
        return walk(url: root, depth: 0)
    }

    /// Идентификатор тома приходит экзистенциалом; сравнивать удобнее
    /// через NSObject, который он под капотом и есть.
    private func volumeIdentifier(of url: URL) -> NSObject? {
        guard let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey]) else { return nil }
        return values.volumeIdentifier as? NSObject
    }

    /// Верхние два уровня обходим параллельно: это даёт основной выигрыш,
    /// глубже накладные расходы на диспетчеризацию перевешивают.
    private func walk(url: URL, depth: Int) -> FileNode? {
        if cancelled.value { return nil }

        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if values.isSymbolicLink == true { return nil }

        let isDir = values.isDirectory == true
        let isPackage = values.isPackage == true

        // .app, .photoslibrary и прочие бандлы показываем одной строкой:
        // пользователю не нужны потроха пакета, ему нужен его вес.
        if !isDir || isPackage {
            let size = allocatedSize(values)
            let n = counter.increment()
            let total = bytes.add(size)
            if n % 4096 == 0 {
                onProgress(ScanProgress(scannedFiles: n, totalBytes: total, currentPath: url.path))
            }
            return FileNode(
                url: url,
                isDirectory: isPackage,
                size: size,
                fileCount: 1,
                modified: values.contentModificationDate
            )
        }

        if depth > 0, let rootVolumeID, volumeIdentifier(of: url) != rootVolumeID {
            return nil
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsSubdirectoryDescendants]
        )) ?? []

        var children: [FileNode] = []

        if depth < 2 && contents.count > 1 {
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: contents.count) { index in
                if let child = self.walk(url: contents[index], depth: depth + 1) {
                    lock.lock()
                    children.append(child)
                    lock.unlock()
                }
            }
        } else {
            for child in contents {
                if let node = walk(url: child, depth: depth + 1) {
                    children.append(node)
                }
            }
        }

        if cancelled.value { return nil }

        let node = FileNode(
            url: url,
            isDirectory: true,
            size: children.reduce(0) { $0 + $1.size },
            fileCount: children.reduce(0) { $0 + $1.fileCount },
            modified: values.contentModificationDate
        )
        for child in children { child.parent = node }
        node.children = children
        return node
    }

    private func allocatedSize(_ values: URLResourceValues) -> Int64 {
        if let total = values.totalFileAllocatedSize { return Int64(total) }
        if let allocated = values.fileAllocatedSize { return Int64(allocated) }
        if let logical = values.fileSize { return Int64(logical) }
        return 0
    }
}

/// Минимальные потокобезопасные счётчики — Swift Atomics тянуть ради двух
/// счётчиков не хочется, зависимостей у пакета нет намеренно.
final class Atomic<T>: @unchecked Sendable {
    private var storage: T
    private let lock = NSLock()
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

final class Atomic64: @unchecked Sendable {
    private var storage: Int64
    private let lock = NSLock()
    init(_ value: Int64) { storage = value }
    var value: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
    @discardableResult func add(_ delta: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        storage += delta
        return storage
    }
}

extension Atomic where T == Int {
    @discardableResult func increment() -> Int {
        value += 1
        return value
    }
}
