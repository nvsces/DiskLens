import Foundation

/// Виртуальное Android-устройство из ~/.android/avd.
struct AndroidAVD: Identifiable, Sendable {
    let id: String              // имя из .ini — его понимает avdmanager
    let displayName: String
    let path: String            // папка .avd
    let systemImage: String     // относительный путь в SDK
    let size: Int64
    let snapshotsSize: Int64    // снимки состояния: пересоздаются, безопасно
    let userDataSize: Int64     // userdata-qemu.img + cache: данные приложений
    let modified: Date?

    var apiLevel: String {
        systemImage.split(separator: "/").first { $0.hasPrefix("android-") }.map(String.init) ?? ""
    }
}

/// Пакет SDK: системный образ, NDK, build-tools, platforms и т.п.
struct AndroidPackage: Identifiable, Sendable {
    let id: String              // "ndk;27.0.12077973" — формат sdkmanager
    let kind: Kind
    let title: String
    let path: String
    let size: Int64
    let modified: Date?
    var usedBy: [String] = []   // имена AVD для системных образов
    var isRegistered = true     // sdkmanager знает о пакете; иначе — остаток от прерванной загрузки

    enum Kind: String, Sendable, CaseIterable {
        case systemImage = "Системные образы"
        case ndk = "NDK"
        case buildTools = "Build-tools"
        case platform = "Platforms"
        case sources = "Sources"
        case cmake = "CMake"
    }

    var inUse: Bool { !usedBy.isEmpty }
}

struct AndroidSnapshot: Sendable {
    var avds: [AndroidAVD] = []
    var packages: [AndroidPackage] = []
    var emulatorRunning = false
    var sdkPath = ""

    var avdsSize: Int64 { avds.reduce(0) { $0 + $1.size } }
    var packagesSize: Int64 { packages.reduce(0) { $0 + $1.size } }
    var total: Int64 { avdsSize + packagesSize }
    func packages(of kind: AndroidPackage.Kind) -> [AndroidPackage] { packages.filter { $0.kind == kind } }
}

struct AndroidError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// AVD — через avdmanager, пакеты — через sdkmanager. Только снапшоты и
/// остатки прерванных загрузок удаляются как файлы: их никто не учитывает.
final class AndroidManager: @unchecked Sendable {
    let sdkPath: String = {
        let env = ProcessInfo.processInfo.environment
        return env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"] ?? NSHomeDirectory() + "/Library/Android/sdk"
    }()
    private var avdHome: String {
        ProcessInfo.processInfo.environment["ANDROID_AVD_HOME"] ?? NSHomeDirectory() + "/.android/avd"
    }
    private var sdkmanager: String { sdkPath + "/cmdline-tools/latest/bin/sdkmanager" }
    private var avdmanager: String { sdkPath + "/cmdline-tools/latest/bin/avdmanager" }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: sdkPath) }
    var hasTools: Bool { FileManager.default.isExecutableFile(atPath: sdkmanager) }

    func load() throws -> AndroidSnapshot {
        var snapshot = AndroidSnapshot()
        snapshot.sdkPath = sdkPath
        snapshot.emulatorRunning = isEmulatorRunning()
        snapshot.avds = loadAVDs().sorted { $0.size > $1.size }

        let registered = Set(installedPackageIDs())
        var packages: [AndroidPackage] = []
        packages += scan(kind: .systemImage, depth: 3, registered: registered)
        packages += scan(kind: .ndk, depth: 1, registered: registered)
        packages += scan(kind: .buildTools, depth: 1, registered: registered)
        packages += scan(kind: .platform, depth: 1, registered: registered)
        packages += scan(kind: .sources, depth: 1, registered: registered)
        packages += scan(kind: .cmake, depth: 1, registered: registered)

        // Какие образы держат AVD.
        for i in packages.indices where packages[i].kind == .systemImage {
            let rel = packages[i].id.replacingOccurrences(of: ";", with: "/")
            packages[i].usedBy = snapshot.avds
                .filter { $0.systemImage.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == rel }
                .map(\.displayName)
        }
        // Внутри вида — по версии, новые сверху: так сразу видно, что устарело.
        snapshot.packages = packages.sorted {
            $0.kind == $1.kind
                ? $0.title.compare($1.title, options: .numeric) == .orderedDescending
                : $0.kind.rawValue < $1.kind.rawValue
        }
        return snapshot
    }

    // MARK: - Действия

    func deleteAVD(_ avd: AndroidAVD) throws {
        guard !isEmulatorRunning() else { throw AndroidError(message: "Закройте эмулятор перед удалением") }
        if FileManager.default.isExecutableFile(atPath: avdmanager) {
            _ = try run(avdmanager, ["delete", "avd", "-n", avd.id])
        } else {
            // Без cmdline-tools удаляем то же, что удалил бы avdmanager: папку и .ini.
            try FileManager.default.removeItem(atPath: avd.path)
            try? FileManager.default.removeItem(atPath: avdHome + "/\(avd.id).ini")
        }
    }

    /// Снимки состояния: эмулятор делает их при закрытии и пересоздаёт при следующем.
    func deleteSnapshots(_ avd: AndroidAVD) throws {
        guard !isEmulatorRunning() else { throw AndroidError(message: "Закройте эмулятор перед удалением снапшотов") }
        let path = avd.path + "/snapshots"
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
    }

    /// Эквивалент «Wipe Data» в Device Manager: устройство остаётся, данные — с нуля.
    func wipeData(_ avd: AndroidAVD) throws {
        guard !isEmulatorRunning() else { throw AndroidError(message: "Закройте эмулятор перед сбросом") }
        for name in ["snapshots", "userdata-qemu.img", "userdata-qemu.img.qcow2", "cache.img", "cache.img.qcow2", "sdcard.img.qcow2"] {
            let path = avd.path + "/" + name
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        }
    }

    func uninstall(_ package: AndroidPackage) throws {
        if package.isRegistered, FileManager.default.isExecutableFile(atPath: sdkmanager) {
            _ = try run(sdkmanager, ["--uninstall", package.id])
        } else {
            // Остаток прерванной загрузки: sdkmanager о нём не знает, удаляем папку.
            try FileManager.default.removeItem(atPath: package.path)
        }
    }

    // MARK: - Сбор данных

    private func loadAVDs() -> [AndroidAVD] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: avdHome) else { return [] }
        return entries.filter { $0.hasSuffix(".ini") }.compactMap { iniName in
            let name = String(iniName.dropLast(4))
            let ini = parseINI(avdHome + "/" + iniName)
            // path.rel надёжнее абсолютного path: тот бывает от другого пользователя.
            let path = ini["path"].flatMap { fm.fileExists(atPath: $0) ? $0 : nil }
                ?? avdHome + "/" + (ini["path.rel"].map { String($0.dropFirst(4)) } ?? name + ".avd")
            guard fm.fileExists(atPath: path) else { return nil }
            let config = parseINI(path + "/config.ini")
            let userData = ["userdata-qemu.img", "userdata-qemu.img.qcow2", "cache.img", "cache.img.qcow2"]
                .reduce(Int64(0)) { $0 + fileSize(path + "/" + $1) }
            return AndroidAVD(
                id: name,
                displayName: config["avd.ini.displayname"] ?? name.replacingOccurrences(of: "_", with: " "),
                path: path,
                systemImage: config["image.sysdir.1"] ?? "",
                size: directorySize(path),
                snapshotsSize: directorySize(path + "/snapshots"),
                userDataSize: userData,
                modified: (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            )
        }
    }

    private func scan(kind: AndroidPackage.Kind, depth: Int, registered: Set<String>) -> [AndroidPackage] {
        let folder: String
        switch kind {
        case .systemImage: folder = "system-images"
        case .ndk: folder = "ndk"
        case .buildTools: folder = "build-tools"
        case .platform: folder = "platforms"
        case .sources: folder = "sources"
        case .cmake: folder = "cmake"
        }
        let root = sdkPath + "/" + folder
        return leafDirectories(root, depth: depth).map { path in
            let rel = String(path.dropFirst(sdkPath.count + 1))
            let id = rel.replacingOccurrences(of: "/", with: ";")
            let components = rel.split(separator: "/").dropFirst().map(String.init)
            return AndroidPackage(
                id: id,
                kind: kind,
                title: kind == .systemImage ? components.joined(separator: " · ") : components.joined(separator: " "),
                path: path,
                size: directorySize(path),
                modified: (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date,
                isRegistered: registered.contains(id)
            )
        }
    }

    private func installedPackageIDs() -> [String] {
        guard FileManager.default.isExecutableFile(atPath: sdkmanager),
              let data = try? run(sdkmanager, ["--list_installed"]),
              let text = String(data: data, encoding: .utf8) else { return [] }
        // Формат: "  ndk;27.0.12077973 | 27.0.12077973 | NDK (Side by side) 27.0 | ndk/27.0.12077973"
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|")
            guard parts.count >= 3 else { return nil }
            let id = parts[0].trimmingCharacters(in: .whitespaces)
            return id.contains(";") || id == "emulator" ? id : nil
        }
    }

    private func isEmulatorRunning() -> Bool {
        guard let data = try? run("/usr/bin/pgrep", ["-f", "qemu-system"]) else { return false }
        return !(String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Утилиты

    private func parseINI(_ path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            result[line[..<eq].trimmingCharacters(in: .whitespaces)] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private func leafDirectories(_ root: String, depth: Int) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return entries.filter { !$0.hasPrefix(".") }.flatMap { entry -> [String] in
            let path = root + "/" + entry
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return [] }
            return depth <= 1 ? [path] : leafDirectories(path, depth: depth - 1)
        }
    }

    private func fileSize(_ path: String) -> Int64 {
        Int64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
    }

    private func directorySize(_ path: String) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        // sdkmanager — JVM-скрипт; ему нужен JAVA_HOME или java в PATH. Подсказываем Android Studio.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        if env["JAVA_HOME"] == nil {
            let studioJDK = "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
            if FileManager.default.fileExists(atPath: studioJDK) { env["JAVA_HOME"] = studioJDK }
        }
        task.environment = env
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        try task.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let text = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AndroidError(message: text.isEmpty ? "\(URL(fileURLWithPath: executable).lastPathComponent) завершился с кодом \(task.terminationStatus)" : String(text.suffix(400)))
        }
        return data
    }
}
