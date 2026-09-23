import AppKit
import ApplicationServices
import Foundation

enum Accessibility {
    /// How long to wait for the grant before telling the user something is
    /// wrong. Upstream waited forever with no output after the initial line,
    /// which for an LSUIElement agent means an invisible process that appears
    /// to have launched fine and simply does nothing — the single most
    /// confusing failure this app has.
    private static let nagInterval: TimeInterval = 20

    /// Check accessibility permissions.
    ///
    /// If not granted, prompt and poll using the run loop (keeps the app
    /// responsive), surfacing a visible alert if the grant does not arrive,
    /// since a menu bar agent has no other way to tell the user it is stuck.
    static func ensureAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary

        if AXIsProcessTrustedWithOptions(options) {
            Log.debug("Accessibility: already trusted")
            return
        }

        Log.info("Accessibility: waiting for permission…")
        fputs("hyperkey: waiting for Accessibility permission...\n", stderr)

        let start = Date()
        var nagged = false

        // Poll using CFRunLoop instead of Thread.sleep so the app stays
        // responsive and macOS doesn't show "not responding" dialogs.
        while !AXIsProcessTrusted() {
            CFRunLoopRunInMode(.defaultMode, 1.0, false)

            if !nagged, Date().timeIntervalSince(start) > nagInterval {
                nagged = true
                Log.info("Accessibility: still not granted after \(Int(nagInterval))s")
                showStuckAlert()
            }
        }

        Log.info("Accessibility: granted after \(Int(Date().timeIntervalSince(start)))s")
        fputs("hyperkey: Accessibility permission granted.\n", stderr)
    }

    /// Tell the user we are blocked, and offer to open the right pane.
    ///
    /// Non-blocking: the alert runs on the main run loop we are already
    /// spinning, and the poll above continues once it is dismissed.
    private static func showStuckAlert() {
        MainActor.assumeIsolated {
        let alert = NSAlert()
        alert.messageText = "Hyperkey needs Accessibility permission"
        alert.informativeText = """
            Hyperkey cannot remap keys until it is enabled under
            Privacy & Security › Accessibility.

            It will start working the moment you enable it — no relaunch needed.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Keep Waiting")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(
               string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
           )
        {
            NSWorkspace.shared.open(url)
        }
        }
    }
}
