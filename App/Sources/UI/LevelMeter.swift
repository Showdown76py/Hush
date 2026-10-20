import SwiftUI

/// Vumètre horizontal animé (60 images/s), lissé avec maintien de crête.
struct LevelMeter: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    /// Niveau RMS linéaire, lu à chaque image.
    let level: () -> Float
    /// Décalage d'affichage en dB (compensation de gain).
    var offsetDB: Float = 0

    @State private var smoother = Smoother()

    var body: some View {
        TimelineView(.animation) { context in
            let value = smoother.update(db: dB(level()) + offsetDB, at: context.date)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                        .frame(width: 16)
                    Text(title)
                        .font(.callout)
                    Spacer()
                    Text(value.db > -59 ? "\(Int(value.db.rounded())) dB" : "–")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, geo.size.width * CGFloat(value.fraction)))
                        Capsule()
                            .fill(tint)
                            .frame(width: 3)
                            .offset(x: max(0, geo.size.width * CGFloat(value.peakFraction) - 3))
                            .opacity(value.peakFraction > 0.02 ? 1 : 0)
                    }
                }
                .frame(height: 8)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func dB(_ linear: Float) -> Float { 20 * log10(max(linear, 1e-6)) }

    /// État d'affichage : attaque rapide, retombée douce, crête maintenue 1 s.
    final class Smoother {
        private var shown: Float = -60
        private var peak: Float = -60
        private var peakTime = Date.distantPast
        private var last = Date()

        struct Value { var db: Float; var fraction: Float; var peakFraction: Float }

        func update(db: Float, at now: Date) -> Value {
            let dt = Float(min(now.timeIntervalSince(last), 0.1))
            last = now
            let target = max(-60, min(0, db))
            shown = target > shown ? target : max(target, shown - 30 * dt)   // retombe de 30 dB/s
            if shown >= peak || now.timeIntervalSince(peakTime) > 1 { peak = shown; peakTime = now }
            return Value(db: shown, fraction: (shown + 60) / 60, peakFraction: (peak + 60) / 60)
        }
    }
}
