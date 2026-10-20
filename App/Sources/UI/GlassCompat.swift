import SwiftUI

extension Color {
    /// icon purple, independent of the user's accent color
    static let hushBrand = Color(red: 0.43, green: 0.34, blue: 0.86)
}

extension View {
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

    @ViewBuilder
    func hushGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

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
