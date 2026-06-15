import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Color {
    /// Ba-Chan's "screen": pure **white in Light** mode, pure **black in Dark** — the
    /// exact opposite of `.primary` (the ink). Backgrounds use `.screen`; faces, text
    /// and filled controls use `.primary`, so the whole strictly-monochrome UI inverts
    /// cleanly with the system theme.
    static var screen: Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
        })
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .black : .white
        })
        #endif
    }
}
