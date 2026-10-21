import SwiftUI
import AppKit
import Observation

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Container that owns all mouse handling (drag, click, right-click, hover) for the pet.
final class PetContainerView: NSView {
    weak var controller: PetController?
    private var tracking: NSTrackingArea?
    private var downScreenPoint: NSPoint?
    private var downWindowOrigin: NSPoint?
    private var dragged = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        guard downScreenPoint == nil else { return }
        controller?.setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard downScreenPoint == nil else { return }
        controller?.setHovered(false)
    }

    override func mouseDown(with event: NSEvent) {
        downScreenPoint = NSEvent.mouseLocation
        downWindowOrigin = window?.frame.origin
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downScreenPoint, let origin = downWindowOrigin, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if !dragged, hypot(dx, dy) < 3 { return }
        if !dragged {
            dragged = true
            controller?.setHovered(false, animated: false)
        }
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { downScreenPoint = nil; downWindowOrigin = nil }
        if dragged {
            controller?.didFinishDrag()
        } else {
            controller?.handleClick()
        }
        dragged = false
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showMenu(event: event, in: self)
    }
}

@MainActor
final class PetController: NSObject {
    static let shared = PetController()

    private var panel: PetPanel?
    private var container: PetContainerView?
    private weak var store: UsageStore?
    private let pet = PetModel.shared
    var openSettings: (() -> Void)?
    private var installed = false
    private var hoverWork: DispatchWorkItem?

    private enum K {
        static let legacyX = "pet.anchorX", legacyY = "pet.anchorY"
        static let placement = "pet.placement.v2"
    }

    private var placement = PlacementState()
    /// Current bottom-center anchor in global screen coordinates (not persisted directly).
    private var anchor: NSPoint = .zero
    private(set) var currentDisplayID: String?
    private(set) var isFallback = false
    private var debouncer = ChangeDebouncer()

    /// Footprint used for clamping: the sprite box plus the compact bubble, so the pet is fully on-screen.
    private var clampSize: CGSize {
        PetLayout.windowSize(sprite: pet.spriteSize, expanded: false)
    }

    func install(store: UsageStore) {
        guard !installed else { return }
        installed = true
        self.store = store
        loadPlacement()
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReplacement(after: 0.8) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReplacement(after: 2.0) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReplacement(after: 1.5) }
        }
        pet.reloadSprite()
        replace()
        observe()
        apply()
        // Frames can still be settling at launch; check again shortly after.
        scheduleReplacement(after: 1.0)
        if let path = ProcessInfo.processInfo.environment["LLMUSAGEBAR_PET_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.writeSnapshot(to: path) }
        }
    }

    // MARK: - Placement persistence

    private func loadPlacement() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: K.placement), let s = try? JSONDecoder().decode(PlacementState.self, from: data) {
            placement = s
        } else if d.object(forKey: K.legacyX) != nil {
            let legacy = CGPoint(x: d.double(forKey: K.legacyX), y: d.double(forKey: K.legacyY))
            placement = PetPlacement.migrate(legacyAnchor: legacy, displays: DisplayIdentity.connected, size: clampSize)
            savePlacement()
            d.removeObject(forKey: K.legacyX)
            d.removeObject(forKey: K.legacyY)
        }
    }

    private func savePlacement() {
        if let data = try? JSONEncoder().encode(placement) {
            UserDefaults.standard.set(data, forKey: K.placement)
        }
        publishDisplayStatus()
    }

    private func publishDisplayStatus() {
        let connected = DisplayIdentity.connected
        pet.displays = connected.map { PetDisplayOption(id: $0.id, name: $0.name) }
        pet.preferredDisplayName = placement.preferredDisplay.flatMap { id in
            connected.first { $0.id == id }?.name ?? placement.names[id]
        }
        pet.preferredDisplayConnected = placement.preferredDisplay.map { id in connected.contains { $0.id == id } } ?? false
        pet.currentDisplayID = currentDisplayID
    }

    // MARK: - Screen changes

    func scheduleReplacement(after delay: TimeInterval) {
        let token = debouncer.schedule()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.debouncer.isCurrent(token) else { return }
            self.replace()
            self.apply()
        }
    }

    /// Works out where the pet belongs now (preferred display if connected, otherwise a fallback).
    /// This never changes the preferred display.
    private func replace() {
        let displays = DisplayIdentity.connected
        placement = PetPlacement.refreshNames(placement, displays: displays)
        if let dec = PetPlacement.resolve(state: placement, displays: displays, size: clampSize) {
            anchor = dec.anchor
            currentDisplayID = dec.displayID
            isFallback = dec.isFallback
        }
        savePlacement()
    }

    private func commitUserPlacement(_ result: (state: PlacementState, decision: PlacementDecision)?) {
        guard let result else { return }
        placement = result.state
        anchor = result.decision.anchor
        currentDisplayID = result.decision.displayID
        isFallback = false
        savePlacement()
        apply()
    }

    func moveToDisplay(_ id: String) {
        commitUserPlacement(PetPlacement.moveToDisplay(placement, displayID: id, displays: DisplayIdentity.connected,
                                                       size: clampSize))
    }

    func resetPosition() {
        let displays = DisplayIdentity.connected
        let target = currentDisplayID.flatMap { id in displays.first { $0.id == id } }
            ?? displays.first(where: \.isMain) ?? displays.first
        guard let target else { return }
        placement.positions[target.id] = nil
        commitUserPlacement(PetPlacement.moveToDisplay(placement, displayID: target.id, displays: displays, size: clampSize))
    }

    func applySpacesBehavior() {
        guard let p = panel else { return }
        p.collectionBehavior = Self.collectionBehavior(allSpaces: pet.showOnAllSpaces)
        // Re-order so the window server picks up the new Spaces membership.
        if p.isVisible { p.orderOut(nil); p.orderFrontRegardless() }
    }

    static func collectionBehavior(allSpaces: Bool) -> NSWindow.CollectionBehavior {
        allSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            : [.managed, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// Debug aid: renders the pet panel's layer tree to a PNG (works without Screen Recording permission).
    private func writeSnapshot(to path: String) {
        guard let view = panel?.contentView, let layer = view.layer else { return }
        let scale = panel?.backingScaleFactor ?? 2
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func observe() {
        withObservationTracking {
            _ = pet.enabled
            _ = pet.clickThrough
            _ = pet.spriteSize
            _ = pet.expanded
            _ = pet.showOnAllSpaces
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.panel.map({ $0.collectionBehavior != Self.collectionBehavior(allSpaces: self.pet.showOnAllSpaces) }) == true {
                    self.applySpacesBehavior()
                }
                self.apply()
                self.observe()
            }
        }
    }

    private func makePanel() -> PetPanel {
        let p = PetPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 200),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = Self.collectionBehavior(allSpaces: pet.showOnAllSpaces)
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.isExcludedFromWindowsMenu = true
        p.title = "LLM Usage Pet"

        let c = PetContainerView(frame: p.contentLayoutRect)
        c.controller = self
        c.autoresizingMask = [.width, .height]
        if let store {
            let host = NSHostingView(rootView: PetView().environment(store).environment(pet))
            host.frame = c.bounds
            host.autoresizingMask = [.width, .height]
            host.sizingOptions = []
            c.addSubview(host)
        }
        p.contentView = c
        container = c
        return p
    }

    func apply() {
        guard pet.enabled else {
            panel?.orderOut(nil)
            return
        }
        let p = panel ?? makePanel()
        panel = p
        p.ignoresMouseEvents = pet.clickThrough
        let f = frame(for: anchor)
        if p.frame != f { p.setFrame(f, display: true) }
        if !p.isVisible { p.orderFrontRegardless() }
    }

    private func frame(for anchor: NSPoint) -> NSRect {
        let size = PetLayout.windowSize(sprite: pet.spriteSize, expanded: pet.expanded)
        var r = NSRect(x: (anchor.x - size.width / 2).rounded(), y: anchor.y.rounded(), width: size.width, height: size.height)
        // Keep an expanded card from sliding off the top/sides of its screen (sprite stays anchored otherwise).
        let vf = currentDisplayID.flatMap { id in DisplayIdentity.connected.first { $0.id == id }?.visibleFrame }
            ?? PetPlacement.display(containing: anchor, in: DisplayIdentity.connected)?.visibleFrame
        if let vf {
            if r.maxY > vf.maxY { r.origin.y = vf.maxY - r.height }
            if r.minY < vf.minY { r.origin.y = vf.minY }
            if r.minX < vf.minX { r.origin.x = vf.minX }
            if r.maxX > vf.maxX { r.origin.x = vf.maxX - r.width }
        }
        return r
    }

    // MARK: - Interaction

    func setHovered(_ h: Bool, animated: Bool = true) {
        hoverWork?.cancel()
        if !h && !animated { pet.hovered = false; return }
        // Small delays avoid flicker as the window resizes under the cursor.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if h {
                guard let p = self.panel, p.frame.contains(NSEvent.mouseLocation) else { return }
            } else if let p = self.panel, p.frame.contains(NSEvent.mouseLocation) {
                return
            }
            self.pet.hovered = h
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (h ? 0.25 : 0.12), execute: work)
    }

    func didFinishDrag() {
        guard let p = panel else { return }
        let dropped = NSPoint(x: p.frame.midX, y: p.frame.minY)
        // The display under the cursor wins; it matches what the user meant when the pet straddles two screens.
        let displays = DisplayIdentity.connected
        let probe = displays.contains { $0.frame.contains(NSEvent.mouseLocation) } ? NSEvent.mouseLocation : dropped
        guard let target = PetPlacement.display(containing: probe, in: displays) else { return }
        var a = dropped
        if !target.frame.contains(a) { a = CGPoint(x: min(max(a.x, target.frame.minX), target.frame.maxX), y: min(max(a.y, target.frame.minY), target.frame.maxY)) }
        commitUserPlacement(PetPlacement.recordUserPlacement(placement, anchor: a, displays: [target], size: clampSize))
    }

    func handleClick() {
        if !Self.openMenuBarPopover() {
            pet.pinnedCard.toggle()
        }
    }

    /// Clicks the MenuBarExtra's status item button. Returns false if it can't be found.
    @discardableResult
    static func openMenuBarPopover() -> Bool {
        for w in NSApp.windows where String(describing: type(of: w)).contains("NSStatusBarWindow") {
            if let button = findStatusButton(in: w.contentView) {
                button.performClick(nil)
                return true
            }
        }
        return false
    }

    private static func findStatusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let b = view as? NSStatusBarButton { return b }
        for s in view.subviews { if let b = findStatusButton(in: s) { return b } }
        return nil
    }

    func showMenu(event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, state: Bool? = nil, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.isEnabled = enabled
            if let state { i.state = state ? .on : .off }
            menu.addItem(i)
        }
        let header = NSMenuItem(title: "\(pet.name) · \(store?.petMood.label ?? "")", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        add(store?.isRefreshing == true ? "Refreshing…" : "Refresh Now", #selector(refreshNow), enabled: store?.isRefreshing != true)
        add("Open Usage Popover", #selector(openPopover))
        add("Change Pokémon…", #selector(changePokemon))
        add("Shiny", #selector(toggleShiny), state: pet.shiny)
        menu.addItem(.separator())
        add("Click-Through", #selector(toggleClickThrough), state: pet.clickThrough)
        add("Hide Pet", #selector(hidePet))
        menu.addItem(.separator())
        add("Quit LLM Usage", #selector(quit))
        pet.hovered = false
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func refreshNow() { Task { await store?.refresh() } }
    @objc private func openPopover() { Self.openMenuBarPopover() }
    @objc private func toggleShiny() { pet.shiny.toggle() }
    @objc private func hidePet() { pet.enabled = false }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleClickThrough() {
        pet.clickThrough.toggle()
        if pet.clickThrough {
            let a = NSAlert()
            a.messageText = "Click-through enabled"
            a.informativeText = "The pet now ignores the mouse. Turn this off in Settings → Pet, or from the menu bar popover."
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    @objc func changePokemon() {
        pet.settingsTab = .pet
        NSApp.activate(ignoringOtherApps: true)
        openSettings?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.title == "LLM Usage Settings" }?.makeKeyAndOrderFront(nil)
        }
    }
}
