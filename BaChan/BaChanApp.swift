import SwiftUI

#if os(macOS)
import AppKit

/// A status-item hosting view that ignores clicks, so the menu-bar button itself
/// receives them (and toggles the popover). Without this the hosted SwiftUI face
/// would swallow the click.
private final class PassthroughHostingView: NSHostingView<AvatarView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Runs Ba-Chan as a menu-bar (system-tray) app on macOS. The tray icon is the LIVE
/// face — an `AvatarView` sharing the Conductor's `FaceController`, so it blinks,
/// breathes and changes mood exactly like the popover. Clicking it opens the full
/// face panel. No Dock icon / standalone window (accessory activation).
@MainActor
final class BaChanAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    /// The single shared brain + face — used by BOTH the tray icon and the popover.
    let conductor = Conductor()

    private var statusItem: NSStatusItem?
    private var trayHost: PassthroughHostingView?   // the live tray face, to pause it
    private let popover = NSPopover()
    private let pointer = PointerTracker()
    private var popoverIntroPlayed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no standalone window

        // Proactive moments go out as a notification when the face is hidden —
        // tell the Conductor whether the popover is currently on screen.
        conductor.isFaceVisible = { [weak self] in self?.popover.isShown ?? false }

        // Popover = the full ContentView, sharing the same Conductor as the tray face.
        popover.delegate = self      // so a transient (click-outside) close unfreezes the tray face
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 640)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(conductor: conductor)
                .frame(width: 380, height: 640))

        // Tray icon = the live face, with a transparent background and a theme-adaptive
        // feature color (.primary → black in Light mode, white in Dark) so just the
        // face shows in the menu bar. Animates via AvatarView's TimelineView + the
        // shared FaceController.
        let item = NSStatusBar.system.statusItem(withLength: 30)
        if let button = item.button {
            let host = PassthroughHostingView(rootView: trayFace(paused: false))
            trayHost = host
            host.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(host)
            NSLayoutConstraint.activate([
                host.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                host.widthAnchor.constraint(equalToConstant: 26),
                host.heightAnchor.constraint(equalToConstant: 19),
            ])
            button.action = #selector(trayClicked)
            button.target = self
            // Accessory apps have no Dock icon or main menu, so without this
            // there is no way to quit: right-click gets a small menu.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        // Eyes follow the mouse: the tracker needs to know where the face is on
        // screen — the popover when it's open, else the tray icon itself.
        pointer.anchor = { [weak self] in
            guard let self else { return nil }
            if self.popover.isShown,
               let frame = self.popover.contentViewController?.view.window?.frame {
                return CGPoint(x: frame.midX, y: frame.midY)
            }
            if let frame = self.statusItem?.button?.window?.frame {
                return CGPoint(x: frame.midX, y: frame.midY)
            }
            return nil
        }
        pointer.onMove = { [weak self] gaze in self?.conductor.face.followPointer(gaze) }
        pointer.onRest = { [weak self] in self?.conductor.face.stopFollowingPointer() }
        pointer.start()
    }

    /// The live tray face. `maxFPS` is low (it's a 26×19 pt icon) and it freezes
    /// while the popover is open, so the menu-bar face costs almost nothing.
    private func trayFace(paused: Bool) -> AvatarView {
        AvatarView(face: conductor.face, feature: .primary, background: .clear,
                   scale: 1.6, maxFPS: 20, paused: paused)
    }

    /// Pause/resume the tray face's redraw (called when the popover opens/closes).
    private func setTrayFacePaused(_ paused: Bool) {
        trayHost?.rootView = trayFace(paused: paused)
    }

    /// A transient popover can close on a click outside it (not via `togglePopover`),
    /// so resume the tray face here to cover that path too.
    func popoverDidClose(_ notification: Notification) {
        setTrayFacePaused(false)
    }

    /// Left-click toggles the popover; right-click shows the tray menu (Quit).
    @objc private func trayClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showTrayMenu()
        } else {
            togglePopover()
        }
    }

    /// Attach a menu just long enough to pop it open, then detach it so the
    /// next left-click goes back to the popover action (the standard
    /// status-item dance — a permanently assigned menu would eat every click).
    private func showTrayMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        // The privacy wipe lives here since the memory page was removed — the
        // store still works invisibly underneath, so erasing it needs a surface.
        let forget = NSMenuItem(title: "Forget Everything…",
                                action: #selector(confirmForgetEverything),
                                keyEquivalent: "")
        forget.target = self
        menu.addItem(forget)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Ba-Chan",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// Open the popover (if needed) with the Settings page showing — Ba-Chan's
    /// story, hand-added memories, the brain picker, and cloud API keys.
    @objc private func openSettings() {
        conductor.settingsRequested = true
        if !popover.isShown { togglePopover() }
    }

    /// Confirm, then erase memories, Ba-Chan's story, and the conversation
    /// journal. Also re-arms the first-launch onboarding, so a fresh start
    /// begins with telling the story again.
    @objc private func confirmForgetEverything() {
        let alert = NSAlert()
        alert.messageText = "Forget everything Ba-Chan remembers?"
        alert.informativeText = "Memories, Ba-Chan's story, and the conversation journal are erased from this Mac. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Forget Everything")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            conductor.forgetEverything()
            UserDefaults.standard.removeObject(forKey: ContentView.onboardingShownKey)
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            setTrayFacePaused(false)   // back to the tray face — let it breathe again
        } else {
            // Accessory apps aren't active by default; activate so the popover comes
            // forward and its text field can take keyboard focus.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            setTrayFacePaused(true)    // popover's big face is up — freeze the tray icon
            // The launch trace played on the tiny tray face; give the big face the
            // same drawn-on entrance the first time it's actually seen.
            if !popoverIntroPlayed {
                popoverIntroPlayed = true
                conductor.face.replayIntro()
            }
        }
    }
}
#endif

@main
struct BaChanApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(BaChanAppDelegate.self) private var appDelegate
    #else
    @StateObject private var conductor = Conductor()
    #endif

    var body: some Scene {
        #if os(macOS)
        // The whole tray UI lives in the app delegate; this hidden scene only
        // satisfies the `some Scene` requirement for an accessory menu-bar app.
        Settings { EmptyView() }
        #else
        WindowGroup {
            ContentView(conductor: conductor)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
        #endif
    }
}
