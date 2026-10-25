import AppKit
import CoreText
import SwiftUI

/// The app's design tokens. Every color is scheme-dynamic (light/dark) via
/// `NSColor(name:dynamicProvider:)`, so the whole UI adapts when the user
/// switches appearance — no per-view branching.
///
/// Hallmark · redesign · theme: adaptive light/dark, warm gradient accent
/// (Nothing red → warm orange) · type: Geist body 14–15 / Geist Mono meta /
/// Doto display-only. Pre-emit critique: P4 H5 E5 S4 R4 V4.
enum ND {
    // MARK: Scheme-dynamic palette

    /// Window canvas — used as the top stop of the background gradient.
    static let background = Color(dynamicLight: 0xF4F4F7, dark: 0x0B0B0F)
    /// Bottom stop of the background gradient (a shade toward indigo).
    static let backgroundDeep = Color(dynamicLight: 0xE8E8F0, dark: 0x151521)
    /// Cards and elevated surfaces.
    static let surface = Color(dynamicLight: 0xFFFFFF, dark: 0x17171E)
    static let surfaceBorder = Color(dynamicLight: 0xE4E4EB, dark: 0x26262F)

    /// Body text — near-maximum contrast in both schemes.
    static let textPrimary = Color(dynamicLight: 0x15151A, dark: 0xF4F4F7)
    /// Secondary copy — still comfortably readable.
    static let textSecondary = Color(dynamicLight: 0x50505A, dark: 0xB4B4C0)
    /// Metadata only.
    static let textTertiary = Color(dynamicLight: 0x82828C, dark: 0x83838F)

    /// Nothing red, brightened a step for dark backgrounds.
    static let accent = Color(dynamicLight: 0xD71921, dark: 0xFF4438)
    /// The gradient's warm end.
    static let accentWarm = Color(dynamicLight: 0xFF6A3D, dark: 0xFF8A5C)
    static let error = Color(dynamicLight: 0xC2141C, dark: 0xFF5247)
    static let success = Color(dynamicLight: 0x2F7A3C, dark: 0x7BE38A)

    /// Selected-row fill — quiet tint, not full inversion.
    static let selectionFill = Color(dynamicLight: 0xF0E4E5, dark: 0x24242E)

    static let accentGradient = LinearGradient(
        colors: [accent, accentWarm],
        startPoint: .leading, endPoint: .trailing
    )

    static let backgroundGradient = LinearGradient(
        colors: [background, backgroundDeep],
        startPoint: .top, endPoint: .bottom
    )

    // MARK: Typography — generous sizes; body never below 14

    /// Detail body copy.
    static let body = Font.custom("Geist", size: 15)
    /// Row titles and control labels.
    static func ui(_ size: CGFloat = 14, weight: Font.Weight = .regular) -> Font {
        .custom("Geist", size: size).weight(weight)
    }
    /// Detail titles.
    static let title = Font.custom("Geist", size: 22).weight(.semibold)
    /// Section headings inside cards.
    static let sectionHead = Font.custom("Geist", size: 15).weight(.semibold)
    /// Metadata — mono, but never below 12pt.
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .custom("Geist Mono", size: size).weight(weight)
    }
    /// Large display numerals (OTP entry). Doto is illegible below ~20pt, so it
    /// is display-only by rule.
    static func display(_ size: CGFloat = 34) -> Font {
        .custom("Doto", size: size).weight(.regular)
    }
}

extension Color {
    /// Hex color that adapts between light and dark appearances.
    init(dynamicLight light: UInt32, dark: UInt32) {
        func nsColor(_ hex: UInt32) -> NSColor {
            NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
        self.init(
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                    ? nsColor(dark)
                    : nsColor(light)
            }
        )
    }
}

/// Registers the bundled variable fonts (Doto, Geist, Geist Mono) with the
/// process so `Font.custom` finds them. SIL OFL 1.1 — license ships alongside.
enum FontLoader {
    static func registerBundledFonts() {
        for name in ["Doto", "Geist", "GeistMono"] {
            let url =
                Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Resources/Fonts")
                ?? Bundle.module.url(forResource: name, withExtension: "ttf")
            guard let url else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

// MARK: Shared pieces

/// A card: elevated surface, hairline border, continuous 14pt corners.
struct CardStyle: ViewModifier {
    var padding: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ND.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(ND.surfaceBorder, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func card(padding: CGFloat = 24) -> some View {
        modifier(CardStyle(padding: padding))
    }

    /// The app canvas: vertical gradient behind everything.
    func appCanvas() -> some View {
        background(ND.backgroundGradient.ignoresSafeArea())
    }
}

/// Section heading inside a card — small, accent-marked, readable.
struct SectionHead: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(ND.accentGradient)
                .frame(width: 3, height: 14)
            Text(title)
                .font(ND.sectionHead)
                .foregroundStyle(ND.textPrimary)
        }
    }
}

/// Primary action: accent gradient fill, white label.
struct PrimaryButtonStyle: ButtonStyle {
    var expands = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ND.ui(14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .frame(minWidth: expands ? nil : 110, maxWidth: expands ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ND.accentGradient)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Secondary action: surface fill, hairline border.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ND.ui(13, weight: .medium))
            .foregroundStyle(ND.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ND.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(ND.surfaceBorder, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Labelled underlined text field with a visible focus state.
struct NDField: View {
    let title: String
    @Binding var text: String
    var secure: Bool = false

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(ND.mono(12, weight: .medium))
                .foregroundStyle(ND.textTertiary)
            Group {
                if secure {
                    SecureField("", text: $text)
                        .focused($focused)
                } else {
                    TextField("", text: $text)
                        .focused($focused)
                }
            }
            .textFieldStyle(.plain)
            .font(ND.ui(15))
            .foregroundStyle(ND.textPrimary)
            .padding(.horizontal, 4)
            .padding(.bottom, 9)
            .background(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(focused ? ND.accent : ND.surfaceBorder)
                    .frame(height: focused ? 2 : 1)
                    .animation(.easeInOut(duration: 0.15), value: focused)
            }
        }
    }
}
