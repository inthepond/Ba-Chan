import CoreGraphics
import Foundation

/// Where Ba-Chan's features sit for a given view size. One source of truth used
/// by the Canvas renderer, the touch hit-testing, and the camera goggles, so
/// they all stay aligned. (Mirrors the constants in `AvatarView.draw`.)
struct FaceLayout {
    let size: CGSize
    /// The evolved look — eye size/spacing shift with it, so hit-testing and the
    /// goggles stay aligned with what's actually drawn. Defaults to the neutral
    /// genome for callers that don't track evolution.
    var genome = FaceGenome()

    var unit: CGFloat { min(size.width, size.height) }
    var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    var eyeDX: CGFloat { unit * 0.19 * genome.eyeSpacing }
    var eyeY: CGFloat { center.y - unit * 0.05 }
    var eyeR: CGFloat { unit * 0.085 * genome.eyeScale }
    var mouthCenter: CGPoint { CGPoint(x: center.x, y: center.y + unit * 0.17) }

    /// side: -1 = viewer's left eye, +1 = viewer's right eye.
    func eyeCenter(side: CGFloat) -> CGPoint {
        CGPoint(x: center.x + side * eyeDX, y: eyeY)
    }

    /// Which part of the face a touch landed on.
    func region(at p: CGPoint) -> FaceRegion {
        if hypot(p.x - eyeCenter(side: -1).x, p.y - eyeY) < eyeR * 1.7 { return .leftEye }
        if hypot(p.x - eyeCenter(side: 1).x, p.y - eyeY) < eyeR * 1.7 { return .rightEye }
        if hypot(p.x - mouthCenter.x, p.y - mouthCenter.y) < unit * 0.14 { return .mouth }
        if p.y < eyeY - eyeR * 1.7 { return .head }
        if p.y > eyeY + eyeR * 0.6 && p.y < mouthCenter.y + unit * 0.06 {
            return p.x < center.x ? .leftCheek : .rightCheek
        }
        return .face
    }
}

enum FaceRegion: Equatable {
    case leftEye, rightEye, mouth, leftCheek, rightCheek, head, face
    var isEye: Bool { self == .leftEye || self == .rightEye }
}
