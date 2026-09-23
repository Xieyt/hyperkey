import CoreGraphics
import Foundation

/// CGEventTap state. The port is private to this file; hyperActive/hyperUsedAsModifier
/// are shared globals in Constants.swift (also used by KeyboardMonitor).
nonisolated(unsafe) private var eventTapPort: CFMachPort?
nonisolated(unsafe) var escapeOnTap = false

enum EventTap {
    /// Create and start the CGEventTap. Call on the main thread.
    /// The tap runs via the main CFRunLoop (driven by NSApplication).
    static func start() {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Constants.eventMask,
            callback: eventTapCallback,
            userInfo: nil
        ) else {
            fputs("hyperkey: failed to create event tap. Check accessibility permissions.\n", stderr)
            exit(1)
        }

        eventTapPort = tap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        fputs("hyperkey: running (CapsLock -> Hyper)\n", stderr)
    }
}

/// The event tap callback.
///
/// Event flow:
///   1. hidutil remaps CapsLock (HID 0x39) to F18 (HID 0x6D) at driver level
///   2. macOS translates F18 to virtual keycode 79 (kVK_F18)
///   3. Our CGEventTap intercepts keyDown/keyUp for keycode 79
///   4. On F18 keyDown: set hyperActive, suppress the event
///   5. On any other keyDown/keyUp while hyperActive: add hyper modifier flags
///   6. On F18 keyUp: clear hyperActive, suppress the event; if it was a tap
///      (never used as a modifier), optionally synthesize Escape
///   7. Left Command (keycode 55) is a second, independent Hyper trigger via
///      flagsChanged. It never synthesizes Escape on tap-alone - only
///      CapsLock/F18 does. Left Command therefore no longer produces normal
///      Cmd-key behavior; use Right Command for ordinary shortcuts.
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // Re-enable tap if system disabled it (happens under heavy load)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = eventTapPort {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    // Skip events injected by the HID seizure path (avoid feedback loops)
    if event.getIntegerValueField(Constants.injectedEventField) == Constants.injectedEventMarker {
        return Unmanaged.passUnretained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

    // F18 keyDown: activate hyper mode (from hidutil-remapped keyboards)
    if type == .keyDown && keyCode == Constants.f18KeyCode {
        if !hyperActive {
            hyperActive = true
            hyperUsedAsModifier = false
        }
        return nil
    }

    // F18 keyUp: deactivate hyper mode (from hidutil-remapped keyboards).
    // This is the CapsLock path, so tap-alone may synthesize Escape.
    if type == .keyUp && keyCode == Constants.f18KeyCode {
        return deactivateHyper(allowEscape: true)
    }

    // CapsLock flagsChanged: fallback for keyboards where hidutil doesn't remap.
    // When CapsLock is pressed, macOS sends flagsChanged with keycode 57.
    // alphaShift flag present = key down, absent = key up.
    if type == .flagsChanged && keyCode == Constants.capsLockKeyCode {
        let isDown = event.flags.contains(Constants.capsLockFlag)
        if isDown {
            if !hyperActive {
                hyperActive = true
                hyperUsedAsModifier = false
            }
        } else {
            return deactivateHyper(allowEscape: true)
        }
        return nil
    }

    // Left Command flagsChanged: independent Hyper trigger. Never synthesizes
    // Escape on tap-alone - only the CapsLock/F18 path above does that.
    // Left Command therefore stops behaving as a normal modifier; use Right
    // Command for ordinary Cmd-key shortcuts.
    if type == .flagsChanged && keyCode == Constants.leftCommandKeyCode {
        let isDown = event.flags.contains(.maskCommand)
        if isDown {
            if !hyperActive {
                hyperActive = true
                hyperUsedAsModifier = false
            }
            return nil
        } else {
            return deactivateHyper(allowEscape: false)
        }
    }

    // Any other key while hyper is active: add modifier flags
    if hyperActive && (type == .keyDown || type == .keyUp) {
        hyperUsedAsModifier = true
        event.flags = CGEventFlags(rawValue: event.flags.rawValue | Constants.hyperFlags.rawValue)
        return Unmanaged.passUnretained(event)
    }

    // flagsChanged events while hyper is active (e.g. holding Shift with Hyper)
    if hyperActive && type == .flagsChanged {
        hyperUsedAsModifier = true
        event.flags = CGEventFlags(rawValue: event.flags.rawValue | Constants.hyperFlags.rawValue)
        return Unmanaged.passUnretained(event)
    }

    // Everything else: pass through unmodified
    return Unmanaged.passUnretained(event)
}

/// Shared logic for deactivating hyper mode (used by CapsLock/F18 and Left
/// Command trigger paths). `allowEscape` gates the tap-alone Escape synth -
/// only the CapsLock/F18 path passes true.
private func deactivateHyper(allowEscape: Bool) -> Unmanaged<CGEvent>? {
    let wasUsed = hyperUsedAsModifier
    hyperActive = false
    hyperUsedAsModifier = false

    if !wasUsed && escapeOnTap && allowEscape {
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: Constants.escKeyCode, keyDown: true),
           let up = CGEvent(keyboardEventSource: src, virtualKey: Constants.escKeyCode, keyDown: false) {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    return nil
}
