import Foundation
import SwiftUI

/// Сводка по тому: сколько всего, занято, свободно.
struct VolumeInfo: Sendable {
    var total: Int64 = 0
    var free: Int64 = 0
    var name: String = "Macintosh HD"
    var used: Int64 { max(0, total - free) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum Tab: String, CaseIterable, Identifiable {
    case overview = "Обзор"
    case explorer = "Папки"
    case junk = "Очистка"
    case simulators = "Симуляторы"
    case docker = "Docker"
    case android = "Android"
    case devtools = "Инструменты"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: return "chart.pie"
        case .explorer: return "folder"
        case .junk: return "sparkles"
        case .simulators: return "iphone.gen3"
        case .docker: return "shippingbox"
        case .android: return "smartphone"
        case .devtools: return "wrench.and.screwdriver"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var tab: Tab = CommandLine.arguments.contains("--simulators") ? .simulators : CommandLine.arguments.contains("--docker") ? .docker : CommandLine.arguments.contains("--android") ? .android : CommandLine.arguments.contains("--junk") ? .junk : CommandLine.arguments.contains("--devtools") ? .devtools : .overview
    @Published var volume = VolumeInfo()

    // Скан папок
    @Published var root: FileNode?
    @Published var currentNode: FileNode?
    @Published var isScanning = false
    @Published var scanProgress = ScanProgress()
    @Published var scanRootPath: String = NSHomeDirectory()

    // Очистка
    @Published var junkGroups: [JunkGroup] = []
    @Published var isFindingJunk = false
    @Published var junkStatus: String = ""
    @Published var lastOutcome: SafeDelete.Outcome?
    @Published var deleteError: String?

    @AppStorage("permanentDelete") var permanentDelete = false
    /// Прятать находки, менявшиеся за последние 7 дней — для тех, кто чистит между спринтами.
    @AppStorage("hideRecentJunk") var hideRecentJunk = false

    // Симуляторы
    @Published var simGroups: [SimGroup] = []
    @Published var simSelection: Set<String> = []
    @Published var isLoadingSims = false
    @Published var isWorkingSims = false
    @Published var simStatus = ""
    @Published var simError: String?
    @Published var simFreed: Int64 = 0
    private let simulators = SimulatorManager()

    // Docker
    @Published var docker = DockerSnapshot()
    @Published var dockerState: DockerState = .unknown
    @Published var dockerSelection: Set<String> = []   // id образов/контейнеров/томов
    @Published var isWorkingDocker = false
    @Published var dockerStatus = ""
    @Published var dockerError: String?
    @Published var dockerFreed: Int64 = 0
    private let dockerManager = DockerManager()

    enum DockerState { case unknown, notInstalled, daemonDown, starting, ready }

    // Android
    @Published var android = AndroidSnapshot()
    @Published var androidLoaded = false
    @Published var androidSelection: Set<String> = []   // id AVD и пакетов
    @Published var isWorkingAndroid = false
    @Published var androidStatus = ""
    @Published var androidError: String?
    @Published var androidFreed: Int64 = 0
    private let androidManager = AndroidManager()
    var androidInstalled: Bool { androidManager.isInstalled }

    // Инструменты разработки
    @Published var devGroups: [DevGroup] = []
    @Published var devLoaded = false
    @Published var isWorkingDev = false
    @Published var devSelection: Set<String> = []
    @Published var devStatus = ""
    @Published var devError: String?
    @Published var devFreed: Int64 = 0
    private let devManager = DevToolsManager()

    private var scanner: DiskScanner?
    private var finder: JunkFinder?

    var selectedJunkSize: Int64 { junkGroups.reduce(0) { $0 + $1.selectedSize } }
    var selectedJunkCount: Int { junkGroups.reduce(0) { $0 + $1.selectedCount } }
    var totalJunkSize: Int64 { junkGroups.reduce(0) { $0 + $1.totalSize } }

    func refreshVolume() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeNameKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return }
        var info = VolumeInfo()
        info.total = Int64(values.volumeTotalCapacity ?? 0)
        // "ForImportantUsage" отражает то, что реально освободит система,
        // включая вытеснение очищаемого кэша — это ближе к цифре в «Об этом Mac».
        info.free = values.volumeAvailableCapacityForImportantUsage ?? 0
        info.name = values.volumeName ?? "Macintosh HD"
        volume = info
    }

    // MARK: - Скан папок

    func startScan(path: String? = nil) {
        if let path { scanRootPath = path }
        guard !isScanning else { return }
        isScanning = true
        scanProgress = ScanProgress()
        root = nil
        currentNode = nil

        let rootURL = URL(fileURLWithPath: scanRootPath)
        let scanner = DiskScanner { [weak self] progress in
            Task { @MainActor in self?.scanProgress = progress }
        }
        self.scanner = scanner

        Task.detached(priority: .userInitiated) {
            let result = scanner.scan(root: rootURL)
            await MainActor.run {
                self.root = result
                self.currentNode = result
                self.isScanning = false
            }
        }
    }

    func cancelScan() {
        scanner?.cancel()
        isScanning = false
    }

    func drillInto(_ node: FileNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        currentNode = node
    }

    func goUp() {
        if let parent = currentNode?.parent { currentNode = parent }
    }

    // MARK: - Очистка

    func findJunk() {
        guard !isFindingJunk else { return }
        isFindingJunk = true
        junkGroups = []
        lastOutcome = nil
        junkStatus = "Подготовка…"

        let finder = JunkFinder()
        self.finder = finder

        Task.detached(priority: .userInitiated) {
            let groups = finder.findAll { title in
                Task { @MainActor in self.junkStatus = "Ищу: \(title)" }
            }
            await MainActor.run {
                self.junkGroups = groups
                self.isFindingJunk = false
                self.junkStatus = groups.isEmpty ? "Ничего лишнего не найдено" : ""
            }
        }
    }

    func cancelJunkSearch() {
        finder?.cancel()
        isFindingJunk = false
        junkStatus = "Поиск отменён"
    }

    func toggle(item: JunkItem) {
        guard let g = junkGroups.firstIndex(where: { $0.id == item.categoryID }),
              let i = junkGroups[g].items.firstIndex(where: { $0.id == item.id }) else { return }
        junkGroups[g].items[i].isSelected.toggle()
    }

    func setSelection(groupID: String, selected: Bool) {
        guard let g = junkGroups.firstIndex(where: { $0.id == groupID }) else { return }
        for i in junkGroups[g].items.indices where !(hideRecentJunk && junkGroups[g].items[i].isRecent) {
            junkGroups[g].items[i].isSelected = selected
        }
    }

    func visibleItems(_ group: JunkGroup) -> [JunkItem] {
        hideRecentJunk ? group.items.filter { !$0.isRecent } : group.items
    }

    /// Выбирает только категории с safety == .safe — то, что система пересоздаст сама.
    func selectSafeOnly() {
        for g in junkGroups.indices {
            let safe = junkGroups[g].category.safety == .safe
            for i in junkGroups[g].items.indices {
                junkGroups[g].items[i].isSelected = safe && !(hideRecentJunk && junkGroups[g].items[i].isRecent)
            }
        }
    }

    func deselectRecent() {
        for g in junkGroups.indices {
            for i in junkGroups[g].items.indices where junkGroups[g].items[i].isRecent {
                junkGroups[g].items[i].isSelected = false
            }
        }
    }

    func deselectAll() {
        for g in junkGroups.indices {
            for i in junkGroups[g].items.indices {
                junkGroups[g].items[i].isSelected = false
            }
        }
    }

    func deleteSelected() {
        let items = junkGroups.flatMap { $0.items.filter(\.isSelected) }
        guard !items.isEmpty else { return }
        let permanently = permanentDelete

        Task.detached(priority: .userInitiated) {
            let outcome = SafeDelete.delete(items: items, permanently: permanently)
            await MainActor.run {
                self.lastOutcome = outcome
                let deleted = Set(items.map(\.url))
                // Удалённое убираем из списка, неудавшееся оставляем видимым.
                let failed = Set(outcome.failures.map(\.path))
                for g in self.junkGroups.indices {
                    self.junkGroups[g].items.removeAll {
                        deleted.contains($0.url) && !failed.contains($0.displayPath)
                    }
                }
                self.junkGroups.removeAll { $0.items.isEmpty }
                self.refreshVolume()
            }
        }
    }

    // MARK: - Симуляторы

    var selectedSimDevices: [SimDevice] {
        simGroups.flatMap { $0.devices.filter { simSelection.contains($0.id) } }
    }
    var selectedSimSize: Int64 { selectedSimDevices.reduce(0) { $0 + $1.size } }
    var simTotalSize: Int64 { simGroups.reduce(0) { $0 + $1.totalSize } }

    func loadSimulators() {
        guard !isLoadingSims else { return }
        isLoadingSims = true
        simError = nil
        Task.detached(priority: .userInitiated) { [simulators] in
            do {
                let groups = try simulators.load()
                await MainActor.run {
                    self.simGroups = groups
                    self.simSelection = self.simSelection.filter { id in groups.contains { $0.devices.contains { $0.id == id } } }
                    self.isLoadingSims = false
                }
            } catch {
                await MainActor.run {
                    self.simError = error.localizedDescription
                    self.isLoadingSims = false
                }
            }
        }
    }

    /// Выбирает устройства с данными, не запускавшиеся дольше `days` дней.
    func selectStaleSimulators(days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        simSelection = Set(simGroups.flatMap { $0.devices }
            .filter { !$0.isStub && ($0.lastBooted ?? .distantPast) < cutoff }
            .map(\.id))
    }

    /// Стереть содержимое или удалить целиком — оба пути через simctl.
    func applySimAction(delete: Bool) {
        let targets = selectedSimDevices
        guard !targets.isEmpty, !isWorkingSims else { return }
        isWorkingSims = true
        simError = nil
        Task.detached(priority: .userInitiated) { [simulators] in
            var freed: Int64 = 0
            var failures: [String] = []
            for device in targets {
                await MainActor.run { self.simStatus = "\(delete ? "Удаляю" : "Стираю"): \(device.name)" }
                do {
                    if delete { try simulators.delete(udid: device.id) } else { try simulators.erase(udid: device.id) }
                    freed += device.size
                } catch {
                    failures.append("\(device.name): \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                self.simFreed = freed
                self.simStatus = ""
                self.isWorkingSims = false
                self.simSelection = []
                if !failures.isEmpty { self.simError = failures.joined(separator: "\n") }
                self.loadSimulators()
                self.refreshVolume()
            }
        }
    }

    func deleteRuntime(_ runtime: SimRuntime) {
        guard !isWorkingSims else { return }
        isWorkingSims = true
        simStatus = "Удаляю рантайм \(runtime.title)"
        Task.detached(priority: .userInitiated) { [simulators] in
            do {
                try simulators.deleteRuntime(id: runtime.id)
                await MainActor.run { self.simFreed = runtime.size }
            } catch {
                await MainActor.run { self.simError = error.localizedDescription }
            }
            await MainActor.run {
                self.simStatus = ""
                self.isWorkingSims = false
                self.loadSimulators()
                self.refreshVolume()
            }
        }
    }

    func clearKeyboardCache(_ device: SimDevice) {
        guard !isWorkingSims else { return }
        isWorkingSims = true
        simStatus = "Удаляю кэш клавиатуры: \(device.name)"
        Task.detached(priority: .userInitiated) { [simulators] in
            do {
                try simulators.clearKeyboardCache(device: device)
                await MainActor.run { self.simFreed = device.keyboardCacheSize }
            } catch {
                await MainActor.run { self.simError = error.localizedDescription }
            }
            await MainActor.run {
                self.simStatus = ""
                self.isWorkingSims = false
                self.loadSimulators()
                self.refreshVolume()
            }
        }
    }

    /// Открывает данные устройства в разделе «Папки» — видно, что именно занимает место.
    func exploreSimulator(_ device: SimDevice) {
        tab = .explorer
        startScan(path: device.dataPath)
    }

    func deleteUnavailableSimulators() {
        guard !isWorkingSims else { return }
        isWorkingSims = true
        simStatus = "Удаляю недоступные устройства"
        Task.detached(priority: .userInitiated) { [simulators] in
            do { try simulators.deleteUnavailable() }
            catch { await MainActor.run { self.simError = error.localizedDescription } }
            await MainActor.run {
                self.simStatus = ""
                self.isWorkingSims = false
                self.loadSimulators()
            }
        }
    }

    // MARK: - Docker

    var selectedDockerImages: [DockerImage] { docker.images.filter { dockerSelection.contains($0.id) } }
    var selectedDockerContainers: [DockerContainer] { docker.containers.filter { dockerSelection.contains($0.id) } }
    var selectedDockerVolumes: [DockerVolume] { docker.volumes.filter { dockerSelection.contains($0.id) } }
    var selectedDockerSize: Int64 {
        selectedDockerImages.reduce(0) { $0 + $1.size }
            + selectedDockerContainers.reduce(0) { $0 + $1.size }
            + selectedDockerVolumes.reduce(0) { $0 + $1.size }
    }
    var selectedDockerCount: Int { dockerSelection.count }

    func loadDocker() {
        guard !isWorkingDocker else { return }
        guard dockerManager.isInstalled else { dockerState = .notInstalled; return }
        isWorkingDocker = true
        dockerStatus = "Опрашиваю docker…"
        Task.detached(priority: .userInitiated) { [dockerManager] in
            guard dockerManager.isDaemonRunning() else {
                await MainActor.run { self.dockerState = .daemonDown; self.isWorkingDocker = false; self.dockerStatus = "" }
                return
            }
            do {
                let snapshot = try dockerManager.load()
                await MainActor.run {
                    self.docker = snapshot
                    self.dockerState = .ready
                    let valid = Set(snapshot.images.map(\.id) + snapshot.containers.map(\.id) + snapshot.volumes.map(\.id))
                    self.dockerSelection = self.dockerSelection.intersection(valid)
                }
            } catch {
                await MainActor.run { self.dockerError = error.localizedDescription }
            }
            await MainActor.run { self.isWorkingDocker = false; self.dockerStatus = "" }
        }
    }

    /// Запускает Docker Desktop и ждёт демона до минуты.
    func startDocker() {
        dockerState = .starting
        dockerManager.startDesktop()
        Task.detached(priority: .userInitiated) { [dockerManager] in
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if dockerManager.isDaemonRunning() {
                    await MainActor.run { self.loadDocker() }
                    return
                }
            }
            await MainActor.run { self.dockerState = .daemonDown; self.dockerError = "Docker Desktop не запустился за минуту" }
        }
    }

    /// Выбирает образы без контейнеров старше `days` дней (и все dangling).
    func selectUnusedDockerImages(days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        dockerSelection = Set(docker.images.filter { image in
            !image.inUse && (image.isDangling || (image.createdAt ?? .distantPast) < cutoff)
        }.map(\.id))
    }

    func selectStoppedContainers() {
        dockerSelection = Set(docker.containers.filter { !$0.isRunning }.map(\.id))
    }

    func selectUnusedVolumes() {
        dockerSelection = Set(docker.volumes.filter { !$0.inUse }.map(\.id))
    }

    func removeSelectedDocker() {
        let images = selectedDockerImages, containers = selectedDockerContainers, volumes = selectedDockerVolumes
        guard !(images.isEmpty && containers.isEmpty && volumes.isEmpty), !isWorkingDocker else { return }
        isWorkingDocker = true
        dockerError = nil
        Task.detached(priority: .userInitiated) { [dockerManager] in
            var freed: Int64 = 0
            var failures: [String] = []
            // Порядок важен: контейнеры держат образы и тома.
            for c in containers {
                await MainActor.run { self.dockerStatus = "Удаляю контейнер \(c.name)" }
                do { try dockerManager.removeContainer(c); freed += c.size } catch { failures.append("\(c.name): \(error.localizedDescription)") }
            }
            for i in images {
                await MainActor.run { self.dockerStatus = "Удаляю образ \(i.title)" }
                do { try dockerManager.removeImage(i); freed += i.uniqueSize } catch { failures.append("\(i.title): \(error.localizedDescription)") }
            }
            for v in volumes {
                await MainActor.run { self.dockerStatus = "Удаляю том \(v.title)" }
                do { try dockerManager.removeVolume(v); freed += v.size } catch { failures.append("\(v.title): \(error.localizedDescription)") }
            }
            await MainActor.run {
                self.dockerFreed = freed
                self.dockerSelection = []
                self.isWorkingDocker = false
                self.dockerStatus = ""
                if !failures.isEmpty { self.dockerError = failures.prefix(5).joined(separator: "\n") }
                self.loadDocker()
                self.refreshVolume()
            }
        }
    }

    func pruneDockerBuildCache() {
        guard !isWorkingDocker else { return }
        isWorkingDocker = true
        dockerStatus = "Чищу кэш сборки…"
        let expected = docker.buildCacheUnused
        Task.detached(priority: .userInitiated) { [dockerManager] in
            do { try dockerManager.pruneBuildCache(); await MainActor.run { self.dockerFreed = expected } }
            catch { await MainActor.run { self.dockerError = error.localizedDescription } }
            await MainActor.run { self.isWorkingDocker = false; self.dockerStatus = ""; self.loadDocker() }
        }
    }

    // MARK: - Android

    var selectedAVDs: [AndroidAVD] { android.avds.filter { androidSelection.contains($0.id) } }
    var selectedAndroidPackages: [AndroidPackage] { android.packages.filter { androidSelection.contains($0.id) } }
    var selectedAndroidSize: Int64 {
        selectedAVDs.reduce(0) { $0 + $1.size } + selectedAndroidPackages.reduce(0) { $0 + $1.size }
    }

    func loadAndroid() {
        guard !isWorkingAndroid else { return }
        isWorkingAndroid = true
        androidStatus = "Считаю размеры…"
        Task.detached(priority: .userInitiated) { [androidManager] in
            do {
                let snapshot = try androidManager.load()
                await MainActor.run {
                    self.android = snapshot
                    self.androidLoaded = true
                    let valid = Set(snapshot.avds.map(\.id) + snapshot.packages.map(\.id))
                    self.androidSelection = self.androidSelection.intersection(valid)
                }
            } catch {
                await MainActor.run { self.androidError = error.localizedDescription }
            }
            await MainActor.run { self.isWorkingAndroid = false; self.androidStatus = "" }
        }
    }

    /// Выбирает старые версии каждого компонента, оставляя самую новую.
    func selectOldAndroidVersions() {
        var selection = Set<String>()
        for kind in AndroidPackage.Kind.allCases where kind != .systemImage {
            // Самую новую ищем только среди реально установленных: пустая папка
            // от прерванной загрузки NDK 29 иначе «защитила» бы себя, а рабочий 28 попал бы под нож.
            let installed = android.packages(of: kind).filter(\.isRegistered)
                .sorted { $0.title.compare($1.title, options: .numeric) == .orderedDescending }
            selection.formUnion(installed.dropFirst().map(\.id))
        }
        // Образы без AVD и остатки прерванных загрузок.
        selection.formUnion(android.packages.filter { ($0.kind == .systemImage && !$0.inUse) || !$0.isRegistered }.map(\.id))
        androidSelection = selection
    }

    enum AndroidAction { case deleteSnapshots, wipeData, delete }

    func applyAndroidAction(_ action: AndroidAction) {
        let avds = selectedAVDs, packages = action == .delete ? selectedAndroidPackages : []
        guard !(avds.isEmpty && packages.isEmpty), !isWorkingAndroid else { return }
        isWorkingAndroid = true
        androidError = nil
        Task.detached(priority: .userInitiated) { [androidManager] in
            var freed: Int64 = 0
            var failures: [String] = []
            for avd in avds {
                await MainActor.run { self.androidStatus = "\(avd.displayName)…" }
                do {
                    switch action {
                    case .deleteSnapshots: try androidManager.deleteSnapshots(avd); freed += avd.snapshotsSize
                    case .wipeData: try androidManager.wipeData(avd); freed += avd.snapshotsSize + avd.userDataSize
                    case .delete: try androidManager.deleteAVD(avd); freed += avd.size
                    }
                } catch { failures.append("\(avd.displayName): \(error.localizedDescription)") }
            }
            for package in packages {
                await MainActor.run { self.androidStatus = "Удаляю \(package.title)…" }
                do { try androidManager.uninstall(package); freed += package.size }
                catch { failures.append("\(package.title): \(error.localizedDescription)") }
            }
            await MainActor.run {
                self.androidFreed = freed
                self.androidSelection = []
                self.isWorkingAndroid = false
                self.androidStatus = ""
                if !failures.isEmpty { self.androidError = failures.prefix(5).joined(separator: "\n") }
                self.loadAndroid()
                self.refreshVolume()
            }
        }
    }

    // MARK: - Инструменты разработки

    var devTotal: Int64 { devGroups.reduce(0) { $0 + $1.size } }
    var selectedDevEntries: [DevEntry] { devGroups.flatMap { $0.entries.filter { devSelection.contains($0.id) } } }
    var selectedDevSize: Int64 { selectedDevEntries.reduce(0) { $0 + $1.size } }

    func loadDevTools() {
        guard !isWorkingDev else { return }
        isWorkingDev = true
        devStatus = "Считаю размеры…"
        let roots = [NSHomeDirectory() + "/source", NSHomeDirectory() + "/Projects", NSHomeDirectory() + "/dev", NSHomeDirectory() + "/Developer"]
            .filter { FileManager.default.fileExists(atPath: $0) }
        Task.detached(priority: .userInitiated) { [devManager] in
            let groups = devManager.load(sourceRoots: roots)
            await MainActor.run {
                self.devGroups = groups
                self.devLoaded = true
                let valid = Set(groups.flatMap { $0.entries.map(\.id) })
                self.devSelection = self.devSelection.intersection(valid)
                self.isWorkingDev = false
                self.devStatus = ""
            }
        }
    }

    /// Всё с пометкой «безопасно», что никем не используется.
    func selectSafeDev() {
        devSelection = Set(devGroups.flatMap { $0.entries.filter { $0.safety == .safe && !$0.inUse }.map(\.id) })
    }

    func cleanupSelectedDev() {
        let targets = selectedDevEntries
        guard !targets.isEmpty, !isWorkingDev else { return }
        isWorkingDev = true
        devError = nil
        Task.detached(priority: .userInitiated) { [devManager] in
            var freed: Int64 = 0
            var failures: [String] = []
            for e in targets {
                await MainActor.run { self.devStatus = "\(e.title)…" }
                do { try devManager.cleanup(e); freed += e.size }
                catch { failures.append("\(e.title): \(devManager.lastCommandError ?? error.localizedDescription)") }
            }
            await MainActor.run {
                self.devFreed = freed
                self.devSelection = []
                self.isWorkingDev = false
                self.devStatus = ""
                if !failures.isEmpty { self.devError = failures.prefix(5).joined(separator: "\n") }
                self.loadDevTools()
                self.refreshVolume()
            }
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Форматирование байтов в человекочитаемый вид — используется повсеместно.
func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useGB, .useMB, .useKB, .useTB]
    formatter.allowsNonnumericFormatting = false   // "0 KB" вместо "Zero KB"
    return formatter.string(fromByteCount: bytes)
}
