import SwiftUI

/// One compact control in the row above the message field: an icon, what is chosen,
/// and a menu to change it.
struct OptionMenu<Items: View>: View {
    let symbol: String
    let title: String
    let help: String
    @ViewBuilder var items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .medium)).opacity(0.75)
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).opacity(0.55)
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(.white.opacity(0.1), in: squircle(Radius.control))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel("\(help): \(title)")
    }
}

/// The model and effort menus, shared by the new-thread form and an open Codex thread.
/// An empty choice means "whatever my settings say" and is shown as "Default".
struct ModelEffortMenus: View {
    let models: [ModelChoice]
    let model: String
    let effort: String
    /// What an empty choice is called: "Default" before a thread exists.
    var unset = "Default"
    let chooseModel: (String) -> Void
    let chooseEffort: (String) -> Void

    private var chosen: ModelChoice? { models.first { $0.id == model } }

    /// The chosen model's effort levels, or every model's when none is chosen.
    private var efforts: [String] {
        if let chosen { return chosen.efforts }
        var seen = Set<String>()
        return models.flatMap(\.efforts).filter { seen.insert($0).inserted }
    }

    var body: some View {
        OptionMenu(symbol: "cpu", title: chosen?.name ?? (model.isEmpty ? unset : model), help: "Model") {
            Button(unset) { pick(model: "") }
            Divider()
            ForEach(models) { option in
                Button(option.name) { pick(model: option.id) }
            }
        }
        OptionMenu(symbol: "gauge.with.dots.needle.50percent", title: effort.isEmpty ? unset : effort.capitalized, help: "Effort") {
            Button(unset) { chooseEffort("") }
            Divider()
            ForEach(efforts, id: \.self) { level in
                Button(level.capitalized) { chooseEffort(level) }
            }
        }
    }

    private func pick(model new: String) {
        chooseModel(new)
        // An effort the new model does not take falls back to the default.
        let allowed = models.first { $0.id == new }?.efforts
        if !effort.isEmpty, let allowed, !allowed.contains(effort) { chooseEffort("") }
    }
}

/// The switch between a background session and the desktop app, for a new Claude session.
struct TargetSwitch: View {
    @Binding var target: ClaudeTarget

    var body: some View {
        HStack(spacing: 2) {
            segment("CLI", .cli, help: "In the background, with the claude command. Keeps running when TopLayer is closed.")
            segment("Desktop", .desktop, help: "In the Claude desktop app. Switches to it; you confirm the session there.")
        }
        .padding(2)
        .background(.white.opacity(0.1), in: squircle(Radius.control))
    }

    private func segment(_ title: String, _ value: ClaudeTarget, help: String) -> some View {
        Button { target = value } label: {
            Text(title)
                .font(.system(size: 11, weight: target == value ? .semibold : .regular))
                .padding(.horizontal, 8).frame(height: 20)
                .background(target == value ? Brand.color(.claude).opacity(0.8) : .clear, in: squircle(Radius.control - 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(target == value ? .isSelected : [])
    }
}
