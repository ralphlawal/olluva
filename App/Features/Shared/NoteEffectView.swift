import CoupleDesign
import CoupleDomain
import SwiftUI

/// The flourish a note can open with: a couple of seconds of hearts rising,
/// confetti falling or sparkles appearing, drawn over the note and never in
/// the way of it. Purely decorative, so it is skipped entirely when Reduce
/// Motion is on.
struct NoteEffectView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let effect: NoteStyle.Effect
    @State private var start = Date()

    static let duration: TimeInterval = 2.8
    private static let count = 34

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let elapsed = timeline.date.timeIntervalSince(start)
                    guard elapsed < Self.duration else { return }
                    for index in 0..<Self.count {
                        draw(index, at: elapsed, in: size, context: &context)
                    }
                } symbols: {
                    Image(systemName: "heart.fill").font(.system(size: 26)).tag("heart")
                    Image(systemName: "sparkle").font(.system(size: 24)).tag("sparkle")
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { start = Date() }
        }
    }

    /// Stable pseudo-random numbers per particle, so a particle keeps its
    /// course from one frame to the next.
    private func random(_ index: Int, _ salt: Int) -> CGFloat {
        var value = UInt64(truncatingIfNeeded: index &* 73_856_093 ^ salt &* 19_349_663) &+ 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return CGFloat((value ^ (value >> 31)) % 10_000) / 10_000
    }

    private static let confettiColours = ["#C9566B", "#E0913A", "#D9A441", "#5C8A62", "#3F7FB0", "#7A5CC2", "#E58FA0"]
    private static let heartColours = ["#C9566B", "#E58FA0", "#B4566A", "#F2B6C1"]
    private static let sparkleColours = ["#D9A441", "#F4E3B0", "#B78FD6", "#FFFFFF"]

    private func draw(_ index: Int, at elapsed: TimeInterval, in size: CGSize, context: inout GraphicsContext) {
        let delay = Double(random(index, 1)) * 0.9
        let life = 1.5 + Double(random(index, 2)) * 0.7
        let progress = (elapsed - delay) / life
        guard progress > 0, progress < 1 else { return }
        let x = random(index, 3) * size.width
        let scale = 0.5 + random(index, 4) * 0.9
        let fade = min(1, progress * 5) * min(1, (1 - progress) * 2.5)
        var layer = context
        layer.opacity = fade

        switch effect {
        case .hearts:
            let sway = sin(progress * .pi * 2 + Double(random(index, 5)) * 6) * 18
            layer.translateBy(x: x + sway, y: size.height * (1.05 - progress * 0.95))
            layer.scaleBy(x: scale, y: scale)
            tint(&layer, Self.heartColours[index % Self.heartColours.count])
            if let symbol = context.resolveSymbol(id: "heart") { layer.draw(symbol, at: .zero) }
        case .confetti:
            let drift = (random(index, 5) - 0.5) * 90 * progress
            layer.translateBy(x: x + drift, y: size.height * (-0.05 + progress * 1.05))
            layer.rotate(by: .degrees(progress * 540 * Double(random(index, 6) - 0.5) * 2))
            let piece = CGRect(x: -5 * scale, y: -8 * scale, width: 10 * scale, height: 16 * scale)
            layer.fill(Path(roundedRect: piece, cornerRadius: 2), with: .color(Color(hex: Self.confettiColours[index % Self.confettiColours.count])))
        case .sparkles:
            let pulse = sin(progress * .pi)
            layer.translateBy(x: x, y: random(index, 7) * size.height)
            layer.scaleBy(x: scale * pulse * 1.3, y: scale * pulse * 1.3)
            layer.rotate(by: .degrees(progress * 60))
            tint(&layer, Self.sparkleColours[index % Self.sparkleColours.count])
            if let symbol = context.resolveSymbol(id: "sparkle") { layer.draw(symbol, at: .zero) }
        }
    }

    /// Symbols are drawn as templates; this gives the next one its colour.
    private func tint(_ layer: inout GraphicsContext, _ hex: String) {
        layer.addFilter(.colorMultiply(Color(hex: hex)))
    }
}
