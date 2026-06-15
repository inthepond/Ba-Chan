import SwiftUI

/// Little symbol bursts that punctuate Ba-Chan's reactions. SF Symbols, not
/// emoji (Ba-Chan never uses emoji).
enum FaceEffect {
    case hearts, sweat, anger, sparkle

    var systemImage: String {
        switch self {
        case .hearts:  return "heart.fill"
        case .sweat:   return "drop.fill"
        case .anger:   return "exclamationmark.2"
        case .sparkle: return "sparkles"
        }
    }

    /// Monochrome — the app is strictly black-and-white. Bursts read by symbol +
    /// brightness, not hue.
    var color: Color {
        switch self {
        case .hearts:  return .primary
        case .sweat:   return .primary.opacity(0.6)
        case .anger:   return .primary
        case .sparkle: return .primary
        }
    }
}

fileprivate struct Particle: Identifiable {
    let id = UUID()
    let kind: FaceEffect
    let birth: TimeInterval
    let origin: CGPoint        // normalized 0…1 of the view
    let vx: CGFloat            // velocity, fraction of min(size)/sec
    let vy: CGFloat
    let gravity: CGFloat
    let size: CGFloat          // fraction of min(size)
    let lifetime: TimeInterval
}

/// Holds active particles. `spawn` is called from reaction code; the overlay
/// renders them by elapsed time without per-frame state mutation.
@MainActor
final class ParticleSystem: ObservableObject {
    @Published fileprivate private(set) var particles: [Particle] = []

    func spawn(_ kind: FaceEffect, at origin: CGPoint = CGPoint(x: 0.5, y: 0.40)) {
        let now = Date().timeIntervalSinceReferenceDate
        particles.removeAll { now - $0.birth > $0.lifetime }   // prune expired

        let count: Int
        switch kind {
        case .hearts:  count = 3
        case .sparkle: count = 5
        case .anger:   count = 2
        case .sweat:   count = 1
        }
        for _ in 0..<count {
            particles.append(Particle(
                kind: kind,
                birth: now,
                origin: CGPoint(x: origin.x + .random(in: -0.07...0.07),
                                y: origin.y + .random(in: -0.05...0.05)),
                vx: .random(in: -0.06...0.06),
                vy: kind == .anger ? .random(in: -0.02...0.02)
                                   : .random(in: -0.22 ... -0.10),
                gravity: kind == .sweat ? 0.30 : 0.05,
                size: .random(in: 0.85...1.25),
                lifetime: kind == .anger ? 0.8 : 1.5))
        }
        if particles.count > 80 { particles.removeFirst(particles.count - 80) }
    }
}

/// Draws the live particles. Purely visual — never intercepts touches.
struct ParticleOverlay: View {
    @ObservedObject var system: ParticleSystem

    var body: some View {
        // Only run the per-frame Canvas/TimelineView while there are live
        // particles. When idle (the common case) this draws nothing, so it
        // stops rasterizing every frame and competing with the avatar loop and
        // MLX inference for the CPU/GPU.
        Group {
            if system.particles.isEmpty {
                Color.clear
            } else {
                TimelineView(.animation) { timeline in
                    Canvas { ctx, size in
                        let unit = min(size.width, size.height)
                        let now = timeline.date.timeIntervalSinceReferenceDate
                        for p in system.particles {
                            let t = now - p.birth
                            guard t >= 0, t < p.lifetime else { continue }
                            let progress = t / p.lifetime
                            let x = p.origin.x * size.width + p.vx * unit * CGFloat(t)
                            let y = p.origin.y * size.height
                                + p.vy * unit * CGFloat(t)
                                + p.gravity * unit * CGFloat(t * t)
                            let fontSize = unit * 0.07 * p.size * (kindScale(p.kind, progress))
                            let opacity = max(0, 1 - progress * progress)
                            var layer = ctx
                            layer.opacity = opacity
                            let glyph = Text(Image(systemName: p.kind.systemImage))
                                .font(.system(size: fontSize, weight: .bold))
                                .foregroundColor(p.kind.color)
                            layer.draw(glyph, at: CGPoint(x: x, y: y))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Sparkles/hearts pop in, anger marks are steady.
    private func kindScale(_ kind: FaceEffect, _ progress: Double) -> CGFloat {
        switch kind {
        case .sparkle, .hearts: return CGFloat(min(1, progress * 4))
        default:                return 1
        }
    }
}
