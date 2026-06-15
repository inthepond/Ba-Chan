import SwiftUI
import AVFoundation

/// Renders the camera as an **Apple Vision Pro–style** visor across Ba-Chan's
/// eyes: one smooth curved dark-glass front, an aluminum rim, and a slim knit
/// strap. The feed shows faintly through the glass, and the gloss **reflects the
/// real surrounding light in real time** (driven by `camera.reflection`, a tiny
/// live snapshot composited back with an additive blend). Aligned via `FaceLayout`.
struct GoggleView: View {
    @ObservedObject var camera: CameraService
    /// Tapping the visor flips the camera.
    var onFlip: () -> Void = {}

    var body: some View {
        GeometryReader { geo in
            let layout = FaceLayout(size: geo.size)
            let left = layout.eyeCenter(side: -1)
            let right = layout.eyeCenter(side: 1)

            let visorW = (right.x - left.x) + layout.eyeR * 4.9
            let visorH = layout.eyeR * 3.4
            let visorRect = CGRect(x: layout.center.x - visorW / 2,
                                   y: layout.eyeY - visorH / 2,
                                   width: visorW, height: visorH)
            let visor = VisorShape(rect: visorRect, bow: 0.085)
            let frameRect = visorRect.insetBy(dx: -layout.unit * 0.011, dy: -layout.unit * 0.011)
            let rim = VisorShape(rect: frameRect, bow: 0.085)

            // Front camera = facing the user: just show the eyes (through a faded
            // lens) and make eye contact — no bright reflections washing them out.
            let facingUser = camera.position == .front

            ZStack {
                // Brushed-aluminum rim.
                rim.fill(LinearGradient(colors: [Color(white: 0.82), Color(white: 0.44), Color(white: 0.72)],
                                        startPoint: .top, endPoint: .bottom))

                // Live reflection on the metal rim (back camera only).
                if !facingUser, let refl = camera.reflection {
                    Image(decorative: refl, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFill()
                        .frame(width: frameRect.width + layout.eyeR, height: frameRect.height + layout.eyeR)
                        .position(x: layout.center.x, y: layout.eyeY)
                        .blur(radius: layout.unit * 0.006)   // crisp, metallic
                        .blendMode(.plusLighter)
                        .opacity(0.65)
                        .mask(rim)
                }

                // Camera feed, clipped to the glass, darkened. Front camera fades
                // way down so Ba-Chan's eyes show through and track you.
                CameraPreview(session: camera.session)
                    .opacity(facingUser ? 0.12 : 1)
                    .mask(visor)
                visor.fill(LinearGradient(
                    colors: facingUser ? [Color.black.opacity(0.08), Color.black.opacity(0.22)]
                                       : [Color.black.opacity(0.46), Color.black.opacity(0.74)],
                    startPoint: .top, endPoint: .bottom))

                // Real-time glass reflection of the surroundings (back camera only).
                if !facingUser, let refl = camera.reflection {
                    Image(decorative: refl, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFill()
                        .frame(width: visorW, height: visorH)
                        .position(x: layout.center.x, y: layout.eyeY)
                        .blur(radius: visorH * 0.40)
                        .blendMode(.plusLighter)
                        .opacity(0.3)
                        .mask(visor)
                }

                // Fixed specular gloss (toned down when facing the user).
                visor.fill(LinearGradient(colors: [Color.white.opacity(facingUser ? 0.05 : 0.16), .clear],
                                          startPoint: .top, endPoint: .center))
                    .blendMode(.plusLighter)

                // Rims.
                visor.stroke(Color.black.opacity(0.5), lineWidth: layout.unit * 0.006)
                rim.stroke(Color(white: 0.9).opacity(0.8), lineWidth: layout.unit * 0.004)
            }
            .contentShape(visor)
            .onTapGesture(perform: onFlip)
        }
    }
}

/// A smooth visor silhouette: rounded ends with gently bowed top/bottom edges so
/// it reads as a sculpted goggle (not a flat pill). `bow` = how much the long
/// edges bow outward, as a fraction of height.
struct VisorShape: Shape {
    let rect: CGRect
    var bow: CGFloat = 0.08

    func path(in _: CGRect) -> Path {
        let r = rect
        let end = r.height * 0.46           // horizontal reach of the rounded ends
        let bowY = r.height * bow
        let cx = r.midX

        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.minX + end, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - end, y: r.minY), control: CGPoint(x: cx, y: r.minY - bowY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.midY), control: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - end, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + end, y: r.maxY), control: CGPoint(x: cx, y: r.maxY + bowY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.midY), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
