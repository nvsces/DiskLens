import Foundation

/// Насколько безопасно удалять находку. Влияет на цвет бейджа и на то,
/// попадает ли категория в "выбрать безопасное" одним кликом.
enum JunkSafety: Int, Comparable, Sendable {
    case safe       // регенерируется само, потерять нечего
    case review     // обычно мусор, но стоит посмотреть глазами
    case risky      // можно потерять работу или настройки

    static func < (lhs: JunkSafety, rhs: JunkSafety) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .safe: return "Безопасно"
        case .review: return "Проверьте"
        case .risky: return "Осторожно"
        }
    }
}

/// Одна найденная папка/файл мусора.
struct JunkItem: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let size: Int64
    let modified: Date?
    let categoryID: String
    var isSelected: Bool = false

    var displayName: String { url.lastPathComponent }
    /// Менялся за последнюю неделю — проект, скорее всего, в работе.
    var isRecent: Bool { modified.map { $0 > Date().addingTimeInterval(-7 * 86400) } ?? false }
    /// Для папок сборки имя «build» ни о чём не говорит — показываем проект.
    var contextName: String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? displayName : "\(parent)/\(displayName)"
    }
    /// Путь с ~ вместо домашней папки — так короче и привычнее.
    var displayPath: String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// Категория мусора: где искать, что именно и насколько это безопасно.
struct JunkCategory: Identifiable, Sendable {
    let id: String
    let title: String
    let explanation: String
    let safety: JunkSafety
    let symbol: String

    /// Корни поиска. Отсутствующие пути просто пропускаются.
    let roots: [String]
    /// Если задано — ищем внутри корней папки с такими именами (на глубину `depth`).
    let matchDirectoryNames: Set<String>
    /// Если задано — ищем файлы с такими расширениями.
    let matchExtensions: Set<String>
    /// Глубина поиска от корня. 0 — берём сам корень целиком.
    let depth: Int
    /// Минимальный возраст в днях: свежие файлы часто ещё нужны.
    let minAgeDays: Int
    /// Не показывать находки мельче этого порога — иначе список тонет в мелочи.
    let minSize: Int64

    init(
        id: String,
        title: String,
        explanation: String,
        safety: JunkSafety,
        symbol: String,
        roots: [String],
        matchDirectoryNames: Set<String> = [],
        matchExtensions: Set<String> = [],
        depth: Int = 0,
        minAgeDays: Int = 0,
        minSize: Int64 = 1024 * 1024
    ) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.safety = safety
        self.symbol = symbol
        self.roots = roots
        self.matchDirectoryNames = matchDirectoryNames
        self.matchExtensions = matchExtensions
        self.depth = depth
        self.minAgeDays = minAgeDays
        self.minSize = minSize
    }
}

enum JunkRules {
    static let home = NSHomeDirectory()

    static let categories: [JunkCategory] = [
        JunkCategory(
            id: "user-caches",
            title: "Кэши приложений",
            explanation: "~/Library/Caches — приложения пересоздают это по мере надобности.",
            safety: .safe,
            symbol: "shippingbox",
            roots: ["\(home)/Library/Caches"],
            depth: 1,
            minSize: 20 * 1024 * 1024
        ),
        JunkCategory(
            id: "xcode-derived",
            title: "Xcode DerivedData",
            explanation: "Промежуточные продукты сборки. Пересобираются при следующем билде.",
            safety: .safe,
            symbol: "hammer",
            roots: ["\(home)/Library/Developer/Xcode/DerivedData"],
            depth: 1,
            minSize: 10 * 1024 * 1024
        ),
        JunkCategory(
            id: "xcode-archives",
            title: "Архивы Xcode",
            explanation: "Сборки .xcarchive для загрузки в App Store. Нужны только для повторной отправки символов.",
            safety: .review,
            symbol: "archivebox",
            roots: ["\(home)/Library/Developer/Xcode/Archives"],
            depth: 2,
            minAgeDays: 30,
            minSize: 50 * 1024 * 1024
        ),
        JunkCategory(
            id: "ios-device-support",
            title: "Support-файлы устройств iOS",
            explanation: "Символы для отладки на конкретных версиях iOS. Скачиваются заново при подключении устройства.",
            safety: .safe,
            symbol: "iphone",
            roots: [
                "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
                "\(home)/Library/Developer/Xcode/watchOS DeviceSupport",
            ],
            depth: 1,
            minSize: 100 * 1024 * 1024
        ),
        JunkCategory(
            id: "simulators",
            title: "Кэш симуляторов",
            explanation: "Кэши и логи CoreSimulator. Сами симуляторы удаляйте через Xcode.",
            safety: .safe,
            symbol: "square.stack.3d.up",
            roots: [
                "\(home)/Library/Developer/CoreSimulator/Caches",
                "\(home)/Library/Logs/CoreSimulator",
            ],
            depth: 1,
            minSize: 50 * 1024 * 1024
        ),
        JunkCategory(
            id: "node-modules",
            title: "node_modules",
            explanation: "Зависимости npm. Восстанавливаются командой install, но нужен интернет.",
            safety: .review,
            symbol: "shippingbox.fill",
            roots: ["\(home)/source", "\(home)/Documents", "\(home)/Projects", "\(home)/dev"],
            matchDirectoryNames: ["node_modules"],
            depth: 5,
            minSize: 50 * 1024 * 1024
        ),
        JunkCategory(
            id: "build-dirs",
            title: "Папки сборки",
            explanation: "build, .dart_tool, target, Pods внутри проектов. Пересоздаются при следующей сборке — теряется только её время.",
            safety: .review,
            symbol: "wrench.and.screwdriver",
            roots: ["\(home)/source", "\(home)/Documents", "\(home)/Projects", "\(home)/dev"],
            matchDirectoryNames: ["build", ".build", "target", ".gradle", ".dart_tool", "Pods", "DerivedData"],
            depth: 5,
            minSize: 50 * 1024 * 1024
        ),
        JunkCategory(
            id: "package-caches",
            title: "Кэши пакетных менеджеров",
            explanation: "npm, yarn, pip, Homebrew, CocoaPods, Go, Gradle. Скачиваются заново.",
            safety: .safe,
            symbol: "cube.box",
            roots: [
                "\(home)/.npm/_cacache",
                "\(home)/Library/Caches/Yarn",
                "\(home)/Library/Caches/pip",
                "\(home)/Library/Caches/Homebrew",
                "\(home)/Library/Caches/CocoaPods",
                "\(home)/Library/Caches/go-build",
                "\(home)/.gradle/caches",
                "\(home)/.cache",
            ],
            depth: 0,
            minSize: 20 * 1024 * 1024
        ),
        JunkCategory(
            id: "logs",
            title: "Логи",
            explanation: "~/Library/Logs — диагностические записи приложений.",
            safety: .safe,
            symbol: "doc.text",
            roots: ["\(home)/Library/Logs"],
            depth: 1,
            minSize: 5 * 1024 * 1024
        ),
        JunkCategory(
            id: "crash-reports",
            title: "Отчёты о сбоях",
            explanation: "Диагностика падений приложений. Нужны только при разборе конкретного бага.",
            safety: .safe,
            symbol: "exclamationmark.triangle",
            roots: ["\(home)/Library/Logs/DiagnosticReports"],
            depth: 1,
            minSize: 1024 * 1024
        ),
        JunkCategory(
            id: "old-downloads",
            title: "Старые загрузки",
            explanation: "Установщики и архивы в ~/Downloads старше 90 дней.",
            safety: .review,
            symbol: "arrow.down.circle",
            roots: ["\(home)/Downloads"],
            matchExtensions: ["dmg", "pkg", "zip", "iso", "tar", "gz", "xz", "bz2", "7z", "exe", "msi"],
            depth: 2,
            minAgeDays: 90,
            minSize: 20 * 1024 * 1024
        ),
        JunkCategory(
            id: "trash",
            title: "Корзина",
            explanation: "Файлы, уже помеченные вами к удалению.",
            safety: .review,
            symbol: "trash",
            roots: ["\(home)/.Trash"],
            depth: 1,
            minSize: 1024 * 1024
        ),
        JunkCategory(
            id: "ios-backups",
            title: "Резервные копии iPhone",
            explanation: "Локальные бэкапы устройств. Удаляйте, только если есть копия в iCloud или свежее.",
            safety: .risky,
            symbol: "externaldrive.badge.icloud",
            roots: ["\(home)/Library/Application Support/MobileSync/Backup"],
            depth: 1,
            minSize: 100 * 1024 * 1024
        ),
        JunkCategory(
            id: "docker",
            title: "Данные Docker",
            explanation: "Docker.raw — виртуальный диск со всеми образами, томами и кэшем. Чистить лучше изнутри: docker system prune.",
            safety: .risky,
            symbol: "shippingbox.circle",
            roots: [
                "\(home)/Library/Containers/com.docker.docker/Data/vms",
                "\(home)/.docker",
            ],
            depth: 1,
            minSize: 100 * 1024 * 1024
        ),
        JunkCategory(
            id: "mail-attachments",
            title: "Вложения Почты",
            explanation: "Скачанные вложения. Восстанавливаются с сервера, если письма там остались.",
            safety: .risky,
            symbol: "paperclip",
            roots: ["\(home)/Library/Mail"],
            matchDirectoryNames: ["Attachments"],
            depth: 5,
            minSize: 50 * 1024 * 1024
        ),
    ]
}
