import Cocoa
import SwiftUI

// Compact settings pages, the same look as AI Illuminati's Settings window: titled cards of
// one-line rows (label column + controls), small text, details in hover help instead of footers.

struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            VStack(spacing: 0) { content }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07)))
        }
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 96, alignment: .leading)
            HStack(spacing: 6) { content }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minHeight: 32)
    }
}

/// A short gray line under a row (status or a one-line hint); the long version goes in `help`.
struct SettingsNote: View {
    let text: String
    var lines = 2

    var body: some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
            .lineLimit(lines).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.bottom, 7)
    }
}

struct SettingsAction: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).lineLimit(1).frame(maxWidth: .infinity, minHeight: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
        }.buttonStyle(.plain)
    }
}

// A popup filling the control column. Explicit labels; SwiftUI's Picker would size itself to
// its widest item and leave the buttons at different positions from row to row.
struct SettingsMenu<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value

    var body: some View {
        SettingsPopup(titles: options.map { $0.0 }, selection: Binding(
            get: { options.firstIndex { $0.1 == selection } ?? 0 },
            set: { if options.indices.contains($0) { selection = options[$0].1 } }))
            .frame(maxWidth: .infinity).frame(height: 24)
    }
}

struct SettingsPopup: NSViewRepresentable {
    let titles: [String]
    @Binding var selection: Int

    final class Coordinator: NSObject {
        var parent: SettingsPopup
        init(_ parent: SettingsPopup) { self.parent = parent }
        @objc func select(_ sender: NSPopUpButton) { parent.selection = sender.indexOfSelectedItem }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        button.selectItem(at: selection)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 184, height: 24)
    }
}

/// A status word in the control column: green when things are fine, gray otherwise.
struct SettingsStatus: View {
    let text: String
    var ok = false

    var body: some View {
        Text(text).lineLimit(1).foregroundStyle(ok ? Color.green : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
