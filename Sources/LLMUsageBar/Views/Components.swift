import SwiftUI

struct StatCard: View {
    var title: String
    var value: String
    var subtitle: String? = nil
    var systemImage: String
    var tint: Color = .accentColor
    var placeholder: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .redacted(reason: placeholder ? .placeholder : [])
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
    }
}

struct TrendBadge: View {
    var percent: Double?

    var body: some View {
        if let p = percent {
            let up = p >= 0
            HStack(spacing: 2) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                Text(Fmt.percent(abs(p)))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(up ? Color.orange : Color.green)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((up ? Color.orange : Color.green).opacity(0.15), in: Capsule())
            .help(up ? "Spending more than the previous period" : "Spending less than the previous period")
        } else {
            Text("No prior data")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

struct ShareBar: View {
    var fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint.gradient)
                    .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

struct EmptyState: View {
    var systemImage: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }
}

struct PeriodPicker: View {
    @Binding var period: Period

    var body: some View {
        Picker("", selection: $period) {
            ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 140)
        .controlSize(.small)
    }
}

struct InfoBanner: View {
    var text: String
    var systemImage: String = "info.circle"
    var tint: Color = .blue

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Deterministic per-name color for model/key rows.
enum Palette {
    static let colors: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .mint, .cyan, .red]
    static func color(for name: String) -> Color {
        var h: UInt64 = 5381
        for b in name.utf8 { h = (h &* 33) &+ UInt64(b) }
        return colors[Int(h % UInt64(colors.count))]
    }
}
