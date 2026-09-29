import AppKit
import SwiftUI

/// Upkeep's visual language: near-black surfaces, a bright blue accent taken from
/// the app icon, translucent (vibrancy) backgrounds and rounded type.
enum Theme {
    /// Main accent (the `AccentColor` asset: deep blue in light mode, bright blue in dark).
    static let accent = Color.accentColor
    /// Lighter end of the accent gradient.
    static let accentHighlight = Color(red: 0.43, green: 0.68, blue: 1.0)
    /// Darker end of the accent gradient.
    static let accentDeep = Color(red: 0.16, green: 0.40, blue: 0.96)

    static let accentGradient = LinearGradient(
        colors: [accentHighlight, accentDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cornerRadius: CGFloat = 16
    static let hairline = Color.primary.opacity(0.08)
}

// MARK: - Pointing-hand cursor

/// Shows the pointing-hand cursor while the pointer is over the view.
/// Balanced push/pop, and restored if the view disappears while hovered.
private struct PointingHandCursor: ViewModifier {
    let enabled: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside && enabled && !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                } else if (!inside || !enabled) && pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onChange(of: enabled) { _, isEnabled in
                if !isEnabled && pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}

extension View {
    /// Use the pointing-hand cursor when hovering this (clickable) view.
    func pointingHandCursor(_ enabled: Bool = true) -> some View {
        modifier(PointingHandCursor(enabled: enabled))
    }
}

// MARK: - Button styles

/// Filled blue gradient capsule for primary actions ("Scan Mac", "Clean Selected").
struct ProminentButtonStyle: ButtonStyle {
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration) { hovering, enabled in
            configuration.label
                .font(.system(large ? .headline : .callout, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, large ? 22 : 16)
                .padding(.vertical, large ? 11 : 7)
                .background(Capsule().fill(Theme.accentGradient))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                .shadow(color: Theme.accentDeep.opacity(enabled ? (hovering ? 0.5 : 0.3) : 0), radius: hovering ? 14 : 8, y: 4)
                .brightness(hovering && enabled ? 0.05 : 0)
        }
    }
}

/// Translucent capsule for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration) { hovering, enabled in
            configuration.label
                .font(.system(.callout, design: .rounded).weight(.medium))
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(.thinMaterial)
                )
                .background(
                    Capsule().fill(Theme.accent.opacity(hovering && enabled ? 0.16 : 0.0))
                )
                .overlay(
                    Capsule().strokeBorder(hovering && enabled ? Theme.accent.opacity(0.5) : Theme.hairline, lineWidth: 1)
                )
        }
    }
}

/// No chrome, just feedback and the hand cursor (rows, links, icon buttons).
struct PlainPointerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration) { hovering, _ in
            configuration.label
                .opacity(hovering ? 0.85 : 1)
        }
    }
}

/// Shared hover/pressed/disabled handling for the custom styles.
private struct StyledButton<Label: View>: View {
    let configuration: ButtonStyleConfiguration
    @ViewBuilder let label: (_ hovering: Bool, _ enabled: Bool) -> Label

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        label(hovering, isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .pointingHandCursor(isEnabled)
    }
}

// MARK: - Translucent backgrounds

/// An AppKit vibrancy view (the desktop shows through with `.behindWindow`).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Main content backdrop: translucent window material with a soft blue glow.
struct ContentBackdrop: View {
    var body: some View {
        ZStack {
            VisualEffectBackground(material: .underWindowBackground)
            RadialGradient(
                colors: [Theme.accentDeep.opacity(0.16), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 700
            )
            .allowsHitTesting(false)
        }
    }
}

/// Frosted-glass surface used by cards and panels.
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = Theme.cornerRadius

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.14), Color.white.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.12), radius: 14, y: 6)
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = Theme.cornerRadius) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius))
    }
}
