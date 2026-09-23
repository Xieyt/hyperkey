app := "/Applications/Hyperkey.app"
# This machine's stable local code-signing identity. Shared with rift (see
# services.rift.signingIdentity in xnix-config's fern.nix). Signing with a
# STABLE identity is what lets the Accessibility / Input Monitoring grants
# survive a rebuild — ad-hoc (`-s -`) signatures change identity every build,
# so macOS treats each build as a new app and re-prompts.
signing_cert := "fern-codesign"
sys_keychain := "/Library/Keychains/System.keychain"

# `swift build` must not see nix's SDK/toolchain env: the devShell exports
# DEVELOPER_DIR/SDKROOT pointing at nixpkgs' apple-sdk_14, which the system
# Swift 6.x compiler rejects ("SDK is built with Apple Swift 5.10 ... select a
# toolchain which matches the SDK"). Stripping them falls back to the system
# CommandLineTools SDK, which matches.
swift := "env -u SDKROOT -u DEVELOPER_DIR -u LIBRARY_PATH /usr/bin/swift"

# list recipes
default:
    @just --list

# build the release binary
build:
    {{swift}} build -c release

# build, swap the binary into the installed bundle, re-sign, relaunch
dev-install: build
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "{{app}}" ]; then
      echo "!! {{app}} not present — run \`just install\` first"; exit 1
    fi
    pkill -x hyperkey 2>/dev/null || true
    sleep 1
    cp .build/release/hyperkey "{{app}}/Contents/MacOS/hyperkey"
    just _sign
    open "{{app}}"
    sleep 2
    just status

# full install: build the .app bundle from scratch, sign, install, launch
install: build
    #!/usr/bin/env bash
    set -euo pipefail
    stage=$(mktemp -d)/Hyperkey.app
    mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
    cp .build/release/hyperkey "$stage/Contents/MacOS/"
    cp Info.plist "$stage/Contents/"
    cp AppIcon.icns "$stage/Contents/Resources/"
    pkill -x hyperkey 2>/dev/null || true
    sleep 1
    rm -rf "{{app}}"
    cp -R "$stage" "{{app}}"
    rm -rf "$(dirname "$stage")"
    just _sign
    open "{{app}}"
    sleep 2
    just status

# sign the installed bundle with the stable identity (ad-hoc fallback warns)
_sign:
    #!/usr/bin/env bash
    set -euo pipefail
    if security find-certificate -c "{{signing_cert}}" "{{sys_keychain}}" >/dev/null 2>&1; then
      codesign -f -s "{{signing_cert}}" --identifier com.feedthejim.hyperkey "{{app}}"
    else
      echo "!! '{{signing_cert}}' not in System keychain; signing ad-hoc."
      echo "   Accessibility/Input Monitoring will be re-prompted on every build."
      echo "   Fix: run \`just setup-signing-cert\` in ~/xde/forks/rift, or"
      echo "   \`darwin-rebuild switch\` (services.rift.manageSigningIdentity creates it)."
      codesign -f -s - --identifier com.feedthejim.hyperkey "{{app}}"
    fi

# restart the app (must start AFTER rift - see restart-all)
restart:
    pkill -x hyperkey 2>/dev/null || true
    sleep 1
    open "{{app}}"

# restart rift first, then hyperkey — the only correct order (see `restart`)
restart-all:
    launchctl kickstart -k "gui/$(id -u)/git.acsandmann.rift"
    sleep 2
    just restart

# stop the app
stop:
    pkill -x hyperkey 2>/dev/null || true

# what's running, what's signed, what's granted, is the remap live
status:
    #!/usr/bin/env bash
    pid=$(pgrep -x hyperkey || true)
    echo "process:   ${pid:-not running}"
    echo -n "signature: "
    codesign -dvvv "{{app}}" 2>&1 | grep -E "^Authority=" || echo "ad-hoc/unsigned"
    echo -n "capslock remap: "
    if hidutil property --get UserKeyMapping 2>/dev/null | grep -q 30064771181; then
      echo "active (CapsLock -> F18)"
    else
      echo "NOT active"
    fi
    echo "TCC grants:"
    sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
      "select '  '||service||' = '||auth_value from access where client='com.feedthejim.hyperkey';" \
      2>/dev/null || echo "  (cannot read TCC.db)"
    echo "  note: kTCCServiceListenEvent (Input Monitoring) is required for the"
    echo "        Keyboards menu and external-keyboard support on macOS 26+."

# reset Accessibility/Input Monitoring (only needed when changing signing identity)
reset-permissions:
    tccutil reset Accessibility com.feedthejim.hyperkey
    tccutil reset ListenEvent com.feedthejim.hyperkey || true
    @echo "Relaunch the app and approve the prompts."

# open the panes where the two required permissions are granted
open-permissions:
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    sleep 1
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"

# remove the CapsLock->F18 hidutil mapping and stop the app
uninstall:
    "{{app}}/Contents/MacOS/hyperkey" --uninstall || true
    just stop
    rm -rf "{{app}}"

# sync with upstream (see UPSTREAM.md)
sync:
    git fetch upstream
    git log --oneline main..upstream/main

# --- debug logging (off by default; writes /tmp/hyperkey.log) ---

# turn debug logging on (writes /tmp/hyperkey.log)
debug-on:
    defaults write com.feedthejim.hyperkey debugLogging -bool true
    @echo "debug logging ON — restart the app (\`just restart\`), then \`just log\`"

# turn debug logging off
debug-off:
    defaults write com.feedthejim.hyperkey debugLogging -bool false
    @echo "debug logging OFF — restart the app to apply"

# tail the debug log (enable it first with debug-on)
log:
    @touch /tmp/hyperkey.log
    tail -f /tmp/hyperkey.log

# dump the debug log and the current debug flag
log-dump:
    @echo "debugLogging = $(defaults read com.feedthejim.hyperkey debugLogging 2>/dev/null || echo 0)"
    @cat /tmp/hyperkey.log 2>/dev/null || echo "(no log yet)"

# restore stock CapsLock after a crash left the hidutil remap stranded
fix-capslock:
    hidutil property --set '{"UserKeyMapping":[]}' >/dev/null
    @echo "CapsLock restored to default. Run \`just restart\` to re-enable Hyper."
