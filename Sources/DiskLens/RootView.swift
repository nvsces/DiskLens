import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            Group {
                switch model.tab {
                case .overview: OverviewView()
                case .explorer: ExplorerView()
                case .junk: JunkView()
                case .simulators: SimulatorsView()
                case .docker: DockerView()
                case .android: AndroidView()
                case .devtools: DevToolsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $model.tab) {
                Section("Разделы") {
                    ForEach(Tab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.symbol)
                            .tag(tab)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            VolumeGauge(volume: model.volume)
                .padding(14)
        }
    }
}

/// Компактный индикатор заполненности диска внизу сайдбара.
struct VolumeGauge: View {
    let volume: VolumeInfo

    private var color: Color {
        switch volume.usedFraction {
        case ..<0.75: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(volume.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(3, geo.size.width * volume.usedFraction))
                }
            }
            .frame(height: 8)

            HStack(spacing: 4) {
                Text(formatBytes(volume.free)).fontWeight(.semibold)
                Text("свободно").foregroundStyle(.secondary)
            }
            .font(.caption)

            Text("из \(formatBytes(volume.total))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Цвет для строки/сегмента. Стабилен для одного имени, чтобы папка
/// не меняла цвет между запусками.
func paletteColor(for name: String) -> Color {
    let palette: [Color] = [
        .blue, .purple, .pink, .orange, .green,
        .teal, .indigo, .cyan, .mint, .yellow,
    ]
    var hash = 5381
    for byte in name.utf8 { hash = (hash &* 33) &+ Int(byte) }
    return palette[abs(hash) % palette.count]
}

extension JunkSafety {
    var color: Color {
        switch self {
        case .safe: return .green
        case .review: return .orange
        case .risky: return .red
        }
    }
}
