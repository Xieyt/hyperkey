import AppKit
import ApplicationServices
import Foundation

/// Strong reference to the app delegate.
///
/// `NSApplication.delegate` is a WEAK reference. Holding the delegate only in a
/// local inside `main()` lets ARC deallocate it immediately after the
/// assignment in optimized (`-c release`) builds, since the local is never read
/// again — `app.run()` then runs with a nil delegate and
/// `applicationDidFinishLaunching` is never called, so the menu bar item is
/// never created. The app still works (the event tap and hidutil remap are set
/// up before this point), it just silently has no icon and no menu. The bug is
/// timing-dependent, which is why the icon sometimes appeared on a second
/// launch. A static keeps it alive for the process lifetime.
nonisolated(unsafe) private var appDelegate: AppDelegate?

@main
struct HyperKeyApp {
    static func main() {
        // Handle --uninstall flag
        if CommandLine.arguments.contains("--uninstall") {
            HIDMapping.clearMapping()
            fputs("hyperkey: CapsLock mapping cleared.\n", stderr)
            return
        }

        // Handle --version flag
        if CommandLine.arguments.contains("--version") {
            print("hyperkey \(Constants.displayVersion)")
            return
        }

        // 1. Check for already-running instance
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: Constants.bundleID)
        if runningApps.count > 1 {
            fputs("hyperkey: already running.\n", stderr)
            return
        }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName == "hyperkey" && $0.processIdentifier != selfPID
        }
        if !others.isEmpty {
            fputs("hyperkey: already running.\n", stderr)
            return
        }

        // 2. Check accessibility permissions (waits until granted)
        Accessibility.ensureAccessibility()

        // 3. Apply CapsLock -> F18 mapping via hidutil
        let hidMappingOK = HIDMapping.applyCapsLockToF18()

        // 4. Monitor for keyboard connect/disconnect and seize external keyboards
        KeyboardMonitor.start()

        // 5. Set up signal handlers for clean shutdown
        signal(SIGINT) { _ in
            HIDMapping.clearMapping()
            fputs("\nhyperkey: stopped, CapsLock mapping cleared.\n", stderr)
            exit(0)
        }
        signal(SIGTERM) { _ in
            HIDMapping.clearMapping()
            fputs("hyperkey: stopped, CapsLock mapping cleared.\n", stderr)
            exit(0)
        }

        // 6. Start the event tap (runs on the main run loop)
        EventTap.start()

        // 7. Set up NSApplication with menu bar item
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate(hidMappingOK: hidMappingOK)
        appDelegate = delegate
        app.delegate = delegate

        // Build the menu bar item explicitly rather than waiting for AppKit to
        // deliver applicationDidFinishLaunching. On this setup that
        // notification is never delivered — verified by a filesystem marker
        // written as the first statement of the callback, which never appeared
        // across repeated launches while the process sat healthily in
        // NSApplication.run()'s event loop. The app still worked (event tap and
        // hidutil remap are established earlier in main()), it just never got
        // an icon or menu. Calling it directly makes the status item
        // independent of that notification; AppKit invoking it later is
        // harmless, the delegate would just rebuild the same item.
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var updateMenuItem: NSMenuItem!
    private var checkForUpdatesItem: NSMenuItem!
    private var warningMenuItem: NSMenuItem!
    private var keyboardsMenuItem: NSMenuItem!
    private var updateURL: String?
    private let hidMappingOK: Bool

    private let escapeKey = "escapeOnTap"

    init(hidMappingOK: Bool) {
        self.hidMappingOK = hidMappingOK
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedEscape = UserDefaults.standard.bool(forKey: escapeKey)
        escapeOnTap = savedEscape

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // Without an autosaveName, macOS assigns a slot from the shared generic
        // "Item-N" pool in com.apple.controlcenter's prefs. Those carry a
        // persisted per-slot visibility flag, and a stale
        // `NSStatusItem Visible Item-N = 0` (left behind by ⌘-dragging some
        // other app's icon off the menu bar) makes our item silently invisible:
        // created, functional, but never drawn. Symptom is a menu bar icon that
        // only appears on the second launch, because that launch lands on a
        // different slot. A stable name gets its own
        // `NSStatusItem Visible hyperkey` key that nothing else can poison.
        statusItem.autosaveName = "hyperkey"
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "capslock.fill",
                accessibilityDescription: "Hyperkey"
            )
        }

        let menu = NSMenu()
        menu.delegate = self

        // Version
        let statusMenuItem = NSMenuItem(title: "Hyperkey v\(Constants.displayVersion)", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        // Update available (hidden until detected)
        updateMenuItem = NSMenuItem(title: "Update available", action: #selector(openUpdate(_:)), keyEquivalent: "")
        updateMenuItem.target = self
        updateMenuItem.isHidden = true
        menu.addItem(updateMenuItem)

        // Check for Updates
        checkForUpdatesItem = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdatesItem.target = self
        menu.addItem(checkForUpdatesItem)

        // Warning (hidden unless something is wrong)
        warningMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        warningMenuItem.isHidden = true
        menu.addItem(warningMenuItem)

        if !hidMappingOK {
            warningMenuItem.title = "Warning: HID mapping failed"
            warningMenuItem.isHidden = false
        }

        menu.addItem(NSMenuItem.separator())

        // Keyboards submenu
        keyboardsMenuItem = NSMenuItem(title: "Keyboards", action: nil, keyEquivalent: "")
        let keyboardsSubmenu = NSMenu()
        keyboardsMenuItem.submenu = keyboardsSubmenu
        menu.addItem(keyboardsMenuItem)

        menu.addItem(NSMenuItem.separator())

        // CapsLock -> Escape toggle
        let escapeItem = NSMenuItem(
            title: "CapsLock alone \u{2192} Escape",
            action: #selector(toggleEscape(_:)),
            keyEquivalent: ""
        )
        escapeItem.target = self
        escapeItem.state = savedEscape ? .on : .off
        menu.addItem(escapeItem)

        // Launch at Login toggle
        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = isLaunchAgentInstalled() ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit Hyperkey",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // Populate now, and again whenever a keyboard connects/disconnects.
        // Relying on menuWillOpen alone left this permanently empty, because
        // AppKit does not deliver that callback to this app.
        refreshMenuState()
        KeyboardMonitor.onDevicesChanged = { [weak self] in
            DispatchQueue.main.async { self?.refreshMenuState() }
        }

        // Check for updates (uses 24h cache)
        Task { await performUpdateCheck() }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        Log.debug("menuWillOpen delivered")
        refreshMenuState()
    }

    /// Rebuild the dynamic parts of the menu.
    ///
    /// Called eagerly at setup and from the HID device callbacks, NOT only from
    /// `menuWillOpen`: AppKit does not reliably deliver delegate callbacks to
    /// this app (`applicationDidFinishLaunching` never arrives either — see
    /// `main()`), so a submenu populated only on menu-open stays permanently
    /// empty. Building it up front means the content is correct whether or not
    /// the delegate callback ever fires.
    func refreshMenuState() {
        if !AXIsProcessTrusted() {
            warningMenuItem.title = "Warning: Accessibility permission revoked"
            warningMenuItem.isHidden = false
        } else if hidMappingOK {
            warningMenuItem.isHidden = true
        }

        guard let submenu = keyboardsMenuItem.submenu else { return }
        submenu.removeAllItems()
        let devices = KeyboardMonitor.connectedDevices
        Log.debug("refreshMenuState: connectedDevices=\(devices.count) openFailure="
            + (KeyboardMonitor.openFailure.map { String(format: "0x%08X", $0) } ?? "none"))

        if devices.isEmpty {
            // An empty list is almost never "you have no keyboard" — it means
            // IOHIDManagerOpen was refused for lack of Input Monitoring, a
            // separate grant from Accessibility that macOS does not prompt an
            // LSUIElement agent for. Say which, rather than showing a bare
            // "no keyboards" that looks like a bug.
            let title: String
            if let failure = KeyboardMonitor.openFailure {
                title = "Needs Input Monitoring permission (\(String(format: "0x%08X", failure)))"
            } else {
                title = "No keyboards detected"
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)

            if KeyboardMonitor.openFailure != nil {
                let fix = NSMenuItem(
                    title: "Open Input Monitoring settings…",
                    action: #selector(openInputMonitoringSettings(_:)),
                    keyEquivalent: ""
                )
                fix.target = self
                submenu.addItem(fix)
            }
        } else {
            for device in devices {
                let item = NSMenuItem(
                    title: "\(device.name) (\(device.status))",
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                submenu.addItem(item)
            }
        }
    }

    // MARK: - Actions

    @objc private func openInputMonitoringSettings(_ sender: NSMenuItem) {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleEscape(_ sender: NSMenuItem) {
        let newValue = sender.state != .on
        escapeOnTap = newValue
        sender.state = newValue ? .on : .off
        UserDefaults.standard.set(newValue, forKey: escapeKey)
    }

    @objc private func openUpdate(_ sender: NSMenuItem) {
        if let urlString = updateURL, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        sender.title = "Checking..."
        sender.isEnabled = false
        Task {
            await performUpdateCheck(force: true)
            sender.title = "Check for Updates"
            sender.isEnabled = true
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let plistName = "\(Constants.bundleID).plist"
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let plistPath = launchAgentsDir.appendingPathComponent(plistName)
        let uid = getuid()

        if sender.state == .on {
            // Unload
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootout", "gui/\(uid)/\(plistName)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()

            try? FileManager.default.removeItem(at: plistPath)
            sender.state = .off
        } else {
            // Install and load
            try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

            let execPath = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
              "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(Constants.bundleID)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(execPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <dict>
                    <key>SuccessfulExit</key>
                    <false/>
                    <key>Crashed</key>
                    <true/>
                </dict>
                <key>ProcessType</key>
                <string>Interactive</string>
                <key>StandardOutPath</key>
                <string>/tmp/hyperkey.out.log</string>
                <key>StandardErrorPath</key>
                <string>/tmp/hyperkey.err.log</string>
                <key>LimitLoadToSessionType</key>
                <string>Aqua</string>
            </dict>
            </plist>
            """

            do {
                try plistContent.write(to: plistPath, atomically: true, encoding: .utf8)
            } catch {
                fputs("hyperkey: failed to write LaunchAgent plist: \(error)\n", stderr)
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootstrap", "gui/\(uid)", plistPath.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    sender.state = .on
                } else {
                    fputs("hyperkey: launchctl bootstrap failed (status \(process.terminationStatus))\n", stderr)
                }
            } catch {
                fputs("hyperkey: failed to run launchctl: \(error)\n", stderr)
            }
        }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        HIDMapping.clearMapping()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Helpers

    private func performUpdateCheck(force: Bool = false) async {
        if let (version, url) = await UpdateChecker.check(force: force) {
            updateMenuItem.title = "Update available: v\(version)"
            updateMenuItem.isHidden = false
            updateURL = url
        } else if force {
            updateMenuItem.title = "Up to date"
            updateMenuItem.isHidden = false
            updateURL = nil
            // Hide "up to date" after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if self?.updateURL == nil {
                    self?.updateMenuItem.isHidden = true
                }
            }
        }
    }

    private func isLaunchAgentInstalled() -> Bool {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Constants.bundleID).plist")
        return FileManager.default.fileExists(atPath: plistPath.path)
    }
}
