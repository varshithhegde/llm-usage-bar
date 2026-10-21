import Foundation
import Observation
import CoreGraphics

enum PetBubbleMode: String, CaseIterable, Identifiable {
    case today, week, lifetime, todayRequests
    var id: String { rawValue }
    var label: String {
        switch self {
        case .today: return "Today's spend"
        case .week: return "Last 7 days"
        case .lifetime: return "Lifetime spend"
        case .todayRequests: return "Today + requests"
        }
    }
}

enum SettingsTab: String { case general, pet }

enum PetMood: String, Equatable {
    case calm, normal, excited, overheated

    var emoji: String {
        switch self {
        case .calm: return "😌"
        case .normal: return "🙂"
        case .excited: return "🤩"
        case .overheated: return "🥵"
        }
    }

    var label: String {
        switch self {
        case .calm: return "Calm"
        case .normal: return "Normal"
        case .excited: return "Excited"
        case .overheated: return "Overheated"
        }
    }

    /// With a daily budget: calm <50%, normal <80%, excited <100%, overheated ≥100% (over budget).
    /// Without one, compared to the previous 7 days' average: calm <50%, normal ≤100%, excited ≤150%, overheated >150%.
    static func compute(todaySpend: Double, budget: Double?, baseline: Double) -> PetMood {
        if let budget, budget > 0 {
            let r = todaySpend / budget
            if r >= 1.0 { return .overheated }
            if r >= 0.8 { return .excited }
            if r >= 0.5 { return .normal }
            return .calm
        }
        guard baseline > 0.0001 else { return todaySpend > 0 ? .normal : .calm }
        let r = todaySpend / baseline
        if r > 1.5 { return .overheated }
        if r > 1.0 { return .excited }
        if r >= 0.5 { return .normal }
        return .calm
    }
}

struct PetDisplayOption: Identifiable, Hashable {
    let id: String
    let name: String
}

struct PokemonEntry: Identifiable, Hashable {
    let id: Int
    let name: String
}

enum PetCatalog {
    static let defaultID = 150
    static let maxID = 1025

    static let curated: [PokemonEntry] = [
        .init(id: 150, name: "Mewtwo"), .init(id: 151, name: "Mew"),
        .init(id: 144, name: "Articuno"), .init(id: 145, name: "Zapdos"), .init(id: 146, name: "Moltres"),
        .init(id: 249, name: "Lugia"), .init(id: 250, name: "Ho-Oh"), .init(id: 251, name: "Celebi"),
        .init(id: 243, name: "Raikou"), .init(id: 244, name: "Entei"), .init(id: 245, name: "Suicune"),
        .init(id: 382, name: "Kyogre"), .init(id: 383, name: "Groudon"), .init(id: 384, name: "Rayquaza"),
        .init(id: 385, name: "Jirachi"), .init(id: 386, name: "Deoxys"), .init(id: 381, name: "Latios"),
        .init(id: 380, name: "Latias"), .init(id: 483, name: "Dialga"), .init(id: 484, name: "Palkia"),
        .init(id: 487, name: "Giratina"), .init(id: 493, name: "Arceus"), .init(id: 491, name: "Darkrai"),
        .init(id: 643, name: "Reshiram"), .init(id: 644, name: "Zekrom"), .init(id: 646, name: "Kyurem"),
        .init(id: 494, name: "Victini"),
        .init(id: 25, name: "Pikachu"), .init(id: 6, name: "Charizard"), .init(id: 94, name: "Gengar"),
        .init(id: 143, name: "Snorlax"), .init(id: 133, name: "Eevee"), .init(id: 448, name: "Lucario"),
        .init(id: 445, name: "Garchomp"),
    ]

    static func name(for id: Int) -> String {
        curated.first { $0.id == id }?.name ?? "Pokémon #\(id)"
    }

    static func clamp(_ id: Int) -> Int { min(max(id, 1), maxID) }
}

/// Layout metrics shared by the SwiftUI pet view and the panel's hit-testing.
enum PetLayout {
    static let bottomPad: CGFloat = 6
    static let spacing: CGFloat = 2
    static let bubbleSize = CGSize(width: 210, height: 26)
    static let cardSize = CGSize(width: 224, height: 158)
    static let topPad: CGFloat = 4
    /// Extra room around the sprite so bob/bounce/shake/glow aren't clipped.
    static let spriteMargin = CGSize(width: 14, height: 16)
    static let baseBox: CGFloat = 96

    static func spriteBox(sprite: CGSize) -> CGSize {
        CGSize(width: sprite.width + spriteMargin.width * 2, height: sprite.height + spriteMargin.height)
    }

    static func windowSize(sprite: CGSize, expanded: Bool) -> CGSize {
        let box = spriteBox(sprite: sprite)
        let top = expanded ? cardSize : bubbleSize
        return CGSize(width: ceil(max(box.width, top.width) + 8),
                      height: ceil(bottomPad + box.height + spacing + top.height + topPad))
    }

    /// Natural pixel size × scale, fitted inside a (96 × scale) box so large sprites don't explode.
    static func displaySize(natural: CGSize?, scale: Double) -> CGSize {
        let box = baseBox * CGFloat(scale)
        guard let n = natural, n.width > 0, n.height > 0 else { return CGSize(width: 64 * scale, height: 64 * scale) }
        var w = n.width * CGFloat(scale), h = n.height * CGFloat(scale)
        let f = min(1, box / max(w, h))
        w *= f; h *= f
        return CGSize(width: w.rounded(), height: h.rounded())
    }
}

@MainActor
@Observable
final class PetModel {
    static let shared = PetModel()

    private enum K {
        static let enabled = "pet.enabled", id = "pet.id", shiny = "pet.shiny", scale = "pet.scale"
        static let opacity = "pet.opacity", clickThrough = "pet.clickThrough", bubble = "pet.bubble"
        static let allSpaces = "pet.allSpaces"
    }

    var showOnAllSpaces: Bool { didSet { save(showOnAllSpaces, K.allSpaces) } }

    // Display status published by PetController for Settings.
    var displays: [PetDisplayOption] = []
    var preferredDisplayName: String?
    var preferredDisplayConnected = false
    var currentDisplayID: String?

    var enabled: Bool { didSet { save(enabled, K.enabled) } }
    var pokemonID: Int { didSet { save(pokemonID, K.id); if oldValue != pokemonID { reloadSprite() } } }
    var shiny: Bool { didSet { save(shiny, K.shiny); if oldValue != shiny { reloadSprite() } } }
    var scale: Double { didSet { save(scale, K.scale) } }
    var opacity: Double { didSet { save(opacity, K.opacity) } }
    var clickThrough: Bool { didSet { save(clickThrough, K.clickThrough) } }
    var bubbleMode: PetBubbleMode { didSet { save(bubbleMode.rawValue, K.bubble) } }

    // Transient state
    var hovered = false
    var pinnedCard = false
    var animation: SpriteAnimation?
    var loadingSprite = false
    var spriteFailed = false
    var settingsTab: SettingsTab = .general

    @ObservationIgnored var onChange: (() -> Void)?

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: K.enabled) as? Bool ?? true
        let id = d.integer(forKey: K.id)
        pokemonID = id > 0 ? PetCatalog.clamp(id) : PetCatalog.defaultID
        shiny = d.bool(forKey: K.shiny)
        let s = d.double(forKey: K.scale)
        scale = s > 0 ? min(max(s, 1), 4) : 2
        let o = d.double(forKey: K.opacity)
        opacity = o > 0 ? min(max(o, 0.2), 1) : 1
        clickThrough = d.bool(forKey: K.clickThrough)
        showOnAllSpaces = d.object(forKey: K.allSpaces) as? Bool ?? true
        bubbleMode = PetBubbleMode(rawValue: d.string(forKey: K.bubble) ?? "") ?? .today
    }

    private func save(_ v: Any, _ key: String) {
        UserDefaults.standard.set(v, forKey: key)
        onChange?()
    }

    var name: String { PetCatalog.name(for: pokemonID) }
    var spriteSize: CGSize { PetLayout.displaySize(natural: animation?.pixelSize, scale: scale) }
    var expanded: Bool { hovered || pinnedCard }

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    func reloadSprite() {
        loadTask?.cancel()
        let id = pokemonID, shiny = shiny
        loadingSprite = true
        spriteFailed = false
        loadTask = Task { [weak self] in
            let anim = await SpriteRepository.animation(id: id, shiny: shiny)
            guard let self, !Task.isCancelled, self.pokemonID == id, self.shiny == shiny else { return }
            self.loadingSprite = false
            if let anim {
                self.animation = anim
            } else {
                self.spriteFailed = self.animation == nil
            }
        }
    }
}
