import Foundation

/// Образ. Несколько тегов одного ID — одна запись: место занимается один раз.
struct DockerImage: Identifiable, Sendable {
    let id: String
    var tags: [String]
    let size: Int64
    let uniqueSize: Int64      // без слоёв, общих с другими образами
    let sharedSize: Int64
    let createdSince: String
    let createdAt: Date?
    let containers: Int        // сколько контейнеров используют

    var inUse: Bool { containers > 0 }
    var isDangling: Bool { tags.isEmpty }
    var title: String { tags.first ?? String(id.dropFirst(7).prefix(12)) }
}

struct DockerContainer: Identifiable, Sendable {
    let id: String
    let name: String
    let image: String
    let status: String
    let size: Int64            // записываемый слой; образ считается отдельно
    let createdSince: String

    var isRunning: Bool { status.hasPrefix("Up") }
}

struct DockerVolume: Identifiable, Sendable {
    let id: String             // имя
    let size: Int64
    let links: Int
    let isAnonymous: Bool

    var inUse: Bool { links > 0 }
    var title: String { isAnonymous ? String(id.prefix(12)) + "… (анонимный)" : id }
}

struct DockerSnapshot: Sendable {
    var images: [DockerImage] = []
    var containers: [DockerContainer] = []
    var volumes: [DockerVolume] = []
    var buildCacheSize: Int64 = 0
    var buildCacheUnused: Int64 = 0
    var buildCacheEntries = 0

    // Итоги от `docker system df`: общие слои посчитаны один раз.
    var imagesSize: Int64 = 0
    var imagesReclaimable: Int64 = 0
    var containersSize: Int64 = 0
    var volumesSize: Int64 = 0
    var volumesReclaimable: Int64 = 0
    var total: Int64 { imagesSize + containersSize + volumesSize + buildCacheSize }
}

struct DockerError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Все операции через docker CLI — демон сам обновляет свои метаданные.
/// Docker.raw руками не трогаем никогда.
final class DockerManager: @unchecked Sendable {
    private let candidates = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        NSHomeDirectory() + "/.docker/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
    ]

    var binary: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }
    var isInstalled: Bool { binary != nil }

    /// Демон отвечает? `docker info` быстрый и не требует ничего лишнего.
    func isDaemonRunning() -> Bool {
        (try? run(["info", "--format", "{{.ServerVersion}}"], timeout: 5)) != nil
    }

    func startDesktop() {
        NSWorkspaceStart.open()
    }

    func load() throws -> DockerSnapshot {
        let data = try run(["system", "df", "-v", "--format", "{{json .}}"], timeout: 60)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DockerError(message: "Не удалось разобрать ответ docker")
        }
        var snapshot = DockerSnapshot()

        // Итоги: у `df` без -v общие слои учтены один раз, у нас так не выйдет.
        let totalsData = try run(["system", "df", "--format", "{{json .}}"], timeout: 60)
        for line in String(data: totalsData, encoding: .utf8)?.split(separator: "\n") ?? [] {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let size = parseSize(obj["Size"]), reclaimable = parseSize(obj["Reclaimable"])
            switch obj["Type"] as? String {
            case "Images": snapshot.imagesSize = size; snapshot.imagesReclaimable = reclaimable
            case "Containers": snapshot.containersSize = size
            case "Local Volumes": snapshot.volumesSize = size; snapshot.volumesReclaimable = reclaimable
            default: break
            }
        }

        // Полный список тегов: `df -v` показывает по одному тегу на образ,
        // а удалять нужно все, иначе слои останутся.
        var tagsByID: [String: [String]] = [:]
        let tagData = try run(["image", "ls", "--no-trunc", "--format", "{{.ID}}\t{{.Repository}}:{{.Tag}}"], timeout: 60)
        for line in String(data: tagData, encoding: .utf8)?.split(separator: "\n") ?? [] {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].hasPrefix("<none>") else { continue }
            tagsByID[parts[0], default: []].append(parts[1])
        }

        // Образы группируем по ID: docker перечисляет каждый тег отдельной строкой.
        var byID: [String: DockerImage] = [:]
        var order: [String] = []
        for raw in root["Images"] as? [[String: Any]] ?? [] {
            guard let id = raw["ID"] as? String else { continue }
            let repo = raw["Repository"] as? String ?? "<none>"
            let tag = raw["Tag"] as? String ?? "<none>"
            let tagName = repo == "<none>" ? nil : "\(repo):\(tag)"
            if var existing = byID[id] {
                if let tagName { existing.tags.append(tagName) }
                byID[id] = existing
            } else {
                order.append(id)
                byID[id] = DockerImage(
                    id: id,
                    tags: tagsByID[id] ?? (tagName.map { [$0] } ?? []),
                    size: parseSize(raw["Size"]),
                    uniqueSize: parseSize(raw["UniqueSize"]),
                    sharedSize: parseSize(raw["SharedSize"]),
                    createdSince: raw["CreatedSince"] as? String ?? "",
                    createdAt: parseDate(raw["CreatedAt"]),
                    containers: Int(raw["Containers"] as? String ?? "0") ?? 0
                )
            }
        }
        snapshot.images = order.compactMap { byID[$0] }.sorted { $0.size > $1.size }

        snapshot.containers = (root["Containers"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let id = raw["ID"] as? String else { return nil }
            return DockerContainer(
                id: id,
                name: raw["Names"] as? String ?? String(id.prefix(12)),
                image: raw["Image"] as? String ?? "",
                status: raw["Status"] as? String ?? "",
                size: parseSize(raw["Size"]),
                createdSince: raw["CreatedSince"] as? String ?? ""
            )
        }.sorted { $0.size > $1.size }

        snapshot.volumes = (root["Volumes"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let name = raw["Name"] as? String else { return nil }
            let labels = raw["Labels"] as? String ?? ""
            return DockerVolume(
                id: name,
                size: parseSize(raw["Size"]),
                links: Int(raw["Links"] as? String ?? "0") ?? 0,
                isAnonymous: labels.contains("com.docker.volume.anonymous")
            )
        }.sorted { $0.size > $1.size }

        for raw in root["BuildCache"] as? [[String: Any]] ?? [] {
            let size = parseSize(raw["Size"])
            snapshot.buildCacheSize += size
            snapshot.buildCacheEntries += 1
            if (raw["InUse"] as? String) != "true" { snapshot.buildCacheUnused += size }
        }
        return snapshot
    }

    // MARK: - Действия

    func removeImage(_ image: DockerImage) throws {
        // Удаляем по тегам, если они есть: так docker снимает тег за тегом и
        // удаляет слои, когда не остаётся ни одного. По ID — для dangling.
        if image.tags.isEmpty {
            _ = try run(["image", "rm", image.id], timeout: 120)
        } else {
            _ = try run(["image", "rm"] + image.tags, timeout: 120)
        }
    }

    func removeContainer(_ container: DockerContainer) throws {
        if container.isRunning {
            _ = try run(["stop", container.id], timeout: 60)
        }
        _ = try run(["rm", container.id], timeout: 60)
    }

    func removeVolume(_ volume: DockerVolume) throws {
        _ = try run(["volume", "rm", volume.id], timeout: 60)
    }

    /// Кэш сборки, не используемый ни одним образом. Восстанавливается при следующем build.
    func pruneBuildCache() throws {
        _ = try run(["builder", "prune", "-f"], timeout: 300)
    }

    // MARK: - Разбор

    /// docker пишет размеры строками: "11.4GB", "87.7MB", "0B". Единицы десятичные.
    private func parseSize(_ value: Any?) -> Int64 {
        guard let text = value as? String else { return 0 }
        let cleaned = text.split(separator: " ").first.map(String.init) ?? text
        let scanner = Scanner(string: cleaned)
        guard let number = scanner.scanDouble() else { return 0 }
        let unit = cleaned[scanner.currentIndex...].trimmingCharacters(in: .whitespaces).lowercased()
        let multiplier: Double
        switch unit {
        case "kb": multiplier = 1e3
        case "mb": multiplier = 1e6
        case "gb": multiplier = 1e9
        case "tb": multiplier = 1e12
        default: multiplier = 1
        }
        return Int64(number * multiplier)
    }

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    private func parseDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        // "2026-09-01 02:50:14 +0300 MSK" — отбрасываем имя зоны в конце.
        let parts = text.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        return dateFormatter.date(from: parts.prefix(3).joined(separator: " "))
    }

    // MARK: - Запуск CLI

    @discardableResult
    private func run(_ arguments: [String], timeout: TimeInterval) throws -> Data {
        guard let binary else { throw DockerError(message: "docker не найден") }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = arguments
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        try task.run()

        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        group.enter()
        task.terminationHandler = { _ in group.leave() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        if group.wait(timeout: deadline) == .timedOut {
            task.terminate()
            throw DockerError(message: "docker \(arguments.first ?? "") не ответил за \(Int(timeout)) с")
        }
        guard task.terminationStatus == 0 else {
            let text = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw DockerError(message: text.isEmpty ? "docker завершился с кодом \(task.terminationStatus)" : text)
        }
        return data
    }
}

/// Запуск Docker Desktop вынесен, чтобы менеджер не тянул AppKit.
enum NSWorkspaceStart {
    static func open() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Docker"]
        try? task.run()
    }
}
