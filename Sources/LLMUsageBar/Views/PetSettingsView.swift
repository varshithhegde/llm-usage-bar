import SwiftUI
import AppKit

struct PetSettingsView: View {
    @Environment(PetModel.self) private var pet
    @State private var customID = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        @Bindable var pet = pet
        Form {
            Section {
                Toggle("Show desktop pet", isOn: $pet.enabled)
                HStack(spacing: 10) {
                    PokemonThumb(id: pet.pokemonID, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pet.name).font(.headline)
                        Text("#\(pet.pokemonID)" + (pet.shiny ? " · Shiny ✨" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if pet.loadingSprite {
                        ProgressView().controlSize(.small)
                    } else if pet.spriteFailed {
                        Label("Sprite unavailable offline", systemImage: "wifi.exclamationmark")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            Section("Choose Pokémon") {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(PetCatalog.curated) { e in
                        Button {
                            pet.pokemonID = e.id
                        } label: {
                            VStack(spacing: 1) {
                                PokemonThumb(id: e.id, size: 48)
                                Text(e.name).font(.system(size: 9.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(pet.pokemonID == e.id ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(pet.pokemonID == e.id ? Color.accentColor : .clear, lineWidth: 1.5)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(e.name) #\(e.id)")
                    }
                }
                .padding(.vertical, 2)
                HStack {
                    TextField("Custom Pokédex #", text: $customID, prompt: Text("1–\(PetCatalog.maxID)"))
                        .frame(width: 200)
                        .onSubmit(applyCustom)
                    Button("Use", action: applyCustom).disabled(Int(customID).map { (1...PetCatalog.maxID).contains($0) } != true)
                    Spacer()
                }
                Toggle("Shiny", isOn: $pet.shiny)
            }

            Section("Appearance") {
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $pet.scale, in: 1...4, step: 0.5)
                        Text(String(format: "%.1f×", pet.scale)).monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
                LabeledContent("Opacity") {
                    HStack {
                        Slider(value: $pet.opacity, in: 0.2...1)
                        Text("\(Int((pet.opacity * 100).rounded()))%").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
                Picker("Speech bubble shows", selection: $pet.bubbleMode) {
                    ForEach(PetBubbleMode.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                LabeledContent("Pet display") {
                    if let name = pet.preferredDisplayName {
                        Text(pet.preferredDisplayConnected ? "\(name) (remembered)" : "\(name) (remembered, disconnected)")
                            .foregroundStyle(pet.preferredDisplayConnected ? Color.secondary : Color.orange)
                    } else {
                        Text("Main display").foregroundStyle(.secondary)
                    }
                }
                Picker("Move pet to screen", selection: Binding(
                    get: { pet.currentDisplayID ?? "" },
                    set: { if !$0.isEmpty { PetController.shared.moveToDisplay($0) } }
                )) {
                    if pet.currentDisplayID == nil { Text("—").tag("") }
                    ForEach(pet.displays) { Text($0.name).tag($0.id) }
                }
                HStack {
                    Spacer()
                    Button("Reset position") { PetController.shared.resetPosition() }
                }
                Toggle("Show on all Spaces", isOn: $pet.showOnAllSpaces)
            } header: {
                Text("Placement")
            } footer: {
                Text("The pet remembers its spot on each display. If you unplug its display, it moves to another screen for now and goes back when you plug the display in again. Only dragging the pet or choosing a screen here changes the remembered display. With \"Show on all Spaces\" off, the pet stays on the Space it was opened on.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Click-through", isOn: $pet.clickThrough)
            } footer: {
                Text("With click-through on, the pet ignores the mouse so you can click what's behind it. Turn it off here or from the paw button in the menu bar popover.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("Mood follows today's spend: compared to your daily alert threshold if one is set, otherwise to your average over the previous 7 days. 😌 calm · 🙂 normal · 🤩 excited (bounces) · 🥵 overheated (glows red and shakes).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Show sprite cache") {
                        try? FileManager.default.createDirectory(at: SpriteCache.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(SpriteCache.directory)
                    }
                    Spacer()
                    Text("Sprites are fetched from PokeAPI and cached locally.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 640)
    }

    private func applyCustom() {
        guard let n = Int(customID.trimmingCharacters(in: .whitespaces)), (1...PetCatalog.maxID).contains(n) else { return }
        pet.pokemonID = n
        customID = ""
    }
}

struct PokemonThumb: View {
    var id: Int
    var size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: size * 0.4, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .task(id: id) {
            image = nil
            image = await SpriteRepository.thumbnail(id: id)
        }
    }
}
