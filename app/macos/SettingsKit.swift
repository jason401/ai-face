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
