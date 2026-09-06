import Foundation

/// Устройство симулятора из `simctl list devices -j`.
struct SimDevice: Identifiable, Sendable {
    let id: String              // UDID
    let name: String
    let state: String           // Shutdown / Booted / ...
    let isAvailable: Bool
    let dataPath: String
    let dataSize: Int64
    let logSize: Int64
    let lastBooted: Date?
    let runtimeIdentifier: String
    let deviceType: String
    /// Известная утечка симулятора: кэш превью клавиатуры растёт до десятков гигабайт.
    var keyboardCacheSize: Int64 = 0

    var size: Int64 { dataSize + logSize }
    var keyboardCachePath: String { dataPath + "/Library/Caches/com.apple.keyboards" }
    var isBooted: Bool { state == "Booted" }
    /// Xcode сам создаёт пустую «заготовку» каждой модели для каждого рантайма.
    /// Удалять их бессмысленно — при следующем запуске они появятся снова.
    var isStub: Bool { dataSize < 50 * 1024 * 1024 && lastBooted == nil }
}

/// Образ рантайма из `simctl runtime list -j`.
struct SimRuntime: Identifiable, Sendable {
    let id: String              // UUID образа
    let runtimeIdentifier: String
    let version: String
    let build: String
    let size: Int64
    let deletable: Bool
    let state: String
    let lastUsed: Date?
    let platform: String

    var title: String { "\(platform) \(version) (\(build))" }
}

/// Группа: один рантайм (или несколько его билдов) и устройства на нём.
struct SimGroup: Identifiable, Sendable {
    let id: String              // runtimeIdentifier
    let title: String           // "iOS 18.5"
    var runtimes: [SimRuntime]
    var devices: [SimDevice]

    var devicesSize: Int64 { devices.reduce(0) { $0 + $1.size } }
    var runtimeSize: Int64 { runtimes.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { devicesSize + runtimeSize }

    /// Несколько билдов одной версии: CoreSimulator использует самый новый,
    /// остальные — мёртвый груз после обновления Xcode.
    var duplicateRuntimes: [SimRuntime] {
        guard runtimes.count > 1 else { return [] }
        let sorted = runtimes.sorted { $0.build > $1.build }
        return Array(sorted.dropFirst())
    }
}

struct SimError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Все операции — только через simctl. Он обновляет реестр CoreSimulator;
/// удаление папок напрямую оставляет в Xcode «призраков».
final class SimulatorManager: @unchecked Sendable {
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: "/usr/bin/xcrun")
            && (try? run(["simctl", "help"])) != nil
    }

    func load() throws -> [SimGroup] {
        let devicesJSON = try run(["simctl", "list", "devices", "-j"])
        let runtimesJSON = try run(["simctl", "runtime", "list", "-j"])

        guard let devicesRoot = try JSONSerialization.jsonObject(with: devicesJSON) as? [String: Any],
              let devicesByRuntime = devicesRoot["devices"] as? [String: [[String: Any]]],
              let runtimesRoot = try JSONSerialization.jsonObject(with: runtimesJSON) as? [String: [String: Any]]
        else { throw SimError(message: "Не удалось разобрать ответ simctl") }

        var groups: [String: SimGroup] = [:]

        for (runtimeID, list) in devicesByRuntime {
            var devices = list.compactMap { parseDevice($0, runtimeID: runtimeID) }
            // Считаем кэш клавиатуры только там, где есть что считать.
            for i in devices.indices where devices[i].dataSize > 512 * 1024 * 1024 {
                devices[i].keyboardCacheSize = directorySize(devices[i].keyboardCachePath)
            }
            groups[runtimeID, default: SimGroup(id: runtimeID, title: title(for: runtimeID), runtimes: [], devices: [])]
                .devices = devices.sorted { $0.size > $1.size }
        }

        for (_, raw) in runtimesRoot {
            guard let runtime = parseRuntime(raw) else { continue }
            groups[runtime.runtimeIdentifier, default: SimGroup(
                id: runtime.runtimeIdentifier, title: title(for: runtime.runtimeIdentifier), runtimes: [], devices: []
            )].runtimes.append(runtime)
        }

        return groups.values
            .filter { !$0.devices.isEmpty || !$0.runtimes.isEmpty }
            .sorted { $0.totalSize > $1.totalSize }
    }

    // MARK: - Действия

    /// Сброс содержимого: устройство остаётся, данные приложений и настройки стираются.
    /// Самый безопасный способ вернуть место — Xcode ничего не заметит.
    func erase(udid: String) throws {
        try shutdownIfNeeded(udid: udid)
        _ = try run(["simctl", "erase", udid])
    }

    func delete(udid: String) throws {
        try shutdownIfNeeded(udid: udid)
        _ = try run(["simctl", "delete", udid])
    }

    /// Удаляет устройства, чей рантайм уже отсутствует — они всё равно не запускаются.
    func deleteUnavailable() throws {
        _ = try run(["simctl", "delete", "unavailable"])
    }

    /// Кэш клавиатуры не входит в реестр CoreSimulator — его можно удалить как файлы,
    /// достаточно, чтобы устройство было выключено.
    func clearKeyboardCache(device: SimDevice) throws {
        try shutdownIfNeeded(udid: device.id)
        let url = URL(fileURLWithPath: device.keyboardCachePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func directorySize(_ path: String) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    func deleteRuntime(id: String) throws {
        _ = try run(["simctl", "runtime", "delete", id])
    }

    private func shutdownIfNeeded(udid: String) throws {
        // Ошибку «уже выключен» игнорируем: нам важно только, чтобы не было Booted.
        _ = try? run(["simctl", "shutdown", udid])
    }

    // MARK: - Разбор

    private func parseDevice(_ raw: [String: Any], runtimeID: String) -> SimDevice? {
        guard let udid = raw["udid"] as? String, let name = raw["name"] as? String else { return nil }
        return SimDevice(
            id: udid,
            name: name,
            state: raw["state"] as? String ?? "Unknown",
            isAvailable: raw["isAvailable"] as? Bool ?? false,
            dataPath: raw["dataPath"] as? String ?? "",
            dataSize: Int64(raw["dataPathSize"] as? Int ?? 0),
            logSize: Int64(raw["logPathSize"] as? Int ?? 0),
            lastBooted: (raw["lastBootedAt"] as? String).flatMap { isoFormatter.date(from: $0) },
            runtimeIdentifier: runtimeID,
            deviceType: raw["deviceTypeIdentifier"] as? String ?? ""
        )
    }

    private func parseRuntime(_ raw: [String: Any]) -> SimRuntime? {
        guard let id = raw["identifier"] as? String,
              let runtimeID = raw["runtimeIdentifier"] as? String else { return nil }
        let platformID = raw["platformIdentifier"] as? String ?? ""
        let platform = platformID.contains("watch") ? "watchOS"
            : platformID.contains("appletv") ? "tvOS"
            : platformID.contains("xr") || platformID.contains("vision") ? "visionOS"
            : "iOS"
        return SimRuntime(
            id: id,
            runtimeIdentifier: runtimeID,
            version: raw["version"] as? String ?? "",
            build: raw["build"] as? String ?? "",
            size: Int64(raw["sizeBytes"] as? Int ?? 0),
            deletable: raw["deletable"] as? Bool ?? false,
            state: raw["state"] as? String ?? "",
            lastUsed: (raw["lastUsedAt"] as? String).flatMap { isoFormatter.date(from: $0) },
            platform: platform
        )
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-18-5" → "iOS 18.5"
    private func title(for runtimeID: String) -> String {
        let tail = runtimeID.components(separatedBy: ".").last ?? runtimeID
        var parts = tail.components(separatedBy: "-")
        guard parts.count >= 2 else { return tail }
        let platform = parts.removeFirst()
        return "\(platform) \(parts.joined(separator: "."))"
    }

    // MARK: - Запуск xcrun

    @discardableResult
    private func run(_ arguments: [String]) throws -> Data {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        task.arguments = arguments
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        try task.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let text = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SimError(message: text.isEmpty ? "simctl завершился с кодом \(task.terminationStatus)" : text)
        }
        return data
    }
}
