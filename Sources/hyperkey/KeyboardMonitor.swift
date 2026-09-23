import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

/// Current modifier flags from seized external keyboards.
nonisolated(unsafe) private var currentModifierFlags: UInt64 = 0

/// Monitors and seizes external keyboard HID devices.
///
/// On macOS 26+, CGEventTap no longer receives events from external keyboards.
/// This module seizes external keyboards via IOKit HID, intercepts all input,
/// and re-injects key events as CGEvents with hyper mode logic applied.
/// Built-in keyboards are left to the CGEventTap path in EventTap.swift.
/// Connected keyboard info for menu display.
struct KeyboardInfo {
    let name: String
    let status: String // "Built-in", "Seized", "Skipped"
}

enum KeyboardMonitor {
    private nonisolated(unsafe) static var manager: IOHIDManager?
    /// Connected keyboards for menu display. Updated on connect/disconnect.
    nonisolated(unsafe) static var connectedDevices: [KeyboardInfo] = []
    /// Non-nil when IOHIDManagerOpen failed — almost always a missing Input
    /// Monitoring grant. Surfaced in the Keyboards menu.
    nonisolated(unsafe) static var openFailure: IOReturn?
    /// Invoked after `connectedDevices` changes so the menu can rebuild. The
    /// menu cannot refresh itself on open: AppKit does not deliver
    /// `menuWillOpen` to this app (same reason `applicationDidFinishLaunching`
    /// never arrives), so the submenu must be pushed, not pulled.
    nonisolated(unsafe) static var onDevicesChanged: (() -> Void)?

    static func start() {
        // Ask for Input Monitoring before opening the manager. Upstream called
        // IOHIDManagerOpen cold, which macOS denies WITHOUT prompting when the
        // grant is missing — so the user got no dialog, no error, just an empty
        // Keyboards menu and no external-keyboard support. IOHIDRequestAccess
        // is the Input Monitoring equivalent of AXIsProcessTrustedWithOptions
        // (which this app already calls for Accessibility, and which is why
        // that permission prompts and this one didn't).
        let accessBefore = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        Log.info("KeyboardMonitor.start: IOHIDCheckAccess(ListenEvent)=\(accessBefore.rawValue) (0=granted,1=denied,2=unknown)")
        if accessBefore != kIOHIDAccessTypeGranted {
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            Log.info("KeyboardMonitor.start: IOHIDRequestAccess -> \(granted)")
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceConnectedCallback, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCallback, nil)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // Upstream ignored this result. IOHIDManagerOpen fails with
        // kIOReturnNotPermitted (0xE00002E2) unless the app has Input
        // Monitoring (kTCCServiceListenEvent) — a SEPARATE grant from
        // Accessibility. When it fails no device callbacks ever fire, so
        // `connectedDevices` stays empty and the Keyboards menu silently shows
        // nothing, with no hint that a permission is missing. Record it so the
        // menu can say so.
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        openFailure = openResult == kIOReturnSuccess ? nil : openResult
        Log.info("KeyboardMonitor.start: IOHIDManagerOpen -> \(String(format: "0x%08X", openResult))"
            + (openResult == kIOReturnSuccess ? " (success)" : " (FAILED - needs Input Monitoring)"))

        // Enumerate synchronously too: the matching callback only fires once
        // the run loop is servicing the manager, and it is the sole thing
        // upstream relied on to populate the device list.
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            Log.info("KeyboardMonitor.start: IOHIDManagerCopyDevices -> \(devices.count) device(s)")
            for device in devices {
                Log.debug("  device: \(productName(device)) builtIn=\(isBuiltIn(device))")
            }
        } else {
            Log.info("KeyboardMonitor.start: IOHIDManagerCopyDevices -> nil")
        }

        self.manager = manager
    }
}

// MARK: - Device Classification

private func isBuiltIn(_ device: IOHIDDevice) -> Bool {
    if let builtIn = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) as? NSNumber,
       builtIn.boolValue
    {
        return true
    }
    if let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String,
       transport == "SPI" || transport == "BuiltIn"
    {
        return true
    }
    return false
}

private func productName(_ device: IOHIDDevice) -> String {
    IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
}

// MARK: - Device Connect/Disconnect Callbacks

private func deviceConnectedCallback(
    _ context: UnsafeMutableRawPointer?,
    _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?,
    _ device: IOHIDDevice
) {
    let name = productName(device)

    if isBuiltIn(device) {
        Log.info("deviceConnected: built-in keyboard (\(name)) - CGEventTap path")
        HIDMapping.applyCapsLockToF18()
        KeyboardMonitor.connectedDevices.append(KeyboardInfo(name: name, status: "Built-in"))
        KeyboardMonitor.onDevicesChanged?()
        return
    }

    // External keyboard: seize for exclusive access, then register input callback.
    // Only inject events from devices we successfully seize. If seizure fails
    // (e.g. duplicate HID interface for the same physical keyboard), skip it
    // to avoid double input.
    let seizeResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    if seizeResult == kIOReturnSuccess {
        IOHIDDeviceRegisterInputValueCallback(device, hidInputCallback, nil)
        Log.info("deviceConnected: seized external keyboard (\(name))")
        KeyboardMonitor.connectedDevices.append(KeyboardInfo(name: name, status: "Seized"))
        KeyboardMonitor.onDevicesChanged?()
    } else {
        Log.info("deviceConnected: skipping \(name) - could not seize (error \(seizeResult))")
    }
}

private func deviceRemovedCallback(
    _ context: UnsafeMutableRawPointer?,
    _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?,
    _ device: IOHIDDevice
) {
    let name = productName(device)
    Log.info("deviceRemoved: \(name)")
    KeyboardMonitor.connectedDevices.removeAll { $0.name == name }
    KeyboardMonitor.onDevicesChanged?()

    // Clear state to prevent stuck modifiers
    if hyperActive {
        hyperActive = false
        hyperUsedAsModifier = false
    }
    currentModifierFlags = 0
}

// MARK: - HID Input Callback

private func hidInputCallback(
    _ context: UnsafeMutableRawPointer?,
    _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?,
    _ value: IOHIDValue
) {
    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let pressed = IOHIDValueGetIntegerValue(value) != 0

    // Only handle Keyboard/Keypad page (0x07)
    guard usagePage == 0x07 else { return }
    // Skip reserved/invalid usages and rollover sentinel
    guard usage >= 0x04 && usage <= 0xE7 else { return }

    // CapsLock (usage 0x39): activate/deactivate hyper mode
    if usage == 0x39 {
        handleHyperToggle(pressed: pressed)
        return
    }

    // F18 (usage 0x6D): in case hidutil remaps CapsLock before seizure intercepts
    if usage == 0x6D {
        handleHyperToggle(pressed: pressed)
        return
    }

    // Modifier keys (0xE0-0xE7)
    if let flag = HIDKeyTable.modifierFlag(forUsage: usage) {
        if pressed {
            currentModifierFlags |= flag.rawValue
        } else {
            currentModifierFlags &= ~flag.rawValue
        }
        if let keyCode = HIDKeyTable.virtualKeyCode(forUsage: usage) {
            injectFlagsChanged(keyCode: keyCode)
        }
        return
    }

    // Regular keys: re-inject as CGEvent
    if let keyCode = HIDKeyTable.virtualKeyCode(forUsage: usage) {
        if hyperActive {
            hyperUsedAsModifier = true
            injectKey(keyCode: keyCode, keyDown: pressed, addHyperFlags: true)
        } else {
            injectKey(keyCode: keyCode, keyDown: pressed)
        }
    }
}

// MARK: - Hyper Toggle

private func handleHyperToggle(pressed: Bool) {
    if pressed {
        if !hyperActive {
            hyperActive = true
            hyperUsedAsModifier = false
        }
    } else {
        let wasUsed = hyperUsedAsModifier
        hyperActive = false
        hyperUsedAsModifier = false
        if !wasUsed && escapeOnTap {
            injectKey(keyCode: Constants.escKeyCode, keyDown: true)
            injectKey(keyCode: Constants.escKeyCode, keyDown: false)
        }
    }
}

// MARK: - CGEvent Injection

private func injectKey(keyCode: UInt16, keyDown: Bool, addHyperFlags: Bool = false) {
    let src = CGEventSource(stateID: .hidSystemState)
    guard let event = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: keyDown) else { return }

    var flags = CGEventFlags(rawValue: currentModifierFlags)
    if addHyperFlags {
        flags = CGEventFlags(rawValue: flags.rawValue | Constants.hyperFlags.rawValue)
    }
    event.flags = flags

    // Tag so EventTap's callback skips this event
    event.setIntegerValueField(Constants.injectedEventField, value: Constants.injectedEventMarker)
    event.post(tap: .cghidEventTap)
}

private func injectFlagsChanged(keyCode: UInt16) {
    let src = CGEventSource(stateID: .hidSystemState)
    guard let event = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) else { return }
    event.type = .flagsChanged

    var flags = CGEventFlags(rawValue: currentModifierFlags)
    if hyperActive {
        hyperUsedAsModifier = true
        flags = CGEventFlags(rawValue: flags.rawValue | Constants.hyperFlags.rawValue)
    }
    event.flags = flags

    event.setIntegerValueField(Constants.injectedEventField, value: Constants.injectedEventMarker)
    event.post(tap: .cghidEventTap)
}
