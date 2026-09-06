import SwiftUI
import AppKit

@main
struct DiskLensApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("DiskLens") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 960, idealWidth: 1120, minHeight: 640, idealHeight: 760)
                .onAppear { model.refreshVolume() }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

/// Запуск как обычного оконного приложения даже при старте из терминала,
/// иначе SPM-бинарник не получает фокус и меню.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Удалять безвозвратно, минуя Корзину", isOn: $model.permanentDelete)
                Text(model.permanentDelete
                     ? "Файлы будут стёрты сразу. Восстановить их будет нельзя."
                     : "Файлы попадают в Корзину — их можно вернуть.")
                    .font(.caption)
                    .foregroundStyle(model.permanentDelete ? .red : .secondary)
            } header: {
                Text("Удаление")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 160)
    }
}
