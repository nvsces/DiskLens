import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                HStack(alignment: .top, spacing: 24) {
                    DiskRing(volume: model.volume)
                        .frame(width: 220, height: 220)

                    VStack(alignment: .leading, spacing: 14) {
                        StatTile(
                            title: "Занято",
                            value: formatBytes(model.volume.used),
                            caption: "\(Int(model.volume.usedFraction * 100))% диска",
                            symbol: "internaldrive",
                            tint: .blue
                        )
                        StatTile(
                            title: "Свободно",
                            value: formatBytes(model.volume.free),
                            caption: "доступно для записи",
                            symbol: "checkmark.circle",
                            tint: .green
                        )
                        StatTile(
                            title: "Можно освободить",
                            value: model.junkGroups.isEmpty ? "—" : formatBytes(model.totalJunkSize),
                            caption: model.junkGroups.isEmpty
                                ? "запустите поиск мусора"
                                : "найдено в \(model.junkGroups.count) категориях",
                            symbol: "sparkles",
                            tint: .orange
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                actions

                if !model.junkGroups.isEmpty {
                    junkSummary
                }
            }
            .padding(28)
        }
        .navigationTitle("Обзор")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Куда уходит место")
                .font(.largeTitle.bold())
            Text("Проанализируйте папки и уберите то, что система пересоздаст сама.")
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                model.tab = .explorer
                if model.root == nil { model.startScan() }
            } label: {
                Label("Анализировать папки", systemImage: "folder.badge.gearshape")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Button {
                model.tab = .junk
                if model.junkGroups.isEmpty { model.findJunk() }
            } label: {
                Label("Найти мусор", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    private var junkSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Найденный мусор")
                .font(.headline)

            ForEach(model.junkGroups.prefix(6)) { group in
                HStack(spacing: 10) {
                    Image(systemName: group.category.symbol)
                        .foregroundStyle(group.category.safety.color)
                        .frame(width: 20)
                    Text(group.category.title)
                    Spacer()
                    Text(formatBytes(group.totalSize))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// Кольцевая диаграмма заполненности тома.
struct DiskRing: View {
    let volume: VolumeInfo

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 26)

            Circle()
                .trim(from: 0, to: volume.usedFraction)
                .stroke(
                    AngularGradient(
                        colors: [.blue, .purple, .pink],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 26, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: volume.usedFraction)

            VStack(spacing: 2) {
                Text("\(Int(volume.usedFraction * 100))%")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("занято")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let caption: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}
