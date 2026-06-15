#if os(iOS)
import UIKit
#endif
import CoreGraphics

/// Thin wrapper over the platform's haptic feedback. Exposes its OWN style/type
/// enums on every platform so call sites (e.g. `FaceController`) never reference a
/// UIKit type — on iOS they map to `UIImpactFeedbackGenerator` / `UINotification‑
/// FeedbackGenerator`; on macOS (no Taptic Engine) every call is a no-op. No-ops on
/// the Simulator too, so it's safe to call anywhere.
enum Haptics {
    enum ImpactStyle { case light, medium, heavy, soft, rigid }
    enum NotifyType { case success, warning, error }

    @MainActor static func impact(_ style: ImpactStyle, intensity: CGFloat = 1.0) {
        #if os(iOS)
        let uiStyle: UIImpactFeedbackGenerator.FeedbackStyle
        switch style {
        case .light:  uiStyle = .light
        case .medium: uiStyle = .medium
        case .heavy:  uiStyle = .heavy
        case .soft:   uiStyle = .soft
        case .rigid:  uiStyle = .rigid
        }
        UIImpactFeedbackGenerator(style: uiStyle).impactOccurred(intensity: intensity)
        #endif
    }

    @MainActor static func notify(_ type: NotifyType) {
        #if os(iOS)
        let uiType: UINotificationFeedbackGenerator.FeedbackType
        switch type {
        case .success: uiType = .success
        case .warning: uiType = .warning
        case .error:   uiType = .error
        }
        UINotificationFeedbackGenerator().notificationOccurred(uiType)
        #endif
    }
}
