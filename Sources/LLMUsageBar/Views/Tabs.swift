import SwiftUI
import Charts

// MARK: - Overview

struct OverviewTab: View {
    @Environment(UsageStore.self) private var store
    @State private var period: Period = .week
    @State private var hovered: String?

    var body: some View {
        let series = store.series(for: period)
        let total = series.reduce(0) { $0 + $1.metrics.spend }
        let avg = series.isEmpty ? 0 : total / Double(series.count)
        let peak = series.max { $0.metrics.spend < $1.metrics.spend }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily spend").font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(Fmt.currency(total)).font(.system(size: 11)).monospacedDigit()
                        Text("·").foregroundStyle(.tertiary)
                        Text("avg \(Fmt.currency(avg))/day").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                PeriodPicker(period: $period)
            }

            if store.daily.isEmpty {
                EmptyState(systemImage: "chart.bar", title: "No daily data yet",
                           message: store.isRefreshing ? "Fetching your usage history…" : "Usage will appear here after the first successful refresh.")
            } else {
                Chart(series) { row in
                    BarMark(
                        x: .value("Date", Day.date(from: row.date) ?? Date(), unit: .day),
                        y: .value("Spend", row.metrics.spend)
                    )
                    .foregroundStyle(
                        row.date == Day.today
                            ? AnyShapeStyle(Color.orange.gradient)
                            : AnyShapeStyle(Color.accentColor.gradient)
                    )
                    .opacity(hovered == nil || hovered == row.date ? 1 : 0.45)
                    .cornerRadius(period == .week ? 4 : 2)

                    if avg > 0 {
                        RuleMark(y: .value("Average", avg))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.separator)
                        AxisValueLabel {
                            if let d = v.as(Double.self) { Text(Fmt.compactCurrency(d)).font(.system(size: 9)) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: period == .week ? 7 : 5)) { _ in
                        AxisValueLabel(format: period == .week ? .dateTime.weekday(.narrow) : .dateTime.month(.abbreviated).day(),
                                       centered: period == .week)
                            .font(.system(size: 9))
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let loc):
                                    guard let plot = proxy.plotFrame else { return }
                                    let x = loc.x - geo[plot].origin.x
                                    if let d: Date = proxy.value(atX: x) { hovered = Day.key(d) }
                                case .ended: hovered = nil
                                }
                            }
                    }
                }
                .frame(height: 150)
                .animation(.snappy, value: period)

                HStack {
                    if let h = hovered, let r = series.first(where: { $0.date == h }) {
                        Text(Fmt.dayLabel(h)).font(.system(size: 11, weight: .medium))
                        Text(Fmt.currency(r.metrics.spend)).font(.system(size: 11)).monospacedDigit()
                        if r.metrics.apiRequests > 0 {
                            Text("· \(Fmt.int(r.metrics.apiRequests)) req").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    } else if let peak, peak.metrics.spend > 0 {
                        Text("Peak").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("\(Fmt.dayLabel(peak.date)) · \(Fmt.currency(peak.metrics.spend))")
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    }
                    Spacer()
                    if let t = store.trend(for: period) {
                        Text("vs prev \(period.rawValue)").font(.system(size: 10)).foregroundStyle(.secondary)
                        TrendBadge(percent: t.percent)
                    }
                }
                .frame(height: 18)

                TokenSummary(series: series)
            }
        }
    }
}

struct TokenSummary: View {
    var series: [DailyRow]

    var body: some View {
        let m = series.reduce(Metrics.zero) { $0 + $1.metrics }
        if m.totalTokens > 0 || m.apiRequests > 0 {
            HStack(spacing: 0) {
                item("Requests", Fmt.abbreviate(Double(m.apiRequests)), "arrow.left.arrow.right")
                Divider().frame(height: 26)
                item("Input", Fmt.tokens(m.promptTokens), "arrow.down.doc")
                Divider().frame(height: 26)
                item("Output", Fmt.tokens(m.completionTokens), "arrow.up.doc")
                Divider().frame(height: 26)
                item("Cache read", Fmt.tokens(m.cacheReadTokens), "memorychip")
            }
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func item(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            Label(title, systemImage: icon).font(.system(size: 9)).foregroundStyle(.secondary).labelStyle(.titleOnly)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Models

struct ModelsTab: View {
    @Environment(UsageStore.self) private var store
    @State private var period: Period = .month

    var body: some View {
        let rows = store.modelUsage(for: period)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top models").font(.system(size: 12, weight: .semibold))
                Spacer()
                PeriodPicker(period: $period)
            }
            if rows.isEmpty {
                EmptyState(systemImage: "cpu", title: "No model usage",
                           message: store.usingSnapshotFallback
                           ? "Per-model breakdown needs the daily activity endpoint, which isn't available for this key."
                           : "No requests in this period.")
                if !store.models.isEmpty {
                    Text("\(store.models.count) models available on this gateway")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        ModelRow(rank: i + 1, usage: r)
                        if i < rows.count - 1 { Divider().padding(.leading, 26) }
                    }
                }
            }
        }
    }
}

struct ModelRow: View {
    var rank: Int
    var usage: ModelUsage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(usage.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Fmt.currency(usage.metrics.spend)).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                }
                ShareBar(fraction: usage.share, tint: Palette.color(for: usage.name))
                HStack(spacing: 8) {
                    if usage.metrics.apiRequests > 0 { Text("\(Fmt.int(usage.metrics.apiRequests)) req") }
                    if usage.metrics.totalTokens > 0 {
                        Text("\(Fmt.tokens(usage.metrics.promptTokens)) in · \(Fmt.tokens(usage.metrics.completionTokens)) out")
                    }
                    Spacer()
                    Text(Fmt.percent(usage.share * 100))
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Keys

struct KeysTab: View {
    @Environment(UsageStore.self) private var store
    @State private var period: Period = .month

    var body: some View {
        let rows = store.keyUsage(for: period)
        let currentToken = store.keyInfo?.token
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("API keys").font(.system(size: 12, weight: .semibold))
                Text("\(rows.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                Spacer()
                PeriodPicker(period: $period)
            }
            if rows.isEmpty {
                EmptyState(systemImage: "key", title: "No keys found", message: "Keys from /user/info will be listed here.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        KeyRow(usage: r, isCurrent: currentToken != nil && currentToken == r.hash, period: period)
                        if i < rows.count - 1 { Divider() }
                    }
                }
            }
        }
    }
}

struct KeyRow: View {
    var usage: KeyUsage
    var isCurrent: Bool
    var period: Period

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 11))
                .foregroundStyle(Palette.color(for: usage.hash))
                .frame(width: 24, height: 24)
                .background(Palette.color(for: usage.hash).opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(usage.alias ?? usage.key?.displayName ?? "Unnamed key")
                        .font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    if isCurrent {
                        Text("THIS KEY").font(.system(size: 8, weight: .bold)).foregroundStyle(.blue)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.blue.opacity(0.15), in: Capsule())
                    }
                }
                Text(usage.key?.masked ?? ("…" + usage.hash.suffix(6)))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                if let c = usage.key?.createdAt {
                    Text("Created \(Fmt.date(c))").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if usage.key != nil {
                    Text(Fmt.currency(usage.lifetimeSpend)).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                    Text("lifetime").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                if let p = usage.periodSpend {
                    Text("\(Fmt.currency(p)) · \(period.rawValue)")
                        .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(.vertical, 7)
    }
}

// MARK: - History

struct HistoryTab: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let rows = Array(store.daily.reversed())
        let totals = rows.reduce(Metrics.zero) { $0 + $1.metrics }
        VStack(spacing: 0) {
            if rows.isEmpty {
                EmptyState(systemImage: "tablecells", title: "No history yet",
                           message: "Daily rows are stored locally and accumulate over time.")
            } else {
                header
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(rows) { r in
                        HistoryRow(date: Fmt.dayLabel(r.date), m: r.metrics, derived: r.source == "snapshot")
                            .background(r.date == Day.today ? Color.accentColor.opacity(0.07) : .clear)
                    }
                }
                Divider()
                HistoryRow(date: "Total (\(rows.count)d)", m: totals, derived: false, bold: true)
                if rows.contains(where: { $0.source == "snapshot" }) {
                    Text("* derived from spend snapshots").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Date").frame(maxWidth: .infinity, alignment: .leading)
            Text("Req").frame(width: 46, alignment: .trailing)
            Text("In").frame(width: 50, alignment: .trailing)
            Text("Out").frame(width: 50, alignment: .trailing)
            Text("Spend").frame(width: 72, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
    }
}

struct HistoryRow: View {
    var date: String
    var m: Metrics
    var derived: Bool
    var bold = false

    var body: some View {
        HStack {
            Text(date + (derived ? " *" : "")).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text(derived ? "—" : Fmt.abbreviate(Double(m.apiRequests))).frame(width: 46, alignment: .trailing)
            Text(derived ? "—" : Fmt.tokens(m.promptTokens)).frame(width: 50, alignment: .trailing)
            Text(derived ? "—" : Fmt.tokens(m.completionTokens)).frame(width: 50, alignment: .trailing)
            Text(Fmt.currency(m.spend)).frame(width: 72, alignment: .trailing)
        }
        .font(.system(size: 11, weight: bold ? .semibold : .regular))
        .monospacedDigit()
        .foregroundStyle(m.spend == 0 && !bold ? .secondary : .primary)
        .padding(.vertical, 4)
    }
}
