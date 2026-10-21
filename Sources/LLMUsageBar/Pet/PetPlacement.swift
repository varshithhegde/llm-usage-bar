import Foundation
import CoreGraphics

/// A connected display, identified by a stable id that survives reconnects.
struct DisplayInfo: Equatable, Identifiable {
    var id: String
    var name: String
    var frame: CGRect
    var visibleFrame: CGRect
    var isMain: Bool
}

/// Anchor (bottom-center of the pet) as a fraction of a display's visibleFrame.
struct RelativePoint: Codable, Equatable {
    var x: Double
    var y: Double
}

struct PlacementState: Codable, Equatable {
    var positions: [String: RelativePoint] = [:]
    var names: [String: String] = [:]
    /// The display the user last explicitly put the pet on. Only drags / "Move to screen" change it.
    var preferredDisplay: String?
}

struct PlacementDecision: Equatable {
    var displayID: String
    var anchor: CGPoint
    /// True when the preferred display is missing and the pet is temporarily elsewhere.
    var isFallback: Bool
}

/// Pure placement logic for the desktop pet. Has no AppKit dependencies, so the self-test can drive it.
enum PetPlacement {
    static let margin: CGFloat = 24

    static func toRelative(_ anchor: CGPoint, in vf: CGRect) -> RelativePoint {
        guard vf.width > 0, vf.height > 0 else { return RelativePoint(x: 1, y: 0) }
        let x = Double((anchor.x - vf.minX) / vf.width)
        let y = Double((anchor.y - vf.minY) / vf.height)
        return RelativePoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    static func toAbsolute(_ rel: RelativePoint, in vf: CGRect) -> CGPoint {
        CGPoint(x: vf.minX + CGFloat(rel.x) * vf.width, y: vf.minY + CGFloat(rel.y) * vf.height)
    }

    /// Clamps a bottom-center anchor so a pet of `size` sits fully inside `vf`.
    static func clamp(_ a: CGPoint, size: CGSize, in vf: CGRect) -> CGPoint {
        let halfW = size.width / 2
        let x = vf.width >= size.width ? min(max(a.x, vf.minX + halfW), vf.maxX - halfW) : vf.midX
        let y = vf.height >= size.height ? min(max(a.y, vf.minY), vf.maxY - size.height) : vf.minY
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// Bottom-right corner of the visible frame, inset by a margin.
    static func defaultAnchor(size: CGSize, in vf: CGRect) -> CGPoint {
        clamp(CGPoint(x: vf.maxX - margin - size.width / 2, y: vf.minY + margin), size: size, in: vf)
    }

    static func anchor(on d: DisplayInfo, state: PlacementState, size: CGSize) -> CGPoint {
        if let rel = state.positions[d.id] {
            return clamp(toAbsolute(rel, in: d.visibleFrame), size: size, in: d.visibleFrame)
        }
        return defaultAnchor(size: size, in: d.visibleFrame)
    }

    /// The preferred display if it's connected; otherwise the main display, or the first one.
    static func resolve(state: PlacementState, displays: [DisplayInfo], size: CGSize) -> PlacementDecision? {
        if let pid = state.preferredDisplay, let d = displays.first(where: { $0.id == pid }) {
            return PlacementDecision(displayID: d.id, anchor: anchor(on: d, state: state, size: size), isFallback: false)
        }
        guard let d = displays.first(where: \.isMain) ?? displays.first else { return nil }
        return PlacementDecision(displayID: d.id, anchor: anchor(on: d, state: state, size: size),
                                 isFallback: state.preferredDisplay != nil)
    }

    /// The display containing `p`, or the nearest one.
    static func display(containing p: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first { $0.frame.contains(p) }
            ?? displays.min { distance(p, $0.frame) < distance(p, $1.frame) }
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// Records an explicit user placement (drag or "Move to screen"). This is the only thing that changes the preferred display.
    static func recordUserPlacement(_ state: PlacementState, anchor: CGPoint, displays: [DisplayInfo],
                                    size: CGSize) -> (state: PlacementState, decision: PlacementDecision)? {
        guard let d = display(containing: anchor, in: displays) else { return nil }
        let clamped = clamp(anchor, size: size, in: d.visibleFrame)
        var s = state
        s.positions[d.id] = toRelative(clamped, in: d.visibleFrame)
        s.names[d.id] = d.name
        s.preferredDisplay = d.id
        return (s, PlacementDecision(displayID: d.id, anchor: clamped, isFallback: false))
    }

    /// Moves the pet to `displayID`, keeping its saved spot there or using the default corner.
    static func moveToDisplay(_ state: PlacementState, displayID: String, displays: [DisplayInfo],
                              size: CGSize) -> (state: PlacementState, decision: PlacementDecision)? {
        guard let d = displays.first(where: { $0.id == displayID }) else { return nil }
        return recordUserPlacement(state, anchor: anchor(on: d, state: state, size: size), displays: displays, size: size)
    }

    /// Converts the old single absolute anchor into per-display state.
    static func migrate(legacyAnchor: CGPoint, displays: [DisplayInfo], size: CGSize) -> PlacementState {
        recordUserPlacement(PlacementState(), anchor: legacyAnchor, displays: displays, size: size)?.state ?? PlacementState()
    }

    /// Updates remembered display names without touching positions or the preferred display.
    static func refreshNames(_ state: PlacementState, displays: [DisplayInfo]) -> PlacementState {
        var s = state
        for d in displays where s.positions[d.id] != nil || s.preferredDisplay == d.id { s.names[d.id] = d.name }
        return s
    }
}

/// Coalesces bursts of screen-change notifications: only the most recently scheduled run is acted on.
struct ChangeDebouncer {
    private(set) var generation = 0
    mutating func schedule() -> Int { generation += 1; return generation }
    func isCurrent(_ token: Int) -> Bool { token == generation }
}
