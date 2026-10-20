import SwiftUI

// Liquid Glass sur macOS 26+, avec un rendu équivalent (matériaux) sur macOS 14 et 15.

extension Color {
    /// Violet de l'icône (indépendant de la couleur d'accentuation choisie par l'utilisateur).
    static let hushBrand = Color(red: 0.43, green: 0.34, blue: 0.86)
}

extension View {
    /// Surface en verre (carte, pastille). `tint` colore le verre ; `interactive` réagit au pointeur.
    @ViewBuilder
    func hushGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint { shape.fill(tint.gradient) }
                }
            }
            .overlay(shape.stroke(.white.opacity(0.08), lineWidth: 0.5))
        }
    }

    /// Bouton en verre (`prominent` : action principale teintée).
    @ViewBuilder
    func hushGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

/// Regroupe des surfaces en verre pour qu'elles se fondent entre elles (macOS 26+).
struct HushGlassContainer<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
