import SwiftUI
import UpkeepCore

/// The rounded, bordered container used throughout the app.
struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            )
    }
}

/// The leaf-on-tile mark used in the header and About areas.
struct AppIconTile: View {
    var size: CGFloat = 56

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Color("TileBackground"))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "leaf")
                    .font(.system(size: size * 0.44, weight: .regular))
                    .foregroundStyle(Color.accentColor)
            )
            .accessibilityHidden(true)
    }
}

/// Small rounded pill, e.g. "Apple Silicon".
struct Pill: View {
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

struct RiskBadge: View {
    let risk: CleanupRisk
    var compact = false

    var body: some View {
        Label(compact ? risk.shortTitle : risk.title, systemImage: risk.symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(risk.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(risk.tint.opacity(0.14)))
            .accessibilityLabel(risk.title)
    }
}

extension CleanupRisk {
    var tint: Color {
        switch self {
        case .safe: return .green
        case .review: return .orange
        case .protected: return .secondary
        }
    }
}

/// A three-state checkbox (SwiftUI's Toggle has no mixed state).
struct TriStateCheckbox: View {
    let state: CategorySelectionState
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(state == .all ? "Selected" : state == .some ? "Partially selected" : "Not selected")
        .accessibilityAddTraits(.isButton)
    }

    private var symbol: String {
        switch state {
        case .all: return "checkmark.square.fill"
        case .some: return "minus.square.fill"
        case .none: return "square"
        }
    }
}

struct StatView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct StorageBar: View {
    let usedFraction: Double
    var reclaimableFraction: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: max(0, width * min(1, usedFraction)))
                if reclaimableFraction > 0 {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(4, width * min(usedFraction, reclaimableFraction)))
                        .offset(x: max(0, width * (min(1, usedFraction) - min(usedFraction, reclaimableFraction))))
                }
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Disk usage")
        .accessibilityValue("\(Int((usedFraction * 100).rounded())) percent used")
    }
}

/// A path shortened with ~ and truncated in the middle, with copy/reveal on right-click.
struct PathLabel: View {
    let url: URL

    var body: some View {
        Text(DisplayPath.string(for: url))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(url.path)
            .contextMenu {
                Button("Reveal in Finder") { FinderService.reveal(url) }
                Button("Copy Path") { FinderService.copyPath(url) }
            }
    }
}

enum DisplayPath {
    static func string(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

enum DateText {
    /// "Today, 8:42 PM", "Yesterday, 9:10 AM" or "12 Mar 2025, 9:10 AM".
    static func scanTime(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func modified(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
