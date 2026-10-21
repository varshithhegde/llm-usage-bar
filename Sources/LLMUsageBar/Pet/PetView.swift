import SwiftUI

extension UsageStore {
    /// Average daily spend over the 7 days before today (the mood baseline).
    var previous7DayAverage: Double {
        let days = (1...7).map { Day.offset(Day.today, by: -$0) }
        return days.reduce(0) { $0 + (row(for: $1)?.metrics.spend ?? 0) } / 7
    }

    var topModelToday: (name: String, spend: Double)? {
        guard let m = row(for: Day.today)?.breakdown.models.max(by: { $0.value.spend < $1.value.spend }),
              m.value.spend > 0 || m.value.apiRequests > 0 else { return nil }
        return (m.key, m.value.spend)
    }

    var petMood: PetMood {
        let d = UserDefaults.standard
        let budget = d.bool(forKey: SettingsKeys.alertEnabled) ? d.double(forKey: SettingsKeys.alertThreshold) : 0
        return PetMood.compute(todaySpend: todaySpend, budget: budget > 0 ? budget : nil, baseline: previous7DayAverage)
    }

    func petBubbleText(_ mode: PetBubbleMode) -> String {
        switch mode {
        case .today: return "\(Fmt.currency(todaySpend)) today"
        case .week: return "\(Fmt.compactCurrency(last7Spend)) · 7d"
        case .lifetime: return "\(Fmt.compactCurrency(lifetimeSpend)) lifetime"
        case .todayRequests: return "\(Fmt.currency(todaySpend)) · \(Fmt.abbreviate(Double(todayMetrics.apiRequests))) req"
        }
    }
}

struct PetView: View {
    @Environment(UsageStore.self) private var store
    @Environment(PetModel.self) private var pet

    var body: some View {
        let mood = store.petMood
        VStack(spacing: PetLayout.spacing) {
            Spacer(minLength: 0)
            // No transitions: the panel resizes in the same pass, and a fading-out card would linger as a ghost.
            if pet.expanded {
                PetCard(mood: mood)
            } else {
                PetBubble(mood: mood)
            }
            ZStack {
                PetSpriteView(animation: pet.animation, mood: mood, spriteSize: pet.spriteSize)
                if pet.animation == nil {
                    Group {
                        if pet.spriteFailed {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 22)).foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
                }
            }
            .frame(width: PetLayout.spriteBox(sprite: pet.spriteSize).width,
                   height: PetLayout.spriteBox(sprite: pet.spriteSize).height)
        }
        .padding(.bottom, PetLayout.bottomPad)
        .padding(.top, PetLayout.topPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(pet.opacity)
    }
}

struct PetBubble: View {
    @Environment(UsageStore.self) private var store
    @Environment(PetModel.self) private var pet
    var mood: PetMood

    var body: some View {
        let hot = mood == .overheated
        HStack(spacing: 5) {
            if hot { Text("⚠️").font(.system(size: 10)) }
            if !store.hasKey {
                Text("Add API key in Settings")
            } else if store.isRefreshing && store.lastUpdated == nil {
                Text("Loading…")
            } else {
                Text(store.petBubbleText(pet.bubbleMode)).monospacedDigit()
            }
            if store.isRefreshing {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
            } else if store.lastError != nil {
                Text("❗").font(.system(size: 9)).grayscale(1).opacity(0.75)
                    .help(store.lastError ?? "")
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(hot ? Color.white : Color.primary)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background {
            Capsule()
                .fill(hot ? AnyShapeStyle(Color.red.gradient) : AnyShapeStyle(.regularMaterial))
        }
        .overlay(Capsule().strokeBorder(hot ? Color.red.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .fixedSize()
    }
}

struct PetCard: View {
    @Environment(UsageStore.self) private var store
    @Environment(PetModel.self) private var pet
    var mood: PetMood

    var body: some View {
        let hot = mood == .overheated
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(pet.name).font(.system(size: 11.5, weight: .bold, design: .rounded))
                if pet.shiny { Text("✨").font(.system(size: 9)) }
                Spacer()
                Text("\(mood.emoji) \(mood.label)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(hot ? Color.red : .secondary)
            }
            Divider()
            row("Today", Fmt.currency(store.todaySpend), bold: true, tint: hot ? .red : nil)
            row("Yesterday", Fmt.currency(store.yesterdaySpend))
            row("Last 7 days", Fmt.compactCurrency(store.last7Spend))
            row("Lifetime", Fmt.compactCurrency(store.lifetimeSpend))
            row("Requests today", Fmt.int(store.todayMetrics.apiRequests))
            HStack(alignment: .firstTextBaseline) {
                Text("Top model").foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(store.topModelToday?.name ?? "—").lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 4) {
                if store.isRefreshing {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                    Text("Refreshing…")
                } else if store.lastError != nil {
                    Text("❗").grayscale(1)
                    Text("Last refresh failed · cached")
                } else {
                    Text(Fmt.relative(store.lastUpdated))
                }
                Spacer()
                Text("right-click for menu")
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
        .padding(10)
        .frame(width: PetLayout.cardSize.width, height: PetLayout.cardSize.height, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(hot ? Color.red.opacity(0.7) : Color.primary.opacity(0.12), lineWidth: hot ? 1 : 0.5))
        .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
    }

    private func row(_ title: String, _ value: String, bold: Bool = false, tint: Color? = nil) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(bold ? .semibold : .regular)
                .foregroundStyle(tint ?? .primary)
        }
    }
}
