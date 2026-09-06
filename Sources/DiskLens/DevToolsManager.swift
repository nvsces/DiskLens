import Foundation
import AppKit

/// Кэш, индекс или тулчейн инструмента разработки.
struct DevEntry: Identifiable, Sendable {
    enum Cleanup: Sendable {
        case trash                              // в Корзину — инструмент пересоздаст
        case command([String])                  // родная команда очистки (argv)
        case commandOrTrash([String])           // родная команда; если инструмент удалён — в Корзину
        case remove                             // rm: Корзина не принимает такие объёмы разумно (модели)
        case ollama(String)                     // ollama rm; если сервер не поднят — удаляем блобы сами
    }
    let id: String
    let group: String
    let title: String
    let path: String
    let size: Int64
    let safety: JunkSafety
    let explanation: String
    let cleanup: Cleanup
    var inUse: Bool = false          // активный тулчейн, версия, на которую ссылаются проекты
    var usedBy: [String] = []

    var displayPath: String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
    var commandText: String? {
        switch cleanup {
        case .command(let argv), .commandOrTrash(let argv): return argv.joined(separator: " ")
        case .ollama(let name): return "ollama rm \(name)"
        default: return nil
        }
    }
}

struct DevGroup: Identifiable, Sendable {
    let id: String
    let symbol: String
    var entries: [DevEntry]
    var size: Int64 { entries.reduce(0) { $0 + $1.size } }
}

/// Правила по инструментам. Порядок групп — как в интерфейсе.
final class DevToolsManager: @unchecked Sendable {
    private let home = NSHomeDirectory()
    private var cancelled = false

    func cancel() { cancelled = true }

    func load(sourceRoots: [String]) -> [DevGroup] {
        cancelled = false
        var groups: [DevGroup] = []
        groups.append(DevGroup(id: "Индексы", symbol: "text.magnifyingglass", entries: indexes(sourceRoots: sourceRoots)))
        groups.append(DevGroup(id: "Xcode и Swift", symbol: "hammer", entries: xcode()))
        groups.append(DevGroup(id: "Flutter и Dart", symbol: "bird", entries: flutter(sourceRoots: sourceRoots)))
        groups.append(DevGroup(id: "Go", symbol: "g.circle", entries: go()))
        groups.append(DevGroup(id: "Rust", symbol: "gearshape.2", entries: rust()))
        groups.append(DevGroup(id: "JVM и Android", symbol: "cup.and.saucer", entries: jvm()))
        groups.append(DevGroup(id: "JavaScript", symbol: "curlybraces", entries: js()))
        groups.append(DevGroup(id: "Python", symbol: "chevron.left.forwardslash.chevron.right", entries: python()))
        groups.append(DevGroup(id: "Модели ИИ", symbol: "brain", entries: models()))
        groups.append(DevGroup(id: "IDE и Homebrew", symbol: "macwindow", entries: ide()))
        return groups.map { g in var g = g; g.entries.sort { $0.size > $1.size }; return g }.filter { !$0.entries.isEmpty }
    }

    // MARK: - Группы

    private func indexes(sourceRoots: [String]) -> [DevEntry] {
        var e: [DevEntry] = []
        e += entry("Индексы", "Dart Analysis Server", home + "/.dartServer", .safe,
                   "Индексы анализатора для каждого открытого Dart-проекта. Пересоздаются при открытии проекта в IDE — первые минуты анализ будет медленнее.", .trash)
        e += entry("Индексы", "Xcode ModuleCache", home + "/Library/Developer/Xcode/DerivedData/ModuleCache.noindex", .safe,
                   "Скомпилированные модули Clang/Swift, общие для проектов. Первая сборка после очистки дольше.", .trash)
        e += entry("Индексы", "Xcode SymbolCache", home + "/Library/Developer/Xcode/DerivedData/SymbolCache.noindex", .safe,
                   "Символы для отладчика. Пересоздаются.", .trash)
        e += entry("Индексы", "Кэш Xcode", home + "/Library/Caches/com.apple.dt.Xcode", .safe, "Кэш IDE: превью документации, загрузки. Пересоздаётся.", .trash)
        e += entry("Индексы", "SwiftUI Previews", home + "/Library/Developer/Xcode/UserData/Previews", .safe, "Сборки для канвы превью. Пересоздаются при открытии превью.", .trash)
        e += entry("Индексы", "XCTestDevices", home + "/Library/Developer/XCTestDevices", .safe, "Клоны симуляторов для параллельных тестов. Xcode создаёт заново.", .trash)
        e += entry("Индексы", "SourceKit-LSP", home + "/Library/Caches/sourcekit-lsp", .safe, "Индекс для автодополнения вне Xcode (VS Code, Cursor).", .trash)
        // Индексы внутри DerivedData каждого проекта — самая крупная часть, и её можно убирать без пересборки.
        let dd = home + "/Library/Developer/Xcode/DerivedData"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dd)) ?? [] where !name.hasSuffix(".noindex") {
            let idx = dd + "/" + name + "/Index.noindex"
            e += entry("Индексы", "Индекс \(name.split(separator: "-").first.map(String.init) ?? name)", idx, .safe,
                       "Индекс Xcode для навигации и автодополнения. Сборка не затрагивается, индексация повторится в фоне.", .trash, minSize: 10 << 20)
        }
        // Индексы в проектах: SourceKit-LSP (.build/index-build), JetBrains (.idea/caches).
        for path in find(in: sourceRoots, names: ["index-build", ".index-build"], depth: 6, minSize: 20 << 20) {
            e += entry("Индексы", "SourceKit-LSP · " + projectName(path), path, .safe, "Индекс SwiftPM-проекта для LSP. Пересоздаётся.", .trash)
        }
        return e
    }

    private func xcode() -> [DevEntry] {
        var e: [DevEntry] = []
        e += entry("Xcode и Swift", "Кэш SwiftPM", home + "/Library/Caches/org.swift.swiftpm", .safe,
                   "Скачанные исходники пакетов и манифесты. Повторно скачиваются при resolve.", .command(["swift", "package", "purge-cache"]))
        e += entry("Xcode и Swift", "SwiftPM security/config", home + "/Library/org.swift.swiftpm", .review, "Настройки и зеркала SwiftPM. Мал, но лучше не трогать.", .trash, minSize: 1 << 20)
        e += entry("Xcode и Swift", "Xcode Products", home + "/Library/Developer/Xcode/Products", .safe, "Продукты Archive → Distribute. Уже экспортированы.", .trash)
        e += entry("Xcode и Swift", "IB Support", home + "/Library/Developer/Xcode/UserData/IB Support", .safe, "Кэш Interface Builder.", .trash)
        return e
    }

    private func flutter(sourceRoots: [String]) -> [DevEntry] {
        var e: [DevEntry] = []
        // Какие версии Flutter пинят проекты (.fvmrc / .fvm/fvm_config.json).
        var pinned: [String: [String]] = [:]
        for cfg in find(in: sourceRoots, names: [".fvmrc", "fvm_config.json"], depth: 5, minSize: 0, files: true) {
            guard let text = try? String(contentsOfFile: cfg, encoding: .utf8),
                  let m = text.range(of: #""flutter(?:Sdk)?(?:Version)?"\s*:\s*"([^"]+)""#, options: .regularExpression) else { continue }
            let v = String(text[m]).split(separator: "\"").last.map(String.init) ?? ""
            pinned[v, default: []].append(projectName(cfg))
        }
        let fvm = home + "/fvm/versions"
        let defaultVersion = (try? FileManager.default.destinationOfSymbolicLink(atPath: home + "/fvm/default")).map { ($0 as NSString).lastPathComponent }
        let fvmInstalled = toolExists("fvm")
        for v in (try? FileManager.default.contentsOfDirectory(atPath: fvm)) ?? [] where !v.hasPrefix(".") {
            let users = pinned[v] ?? []
            var en = DevEntry(id: fvm + "/" + v, group: "Flutter и Dart", title: "fvm · Flutter \(v)", path: fvm + "/" + v,
                              size: directorySize(fvm + "/" + v), safety: users.isEmpty ? .review : .risky,
                              explanation: !users.isEmpty ? "Пинят: \(users.joined(separator: ", "))."
                                  : fvmInstalled ? "Ни один проект не пинит эту версию в .fvmrc. fvm install вернёт при необходимости."
                                  : "Сам fvm не установлен — это остатки прошлой установки, полный клон Flutter SDK (\(v)).",
                              cleanup: .commandOrTrash(["fvm", "remove", v]))
            en.inUse = !users.isEmpty || defaultVersion == v
            en.usedBy = users
            e.append(en)
        }
        e += entry("Flutter и Dart", fvmInstalled ? "fvm · git-кэш" : "fvm · остатки git-кэша", home + "/fvm/cache.git", .safe,
                   fvmInstalled ? "Зеркало репозитория Flutter, из которого fvm разворачивает версии." : "Остаток удалённого fvm.", .trash)
        e += entry("Flutter и Dart", "pub cache", home + "/.pub-cache", .safe,
                   "Все скачанные пакеты Dart. dart pub cache clean удаляет всё; при следующем pub get нужные скачаются снова.", .command(["dart", "pub", "cache", "clean", "-f"]))
        if let sdk = flutterSDK() {
            e += entry("Flutter и Dart", "Артефакты движка", sdk + "/bin/cache/artifacts", .safe,
                       "Движки для всех платформ (iOS, Android, web, macOS…). flutter precache скачает нужные при следующей сборке.", .trash)
            e += entry("Flutter и Dart", "Загрузки Flutter", sdk + "/bin/cache/downloads", .safe, "Архивы, из которых распакованы артефакты. Не нужны после распаковки.", .trash)
        }
        return e
    }

    private func go() -> [DevEntry] {
        var e: [DevEntry] = []
        e += entry("Go", "Кэш сборки", home + "/Library/Caches/go-build", .safe, "Результаты компиляции пакетов. Следующая сборка с нуля.", .command(["go", "clean", "-cache"]))
        e += entry("Go", "Кэш модулей", home + "/go/pkg/mod", .safe,
                   "Исходники всех зависимостей всех версий. Заново скачиваются при go build — нужен интернет и время.", .command(["go", "clean", "-modcache"]))
        return e
    }

    private func rust() -> [DevEntry] {
        var e: [DevEntry] = []
        let list = run(["rustup", "toolchain", "list"]) ?? ""
        for line in list.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard let name = parts.first.map(String.init) else { continue }
            let active = line.contains("default") || line.contains("active")
            let path = home + "/.rustup/toolchains/" + name
            var en = DevEntry(id: path, group: "Rust", title: "rustup · \(name)", path: path, size: directorySize(path),
                              safety: active ? .risky : .review,
                              explanation: active ? "Активный тулчейн по умолчанию." : (name.contains("x86_64") ? "Тулчейн для Intel на Apple Silicon — нужен только для кросс-сборки." : "Неактивный тулчейн. rustup toolchain install вернёт."),
                              cleanup: .command(["rustup", "toolchain", "uninstall", name]))
            en.inUse = active
            e.append(en)
        }
        e += entry("Rust", "Cargo registry", home + "/.cargo/registry", .safe, "Скачанные crates. Заново скачаются при сборке.", .trash)
        e += entry("Rust", "Cargo git", home + "/.cargo/git", .safe, "Зависимости из git-репозиториев.", .trash)
        return e
    }

    private func jvm() -> [DevEntry] {
        var e: [DevEntry] = []
        e += entry("JVM и Android", "Gradle caches", home + "/.gradle/caches", .safe, "Зависимости и кэш сборки Gradle. Скачаются заново.", .trash)
        e += entry("JVM и Android", "Gradle daemon", home + "/.gradle/daemon", .safe, "Логи и данные демонов. Перед удалением демоны останавливаются.", .command(["sh", "-c", "(gradle --stop 2>/dev/null || true); rm -rf \"$HOME/.gradle/daemon\""]))
        e += entry("JVM и Android", "Gradle wrapper", home + "/.gradle/wrapper", .review, "Дистрибутивы Gradle разных версий. Проект скачает свою при сборке (100+ MB каждая).", .trash)
        e += entry("JVM и Android", "Android build cache", home + "/.android/build-cache", .safe, "Кэш сборки Android.", .trash)
        e += entry("JVM и Android", "Android cache", home + "/.android/cache", .safe, "Кэш SDK Manager.", .trash)
        e += entry("JVM и Android", "Maven .m2", home + "/.m2/repository", .safe, "Локальный репозиторий Maven.", .trash)
        e += entry("JVM и Android", "Kotlin/Native", home + "/.konan", .safe, "Тулчейны Kotlin/Native. Скачаются при сборке.", .trash)
        return e
    }

    private func js() -> [DevEntry] {
        var e: [DevEntry] = []
        e += entry("JavaScript", "npm cache", home + "/.npm/_cacache", .safe, "Кэш пакетов npm.", .command(["npm", "cache", "clean", "--force"]))
        e += entry("JavaScript", "npx cache", home + "/.npm/_npx", .safe, "Пакеты, запускавшиеся через npx. Скачаются при следующем запуске.", .trash)
        e += entry("JavaScript", "Yarn cache", home + "/Library/Caches/Yarn", .safe, "Кэш Yarn classic.", .trash)
        e += entry("JavaScript", "Yarn berry", home + "/.yarn/berry/cache", .safe, "Кэш Yarn 2+.", .trash)
        e += entry("JavaScript", "pnpm store", home + "/Library/pnpm/store", .safe, "Хранилище pnpm.", .command(["pnpm", "store", "prune"]))
        e += entry("JavaScript", "node-gyp", home + "/.node-gyp", .safe, "Заголовки Node для нативных модулей.", .trash)
        e += entry("JavaScript", "nvm cache", home + "/.nvm/.cache", .safe, "Архивы дистрибутивов Node.", .trash)
        e += entry("JavaScript", "Puppeteer", home + "/.cache/puppeteer", .safe, "Скачанные браузеры Chromium. Скачаются при npm install.", .trash)
        e += entry("JavaScript", "Cypress", home + "/.cache/Cypress", .safe, "Бинарники Cypress.", .trash)
        e += entry("JavaScript", "Bun", home + "/.bun/install/cache", .safe, "Кэш Bun.", .trash)
        return e
    }

    private func python() -> [DevEntry] {
        var e: [DevEntry] = []
        e += entry("Python", "pip cache", home + "/Library/Caches/pip", .safe, "Скачанные wheel'ы.", .command(["python3", "-m", "pip", "cache", "purge"]))
        e += entry("Python", "uv cache", home + "/.cache/uv", .safe, "Кэш uv.", .command(["uv", "cache", "clean"]))
        e += entry("Python", "pipx", home + "/.local/pipx/.cache", .safe, "Кэш pipx.", .trash)
        return e
    }

    private func models() -> [DevEntry] {
        var e: [DevEntry] = []
        // Ollama: модели лежат блобами, имена — в manifests. Размер модели = сумма её блобов.
        let manifests = home + "/.ollama/models/manifests"
        let blobs = home + "/.ollama/models/blobs"
        if let en = FileManager.default.enumerator(atPath: manifests) {
            for case let rel as String in en {
                let full = manifests + "/" + rel
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue,
                      let data = FileManager.default.contents(atPath: full),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                var size: Int64 = 0
                let layers = (obj["layers"] as? [[String: Any]] ?? []) + [(obj["config"] as? [String: Any]) ?? [:]]
                for l in layers { size += Int64(l["size"] as? Int ?? 0) }
                // registry.ollama.ai/library/llama3/latest → llama3:latest
                let parts = rel.split(separator: "/").map(String.init)
                let name = parts.count >= 2 ? "\(parts[parts.count - 2]):\(parts[parts.count - 1])" : rel
                e.append(DevEntry(id: "ollama:" + name, group: "Модели ИИ", title: "Ollama · \(name)", path: full, size: size, safety: .review,
                                  explanation: "Модель Ollama. ollama pull \(name) скачает снова.", cleanup: .ollama(name)))
            }
        }
        let hf = home + "/.cache/huggingface/hub"
        for m in (try? FileManager.default.contentsOfDirectory(atPath: hf)) ?? [] where m.hasPrefix("models--") {
            let name = m.dropFirst(8).replacingOccurrences(of: "--", with: "/")
            e += entry("Модели ИИ", "HF · \(name)", hf + "/" + m, .review, "Модель из Hugging Face Hub. Скачается снова при использовании.", .remove, minSize: 10 << 20)
        }
        e += entry("Модели ИИ", "whisper cache", home + "/.cache/whisper", .safe, "Модели openai-whisper.", .trash)
        return e
    }

    private func ide() -> [DevEntry] {
        var e: [DevEntry] = []
        e += entry("IDE и Homebrew", "JetBrains caches", home + "/Library/Caches/JetBrains", .safe, "Индексы и кэши IDE JetBrains. Пересоздаются при открытии проекта.", .trash)
        for app in ["Code", "Cursor", "VSCodium"] {
            let base = home + "/Library/Application Support/" + app
            e += entry("IDE и Homebrew", "\(app) · Cache", base + "/Cache", .safe, "Кэш браузерного движка редактора.", .trash)
            e += entry("IDE и Homebrew", "\(app) · CachedData", base + "/CachedData", .safe, "Кэш скомпилированного кода редактора.", .trash)
            e += entry("IDE и Homebrew", "\(app) · GPUCache", base + "/GPUCache", .safe, "Кэш шейдеров.", .trash)
            e += entry("IDE и Homebrew", "\(app) · workspaceStorage", base + "/User/workspaceStorage", .review, "Состояние открытых папок: история, точки останова. Для закрытых проектов — мусор.", .trash)
        }
        e += entry("IDE и Homebrew", "Homebrew cache", home + "/Library/Caches/Homebrew", .safe, "Скачанные бутылки и архивы формул.", .command(["brew", "cleanup", "-s", "--prune=all"]))
        return e
    }

    // MARK: - Действия

    func cleanup(_ entry: DevEntry) throws {
        switch entry.cleanup {
        case .trash:
            guard SafeDelete.canDelete(entry.path) else { throw DevError("путь защищён") }
            try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
        case .remove:
            guard SafeDelete.canDelete(entry.path) else { throw DevError("путь защищён") }
            try FileManager.default.removeItem(atPath: entry.path)
        case .command(let argv):
            guard let out = run(argv, throwing: true) else { throw DevError(lastCommandError ?? "команда не выполнилась") }
            _ = out
        case .commandOrTrash(let argv):
            if run(argv, throwing: true) != nil { return }
            // Инструмент удалён, а его данные остались — убираем папку сами.
            guard toolExists(argv[0]) == false else { throw DevError(lastCommandError ?? "команда не выполнилась") }
            guard SafeDelete.canDelete(entry.path) else { throw DevError("путь защищён") }
            try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
        case .ollama(let name):
            try removeOllamaModel(name: name, manifest: entry.path)
        }
    }

    /// `ollama rm` требует запущенного сервера. Если его нет — поднимаем `ollama serve`
    /// на время операции; если и это не вышло, удаляем вручную: манифест плюс слои,
    /// на которые не ссылается ни одна другая модель.
    private func removeOllamaModel(name: String, manifest: String) throws {
        if run(["ollama", "rm", name], throwing: true) != nil { return }

        var startedServer: Process?
        if !ollamaResponds() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "ollama serve"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            startedServer = p
            for _ in 0..<20 {
                if ollamaResponds() { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        defer { startedServer?.terminate() }

        if ollamaResponds(), run(["ollama", "rm", name], throwing: true) != nil { return }
        try removeOllamaBlobs(manifest: manifest)
    }

    private func ollamaResponds() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "-m", "2", "-o", "/dev/null", "http://127.0.0.1:11434/api/tags"]
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Слой удаляем, только если на него не ссылается другой манифест —
    /// модели одного семейства делят слои между собой.
    private func removeOllamaBlobs(manifest: String) throws {
        let root = home + "/.ollama/models"
        guard let data = FileManager.default.contents(atPath: manifest),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DevError("не удалось прочитать манифест модели")
        }
        var mine = Set<String>()
        for layer in (obj["layers"] as? [[String: Any]] ?? []) + [(obj["config"] as? [String: Any]) ?? [:]] {
            if let digest = layer["digest"] as? String { mine.insert(digest.replacingOccurrences(of: ":", with: "-")) }
        }

        var used = Set<String>()
        if let en = FileManager.default.enumerator(atPath: root + "/manifests") {
            for case let rel as String in en {
                let path = root + "/manifests/" + rel
                guard path != manifest, let d = FileManager.default.contents(atPath: path),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                for layer in (o["layers"] as? [[String: Any]] ?? []) + [(o["config"] as? [String: Any]) ?? [:]] {
                    if let digest = layer["digest"] as? String { used.insert(digest.replacingOccurrences(of: ":", with: "-")) }
                }
            }
        }

        for blob in mine.subtracting(used) {
            let path = root + "/blobs/" + blob
            guard SafeDelete.canDelete(path) else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
        guard SafeDelete.canDelete(manifest) else { throw DevError("путь защищён") }
        try FileManager.default.removeItem(atPath: manifest)
    }

    // MARK: - Утилиты

    private func entry(_ group: String, _ title: String, _ path: String, _ safety: JunkSafety, _ explanation: String, _ cleanup: DevEntry.Cleanup, minSize: Int64 = 1 << 20) -> [DevEntry] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let size = directorySize(path)
        guard size >= minSize else { return [] }
        return [DevEntry(id: path, group: group, title: title, path: path, size: size, safety: safety, explanation: explanation, cleanup: cleanup)]
    }

    private func flutterSDK() -> String? {
        for candidate in [home + "/FlutterDev", home + "/flutter", home + "/development/flutter", "/opt/homebrew/share/flutter"] where FileManager.default.fileExists(atPath: candidate + "/bin/flutter") {
            return candidate
        }
        if let which = run(["sh", "-lc", "command -v flutter"])?.trimmingCharacters(in: .whitespacesAndNewlines), !which.isEmpty {
            let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: which)) ?? which
            return ((resolved as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        }
        return nil
    }

    private func projectName(_ path: String) -> String {
        var p = path
        for marker in ["/.build/", "/.fvm/", "/.fvmrc", "/.idea/"] {
            if let r = p.range(of: marker) { p = String(p[..<r.lowerBound]); break }
        }
        return (p as NSString).lastPathComponent
    }

    private func find(in roots: [String], names: Set<String>, depth: Int, minSize: Int64, files: Bool = false) -> [String] {
        var out: [String] = []
        let skip: Set<String> = ["node_modules", ".git", "Pods", "build", ".dart_tool", "DerivedData", "vendor"]
        func walk(_ dir: String, _ d: Int) {
            if cancelled || d > depth { return }
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for it in items {
                let p = dir + "/" + it
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { continue }
                if names.contains(it), isDir.boolValue != files {
                    if files || directorySize(p) >= minSize { out.append(p) }
                    if isDir.boolValue { continue }
                }
                if isDir.boolValue, !skip.contains(it), !(it.hasPrefix(".") && it != ".build" && it != ".fvm") { walk(p, d + 1) }
            }
        }
        for r in roots { walk(r, 0) }
        return out
    }

    func directorySize(_ path: String) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return Int64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0) }
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in en {
            if cancelled { break }
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// Есть ли инструмент в PATH пользователя. Интерактивный shell — потому что
    /// PATH часто дописывается в ~/.zshrc, который при `zsh -lc` не читается.
    private func toolExists(_ tool: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "command -v \(tool)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Запуск через login-shell: PATH пользователя (fvm, rustup, go, brew) в GUI-приложении не виден.
    @discardableResult
    private func run(_ argv: [String], throwing: Bool = false) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let cmd = argv.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        p.arguments = ["-ilc", argv.first == "sh" ? argv.dropFirst(2).joined(separator: " ") : cmd]
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            if throwing { lastCommandError = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "код \(p.terminationStatus)" }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
    var lastCommandError: String?
}

struct DevError: Error, LocalizedError { let m: String; init(_ m: String) { self.m = m }; var errorDescription: String? { m } }

extension SafeDelete {
    /// Разрешаем удалять только внутри домашней папки и не корни защищённого списка.
    static func canDelete(_ path: String) -> Bool {
        path.hasPrefix(NSHomeDirectory() + "/") && !isProtected(URL(fileURLWithPath: path))
    }
}
