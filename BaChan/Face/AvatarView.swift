import SwiftUI

/// Renders Stackchan's face procedurally with a `Canvas`, the same idea as the
/// M5Stack-Avatar library: everything is drawn from a handful of numbers
/// (eye openness, gaze, brows, mouth) so the face can be any size and animate
/// smoothly. A `TimelineView(.animation)` ticks every frame to drive breathing.
struct AvatarView: View {
    @ObservedObject var face: FaceController

    /// Face feature color and screen background — the "screen" Stackchan lives on.
    var feature = Color(white: 0.97)
    var background = Color(white: 0.04)   // pure grayscale — strictly black-and-white
    /// Uniformly zooms the whole face within its frame — all features AND their
    /// spacing scale together, so proportions are preserved (eyes, brows and mouth
    /// stay balanced). 1 = the tuned look; the tiny macOS menu-bar face uses a larger
    /// scale so it reads as boldly as a filled icon rather than thin line-art.
    var scale: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    draw(into: &context,
                         size: size,
                         time: timeline.date.timeIntervalSinceReferenceDate)
                }
                .drawingGroup()
            }
            .background(background)
            .contentShape(Rectangle())
            // Touch Ba-Chan's face: poke eyes/mouth, pat its head, stroke a cheek.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let layout = FaceLayout(size: geo.size, genome: face.genomeShown)
                        let moved = hypot(value.location.x - value.startLocation.x,
                                          value.location.y - value.startLocation.y)
                        face.touch(layout.region(at: value.location),
                                   moving: moved > layout.unit * 0.03)
                    }
                    .onEnded { _ in face.releaseTouch() }
            )
        }
        .ignoresSafeArea()
    }

    private func draw(into ctx: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        // Ease every rendered value toward its target for this frame.
        face.advance(to: time)

        // Uniform face zoom: scaling the unit grows every feature and its spacing
        // together, keeping the proportions identical to the full-size face.
        let unit = min(size.width, size.height) * scale
        // Gentle breathing: the whole face rises and falls a couple of points.
        let breath = CGFloat(sin(time * 1.7)) * unit * 0.007
        let center = CGPoint(x: size.width / 2, y: size.height / 2 + breath)

        // Head tilt: rotate the whole drawing around the face center (touch/sleep
        // tilt + device-motion gravity tilt).
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: .radians(Double(face.tilt + face.gravityTilt)))
        ctx.translateBy(x: -center.x, y: -center.y)

        // The evolved look: the genome scales features and adds the marks a life
        // together leaves (laugh lines, a resting glow).
        let genome = face.genomeShown
        let eyeDX = unit * 0.19 * genome.eyeSpacing
        let eyeY = center.y - unit * 0.05
        let eyeR = unit * 0.085 * genome.eyeScale
        let gaze = CGPoint(x: face.gaze.x * unit * 0.03, y: face.gaze.y * unit * 0.03)

        for sign in [-1.0, 1.0] as [CGFloat] {
            let eyeCenter = CGPoint(x: center.x + sign * eyeDX + gaze.x,
                                    y: eyeY + gaze.y)
            if face.blush > 0.01, face.intro >= 1 {
                drawBlush(into: &ctx, eyeCenter: eyeCenter, eyeR: eyeR)
            }
            if genome.smileLines > 0.03, face.intro >= 1 {
                drawSmileLine(into: &ctx, eyeCenter: eyeCenter, eyeR: eyeR,
                              side: sign, unit: unit, depth: genome.smileLines)
            }
            // Launch trace order: left eye, right eye, then brows, then mouth.
            drawEye(into: &ctx, at: eyeCenter, radius: eyeR,
                    phase: introPhase(sign < 0 ? 0.00 : 0.14, sign < 0 ? 0.42 : 0.56))
            drawBrow(into: &ctx, eyeCenter: eyeCenter, radius: eyeR, side: sign, unit: unit,
                     phase: introPhase(sign < 0 ? 0.34 : 0.42, sign < 0 ? 0.66 : 0.74))
        }

        let mouthCenter = CGPoint(x: center.x + gaze.x * 0.5, y: center.y + unit * 0.17)
        drawMouth(into: &ctx, center: mouthCenter, unit: unit, phase: introPhase(0.60, 1.0))

        // The worn accessory (genome catalog pick), crossfaded on swaps. Drawn
        // after the features so glasses rims read over the filled eyes.
        if face.accessoryAlpha > 0.02, face.intro >= 1 {
            drawAccessory(face.accessoryShown, into: &ctx, center: center,
                          eyeDX: eyeDX, eyeY: eyeY, eyeR: eyeR, unit: unit,
                          alpha: Double(face.accessoryAlpha))
        }

        // Whatever Ba-Chan settled into while idle gets its little prop: drifting
        // z's for a doze, a book, a teacup, music notes, the cooking pot.
        if face.intro >= 1 {
            switch face.pastime {
            case .sleeping: drawSleepZ(into: &ctx, center: center, unit: unit, time: time)
            case .reading:  drawBook(into: &ctx, center: center, unit: unit)
            case .tea:      drawTeacup(into: &ctx, center: center, unit: unit, time: time)
            case .humming:  drawNotes(into: &ctx, center: center, unit: unit, time: time)
            case .cooking:  drawPot(into: &ctx, center: center, unit: unit, time: time)
            case .none:     break
            }
        }
    }

    // MARK: - Accessories (the genome's curated catalog — procedural line art)

    private func drawAccessory(_ accessory: FaceGenome.Accessory,
                               into ctx: inout GraphicsContext, center: CGPoint,
                               eyeDX: CGFloat, eyeY: CGFloat, eyeR: CGFloat,
                               unit: CGFloat, alpha: Double) {
        switch accessory {
        case .none: break
        case .flower:  drawFlower(into: &ctx, center: center, eyeDX: eyeDX,
                                  eyeY: eyeY, eyeR: eyeR, unit: unit, alpha: alpha)
        case .glasses: drawGlasses(into: &ctx, center: center, eyeDX: eyeDX,
                                   eyeY: eyeY, eyeR: eyeR, unit: unit, alpha: alpha)
        case .hairpin: drawHairpin(into: &ctx, center: center, eyeDX: eyeDX,
                                   eyeY: eyeY, eyeR: eyeR, unit: unit, alpha: alpha)
        }
    }

    /// A little five-petal flower tucked up by the viewer's left temple.
    private func drawFlower(into ctx: inout GraphicsContext, center: CGPoint,
                            eyeDX: CGFloat, eyeY: CGFloat, eyeR: CGFloat,
                            unit: CGFloat, alpha: Double) {
        let fc = CGPoint(x: center.x - eyeDX - eyeR * 1.7, y: eyeY - eyeR * 2.1)
        let petal = eyeR * 0.34
        let lw = unit * 0.010
        for i in 0..<5 {
            let a = Double(i) * (2 * .pi / 5) - .pi / 2
            let pc = CGPoint(x: fc.x + CGFloat(cos(a)) * petal * 1.15,
                             y: fc.y + CGFloat(sin(a)) * petal * 1.15)
            let ring = Path(ellipseIn: CGRect(x: pc.x - petal / 2, y: pc.y - petal / 2,
                                              width: petal, height: petal))
            ctx.stroke(ring, with: .color(feature.opacity(0.85 * alpha)),
                       style: StrokeStyle(lineWidth: lw))
        }
        let heart = Path(ellipseIn: CGRect(x: fc.x - petal * 0.32, y: fc.y - petal * 0.32,
                                           width: petal * 0.64, height: petal * 0.64))
        ctx.fill(heart, with: .color(feature.opacity(0.85 * alpha)))
    }

    /// Round reading glasses: a rim around each eye, a soft bridge, and little
    /// temple arms. Rims sit on the resting eye centers (not the gaze), like
    /// real frames the eyes move behind.
    private func drawGlasses(into ctx: inout GraphicsContext, center: CGPoint,
                             eyeDX: CGFloat, eyeY: CGFloat, eyeR: CGFloat,
                             unit: CGFloat, alpha: Double) {
        let r = eyeR * 1.55
        let lw = unit * 0.012
        let style = StrokeStyle(lineWidth: lw, lineCap: .round)
        for sign in [-1.0, 1.0] as [CGFloat] {
            let c = CGPoint(x: center.x + sign * eyeDX, y: eyeY)
            let rim = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r,
                                             width: r * 2, height: r * 2))
            ctx.stroke(rim, with: .color(feature.opacity(0.8 * alpha)), style: style)
            var arm = Path()
            arm.move(to: CGPoint(x: c.x + sign * r, y: c.y))
            arm.addLine(to: CGPoint(x: c.x + sign * (r + eyeR * 0.55), y: c.y - eyeR * 0.3))
            ctx.stroke(arm, with: .color(feature.opacity(0.8 * alpha)), style: style)
        }
        var bridge = Path()
        bridge.move(to: CGPoint(x: center.x - eyeDX + r, y: eyeY))
        bridge.addQuadCurve(to: CGPoint(x: center.x + eyeDX - r, y: eyeY),
                            control: CGPoint(x: center.x, y: eyeY - r * 0.35))
        ctx.stroke(bridge, with: .color(feature.opacity(0.8 * alpha)), style: style)
    }

    /// A slanted hair clip with a tiny bead, up by the viewer's right temple.
    private func drawHairpin(into ctx: inout GraphicsContext, center: CGPoint,
                             eyeDX: CGFloat, eyeY: CGFloat, eyeR: CGFloat,
                             unit: CGFloat, alpha: Double) {
        let base = CGPoint(x: center.x + eyeDX + eyeR * 1.3, y: eyeY - eyeR * 2.3)
        let len = eyeR * 1.5
        let lw = unit * 0.016
        var bar = Path()
        bar.move(to: base)
        bar.addLine(to: CGPoint(x: base.x + len * 0.87, y: base.y + len * 0.5))
        ctx.stroke(bar, with: .color(feature.opacity(0.85 * alpha)),
                   style: StrokeStyle(lineWidth: lw, lineCap: .round))
        let bead = eyeR * 0.30
        let dot = Path(ellipseIn: CGRect(x: base.x - bead / 2, y: base.y - bead / 2,
                                         width: bead, height: bead))
        ctx.fill(dot, with: .color(feature.opacity(0.85 * alpha)))
    }

    // MARK: - Pastime props (procedural line art, all in the feature color)

    /// An open book below the face — two gently curved pages with a hint of text.
    private func drawBook(into ctx: inout GraphicsContext, center: CGPoint, unit: CGFloat) {
        let y = center.y + unit * 0.40
        let w = unit * 0.17, h = unit * 0.105
        let lw = unit * 0.012
        for side in [-1.0, 1.0] as [CGFloat] {
            var page = Path()
            page.move(to: CGPoint(x: center.x, y: y + h * 0.12))
            page.addQuadCurve(to: CGPoint(x: center.x + side * w, y: y - h * 0.18),
                              control: CGPoint(x: center.x + side * w * 0.45, y: y - h * 0.22))
            page.addLine(to: CGPoint(x: center.x + side * w, y: y + h * 0.62))
            page.addQuadCurve(to: CGPoint(x: center.x, y: y + h),
                              control: CGPoint(x: center.x + side * w * 0.45, y: y + h * 0.66))
            page.closeSubpath()
            ctx.stroke(page, with: .color(feature.opacity(0.85)),
                       style: StrokeStyle(lineWidth: lw, lineJoin: .round))
            for i in 0..<2 {   // a couple of "text" lines per page
                var line = Path()
                let ly = y + h * (0.2 + 0.26 * CGFloat(i))
                line.move(to: CGPoint(x: center.x + side * w * 0.2, y: ly))
                line.addLine(to: CGPoint(x: center.x + side * w * 0.75, y: ly - h * 0.08))
                ctx.stroke(line, with: .color(feature.opacity(0.45)),
                           style: StrokeStyle(lineWidth: lw * 0.8, lineCap: .round))
            }
        }
    }

    /// Rising, swaying steam strands — shared by the teacup and the cooking pot.
    private func drawSteam(into ctx: inout GraphicsContext, baseX: CGFloat, baseY: CGFloat,
                           unit: CGFloat, time: TimeInterval, strands: Int) {
        for i in 0..<strands {
            let phase = time * 1.1 + Double(i) * 1.9
            let rise = unit * 0.15
            var path = Path()
            for step in 0...10 {
                let f = CGFloat(step) / 10
                let x = baseX + (CGFloat(i) - CGFloat(strands - 1) / 2) * unit * 0.05
                    + CGFloat(sin(phase * 2 + Double(f) * 4.2)) * unit * 0.02 * f
                let point = CGPoint(x: x, y: baseY - f * rise)
                step == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            ctx.stroke(path, with: .color(feature.opacity(0.32 + 0.18 * sin(phase))),
                       style: StrokeStyle(lineWidth: unit * 0.01, lineCap: .round))
        }
    }

    /// A teacup with a handle, a saucer line, and steam — off to one side, where
    /// the lowered gaze rests.
    private func drawTeacup(into ctx: inout GraphicsContext, center: CGPoint,
                            unit: CGFloat, time: TimeInterval) {
        let cx = center.x + unit * 0.22
        let cy = center.y + unit * 0.37
        let w = unit * 0.12, h = unit * 0.085
        let lw = unit * 0.012
        let body = Path(roundedRect: CGRect(x: cx - w / 2, y: cy, width: w, height: h),
                        cornerRadius: h * 0.4)
        ctx.stroke(body, with: .color(feature.opacity(0.85)), style: StrokeStyle(lineWidth: lw))
        let handle = Path(ellipseIn: CGRect(x: cx + w / 2 - lw * 0.5, y: cy + h * 0.2,
                                            width: w * 0.36, height: w * 0.36))
        ctx.stroke(handle, with: .color(feature.opacity(0.85)), style: StrokeStyle(lineWidth: lw))
        var saucer = Path()
        saucer.move(to: CGPoint(x: cx - w * 0.8, y: cy + h + lw * 1.6))
        saucer.addLine(to: CGPoint(x: cx + w * 0.8, y: cy + h + lw * 1.6))
        ctx.stroke(saucer, with: .color(feature.opacity(0.6)),
                   style: StrokeStyle(lineWidth: lw, lineCap: .round))
        drawSteam(into: &ctx, baseX: cx, baseY: cy - lw, unit: unit, time: time, strands: 2)
    }

    /// Music notes drifting up and away while Ba-Chan hums.
    private func drawNotes(into ctx: inout GraphicsContext, center: CGPoint,
                           unit: CGFloat, time: TimeInterval) {
        let base = CGPoint(x: center.x + unit * 0.28, y: center.y + unit * 0.08)
        let glyphs = ["♪", "♫", "♪"]
        for i in 0..<3 {
            let phase = (time * 0.55 + Double(i) * 0.8).truncatingRemainder(dividingBy: 2.4)
            let rise = CGFloat(phase) * unit * 0.07
            let size = max(unit * (0.05 + 0.012 * CGFloat(i)), 5)
            let opacity = max(0, 1 - phase / 2.4)
            let sway = CGFloat(sin(time * 2 + Double(i) * 1.3)) * unit * 0.012
            ctx.draw(Text(glyphs[i]).font(.system(size: size, weight: .semibold))
                        .foregroundColor(feature.opacity(opacity)),
                     at: CGPoint(x: base.x + CGFloat(i) * unit * 0.045 + sway,
                                 y: max(base.y - rise, size)))
        }
    }

    /// A cooking pot below the face — body, rim, two handles, and busy steam.
    private func drawPot(into ctx: inout GraphicsContext, center: CGPoint,
                         unit: CGFloat, time: TimeInterval) {
        let cy = center.y + unit * 0.38
        let w = unit * 0.22, h = unit * 0.10
        let lw = unit * 0.012
        let body = Path(roundedRect: CGRect(x: center.x - w / 2, y: cy, width: w, height: h),
                        cornerRadius: h * 0.25)
        ctx.stroke(body, with: .color(feature.opacity(0.85)), style: StrokeStyle(lineWidth: lw))
        var rim = Path()
        rim.move(to: CGPoint(x: center.x - w / 2, y: cy + h * 0.22))
        rim.addLine(to: CGPoint(x: center.x + w / 2, y: cy + h * 0.22))
        ctx.stroke(rim, with: .color(feature.opacity(0.6)), style: StrokeStyle(lineWidth: lw * 0.8))
        for side in [-1.0, 1.0] as [CGFloat] {
            var handle = Path()
            handle.move(to: CGPoint(x: center.x + side * w / 2, y: cy + h * 0.35))
            handle.addLine(to: CGPoint(x: center.x + side * (w / 2 + w * 0.12), y: cy + h * 0.3))
            ctx.stroke(handle, with: .color(feature.opacity(0.85)),
                       style: StrokeStyle(lineWidth: lw * 1.4, lineCap: .round))
        }
        drawSteam(into: &ctx, baseX: center.x, baseY: cy - lw, unit: unit, time: time, strands: 3)
    }

    /// 0…1 progress of one feature's slice of the launch trace (smoothstepped);
    /// 1 whenever no trace is playing, so normal rendering costs nothing extra.
    private func introPhase(_ start: Double, _ end: Double) -> CGFloat {
        let t = Double(face.intro)
        guard t < 1 else { return 1 }
        let raw = min(1, max(0, (t - start) / (end - start)))
        return CGFloat(raw * raw * (3 - 2 * raw))
    }

    /// Draw a feature mid-trace: the path's outline draws on like a pen stroke
    /// (an SVG-style route animation via `trimmedPath`), and the solid fill
    /// crossfades in over the last stretch of the stroke.
    private func trace(_ path: Path, into ctx: inout GraphicsContext,
                       phase: CGFloat, lineWidth: CGFloat) {
        guard phase > 0 else { return }
        ctx.stroke(path.trimmedPath(from: 0, to: phase), with: .color(feature),
                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        let fillIn = Double(max(0, (phase - 0.6) / 0.4))
        if fillIn > 0 { ctx.fill(path, with: .color(feature.opacity(fillIn))) }
    }

    /// Floating "z z z" that drift up while Ba-Chan dozes.
    private func drawSleepZ(into ctx: inout GraphicsContext, center: CGPoint, unit: CGFloat, time: TimeInterval) {
        let base = CGPoint(x: center.x + unit * 0.27, y: center.y - unit * 0.16)
        for i in 0..<3 {
            let phase = (time * 0.5 + Double(i) * 0.7).truncatingRemainder(dividingBy: 2.1)
            let rise = CGFloat(phase) * unit * 0.05
            // Floor the size so the "z"s stay legible on the tiny menu-bar face (where
            // `unit` is small); the large face is unaffected (its proportional size wins).
            let size = max(unit * (0.05 + 0.018 * CGFloat(i)), 5 + CGFloat(i) * 1.5)
            let opacity = max(0, 1 - phase / 2.1)
            let text = Text("z")
                .font(.system(size: size, weight: .bold, design: .rounded))
                .foregroundColor(feature.opacity(opacity))
            // Keep them from drifting off the top edge of the small tray tile.
            let zy = max(base.y - rise, size)
            ctx.draw(text, at: CGPoint(x: base.x + CGFloat(i) * unit * 0.035, y: zy))
        }
    }

    private func drawEye(into ctx: inout GraphicsContext, at c: CGPoint, radius: CGFloat,
                         phase: CGFloat = 1) {
        // Combine blink (eyeOpen), the expression's resting squint, and any
        // touch-driven squeeze (poking/petting closes the eyes).
        let openness = max(0.04, face.eyeOpen * (1 - face.eyeSquint) * (1 - face.squeeze * 0.95))
        let halfHeight = radius * openness
        let rect = CGRect(x: c.x - radius, y: c.y - halfHeight,
                          width: radius * 2, height: halfHeight * 2)
        // A capsule reads as a round eye when open and a soft bar when shut.
        let path = Capsule().path(in: rect)
        if phase >= 1 {
            ctx.fill(path, with: .color(feature))
        } else {
            trace(path, into: &ctx, phase: phase, lineWidth: radius * 0.22)
        }
    }

    /// A laugh line beside each eye — a small arc that deepens with the genome's
    /// `smileLines`, the trace warm days leave on the resting face.
    private func drawSmileLine(into ctx: inout GraphicsContext, eyeCenter c: CGPoint,
                               eyeR: CGFloat, side: CGFloat, unit: CGFloat,
                               depth: CGFloat) {
        let x0 = c.x + side * eyeR * 1.45
        var path = Path()
        path.move(to: CGPoint(x: x0, y: c.y + eyeR * 0.05))
        path.addQuadCurve(to: CGPoint(x: x0 + side * eyeR * 0.30, y: c.y + eyeR * 0.85),
                          control: CGPoint(x: x0 + side * eyeR * 0.42, y: c.y + eyeR * 0.42))
        ctx.stroke(path, with: .color(feature.opacity(0.10 + 0.32 * Double(depth))),
                   style: StrokeStyle(lineWidth: unit * 0.008, lineCap: .round))
    }

    private func drawBrow(into ctx: inout GraphicsContext, eyeCenter c: CGPoint,
                          radius: CGFloat, side: CGFloat, unit: CGFloat,
                          phase: CGFloat = 1) {
        let browW = radius * 1.7
        let browH = radius * 0.24 * face.genomeShown.browWeight
        // browRaise is a fraction of the face unit, so the lift scales with size
        // (a fixed point offset flew off the top of the tiny menu-bar face).
        let cy = c.y - radius * 1.75 + face.browRaise * unit
        let base = Path(roundedRect: CGRect(x: -browW / 2, y: -browH / 2,
                                            width: browW, height: browH),
                        cornerRadius: browH / 2)
        // Rotate around origin (mirror the angle for the right brow), then move
        // up above the eye.
        let angle = Angle.degrees(Double(face.browAngle) * Double(side)).radians
        let transform = CGAffineTransform(translationX: c.x, y: cy).rotated(by: angle)
        let path = base.applying(transform)
        if phase >= 1 {
            ctx.fill(path, with: .color(feature))
        } else {
            trace(path, into: &ctx, phase: phase, lineWidth: browH * 0.5)
        }
    }

    private func drawBlush(into ctx: inout GraphicsContext, eyeCenter c: CGPoint, eyeR: CGFloat) {
        let rect = CGRect(x: c.x - eyeR * 0.6, y: c.y + eyeR * 0.9,
                          width: eyeR * 1.2, height: eyeR * 0.7)
        // Monochrome blush — a soft white glow on the cheeks, not pink.
        ctx.fill(Ellipse().path(in: rect),
                 with: .color(feature.opacity(0.20 * Double(face.blush))))
    }

    private func drawMouth(into ctx: inout GraphicsContext, center: CGPoint, unit: CGFloat,
                           phase: CGFloat = 1) {
        let curve = face.mouthCurve
        let width = unit * 0.24 * face.genomeShown.mouthWidth
        let open = face.mouth

        if open > 0.08, phase >= 1 {
            // Talking: a filled rounded shape whose height tracks the lip-sync level.
            let height = max(unit * 0.02, open * unit * 0.14)
            let rect = CGRect(x: center.x - width * 0.34, y: center.y - height / 2,
                              width: width * 0.68, height: height)
            ctx.fill(Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2.1),
                     with: .color(feature))
        } else {
            // Quiet: a curved stroke that smiles or frowns with the expression.
            let lift = curve * unit * 0.05
            var path = Path()
            let left = CGPoint(x: center.x - width / 2, y: center.y - lift)
            let right = CGPoint(x: center.x + width / 2, y: center.y - lift)
            let control = CGPoint(x: center.x, y: center.y + lift * 1.6 + unit * 0.012)
            path.move(to: left)
            path.addQuadCurve(to: right, control: control)
            // Already a stroke — during the launch trace it simply draws on
            // left-to-right; afterwards `phase` is 1 and this is the full curve.
            ctx.stroke(phase >= 1 ? path : path.trimmedPath(from: 0, to: phase),
                       with: .color(feature),
                       style: StrokeStyle(lineWidth: unit * 0.02 * face.genomeShown.strokeWeight,
                                          lineCap: .round))
        }
    }
}

#Preview {
    let face = FaceController()
    face.start()
    face.set(.sleepy)
    return AvatarView(face: face)
}
