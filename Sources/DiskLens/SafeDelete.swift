import Foundation

/// Удаление с двумя страховками: список защищённых путей и перенос
/// в Корзину вместо безвозвратного стирания.
enum SafeDelete {
    /// Пути, которые нельзя трогать ни при каких настройках правил.
    /// Ошибка в правиле не должна стоить пользователю системы или документов.
    private static let protectedPrefixes: [String] = [
        "/System",
        "/Library/Apple",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/var/db",
        "/Applications",
        "/Volumes",
        "/private/var/db",
    ]

    private static let protectedExact: Set<String> = {
        let home = NSHomeDirectory()
        return [
            "/",
            home,
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Downloads",
            "\(home)/Pictures",
            "\(home)/Music",
            "\(home)/Movies",
            "\(home)/Library",
            "\(home)/Library/Caches",
            "\(home)/Library/Logs",
            "\(home)/Library/Application Support",
            "\(home)/Library/Preferences",
            "\(home)/Library/Containers",
            "\(home)/Library/Mail",
            "\(home)/.Trash",
            "\(home)/.ssh",
            "\(home)/.gnupg",
        ]
    }()

    /// true — путь удалять запрещено.
    static func isProtected(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if protectedExact.contains(path) { return true }
        for prefix in protectedPrefixes where path == prefix || path.hasPrefix(prefix + "/") {
            return true
        }
        // Ключи, токены и конфиги в корне домашней папки — не наш профиль риска.
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/.ssh") || path.hasPrefix(home + "/.gnupg") { return true }
        return false
    }

    struct Outcome: Sendable {
        var freedBytes: Int64 = 0
        var deletedCount: Int = 0
        var failures: [(path: String, reason: String)] = []
    }

    /// Переносит в Корзину. `permanently` оставлен для явного выбора
    /// пользователя в настройках — по умолчанию всегда Корзина.
    static func delete(items: [JunkItem], permanently: Bool) -> Outcome {
        var outcome = Outcome()
        for item in items {
            guard !isProtected(item.url) else {
                outcome.failures.append((item.displayPath, "путь защищён от удаления"))
                continue
            }
            do {
                if permanently {
                    try FileManager.default.removeItem(at: item.url)
                } else {
                    var resulting: NSURL?
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: &resulting)
                }
                outcome.freedBytes += item.size
                outcome.deletedCount += 1
            } catch {
                outcome.failures.append((item.displayPath, error.localizedDescription))
            }
        }
        return outcome
    }
}
