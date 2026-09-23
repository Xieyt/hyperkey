import CoreGraphics

/// Shared mutable state for hyper mode. Accessed from both EventTap (CGEventTap callback)
/// and KeyboardMonitor (IOKit HID callback). Both are C function pointers that cannot
/// capture context, requiring global state. Both run on the main run loop so no
/// synchronization is needed.
nonisolated(unsafe) var hyperActive = false
nonisolated(unsafe) var hyperUsedAsModifier = false

enum Constants {
    /// Virtual keycode for F18 (0x4F)
    static let f18KeyCode: Int64 = 79

    /// HID usage ID for Caps Lock
    static let hidCapsLock: UInt64 = 0x700000039

    /// HID usage ID for F18
    static let hidF18: UInt64 = 0x70000006D

    /// Combined hyper modifier flags: Cmd + Ctrl + Opt (no Shift - Shift stays
    /// free so "hyper + Shift + X" bindings remain distinguishable from
    /// "hyper + X". See FORK.md #A.)
    static let hyperFlags = CGEventFlags(rawValue:
        CGEventFlags.maskCommand.rawValue |
        CGEventFlags.maskControl.rawValue |
        CGEventFlags.maskAlternate.rawValue
    )

    /// Event mask for key events we intercept
    static let eventMask: CGEventMask = (
        (1 << CGEventType.keyDown.rawValue) |
        (1 << CGEventType.keyUp.rawValue) |
        (1 << CGEventType.flagsChanged.rawValue)
    )

    /// Virtual keycode for CapsLock (fallback for keyboards where hidutil doesn't remap)
    static let capsLockKeyCode: Int64 = 57

    /// CapsLock modifier flag
    static let capsLockFlag = CGEventFlags.maskAlphaShift

    /// Virtual keycode for Left Command (kVK_Command) - used as an independent Hyper trigger
    static let leftCommandKeyCode: Int64 = 55

    /// Virtual keycode for Escape
    static let escKeyCode: UInt16 = 0x35
    /// Upstream version this fork is based on.
    ///
    /// Upstream never bumped this literal — it still said "0.2.0" at the v0.5.0
    /// tag, which made the update check think every build was out of date.
    /// MUST stay plain dotted-numeric: `UpdateChecker.isNewer` parses it with
    /// `split(".")` + `Int()`, so a suffix like "0.5.0-xieyt.1" would silently
    /// compactMap down to [0, 5, 1] and compare wrong. Fork identity lives in
    /// `forkRevision` instead.
    static let version = "0.5.0"

    /// Fork revision, shown in the menu. Bump when shipping fork changes.
    static let forkRevision = "xieyt.1"

    /// What the menu displays: "0.5.0 (xieyt.1)".
    static var displayVersion: String { "\(version) (\(forkRevision))" }

    /// Update-check repo — OUR fork, deliberately not upstream.
    ///
    /// Pointing this at feedthejim/hyperkey made the menu advertise upstream's
    /// release as an available update (its 0.5.0 > our stale 0.2.0 literal),
    /// and following it would replace this build with a stock upstream one,
    /// silently dropping every fork change: the Left Command trigger, the
    /// Shift-free hyperFlags our Rift bindings depend on, and the menu bar
    /// fixes. Upstream releases are pulled in deliberately via UPSTREAM.md's
    /// sync procedure, never by a one-click "update".
    static let githubRepo = "Xieyt/hyperkey"

    /// CGEvent user data field for tagging events injected by the HID seizure path
    static let injectedEventField = CGEventField(rawValue: 43)!
    /// Marker value to identify our injected events (prevents feedback loops)
    static let injectedEventMarker: Int64 = 0x48594B45 // "HYKE"

    /// LaunchAgent label
    static let bundleID = "com.feedthejim.hyperkey"
}
