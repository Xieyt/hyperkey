# Fork maintenance guide

This is a **fork** of [`feedthejim/hyperkey`](https://github.com/feedthejim/hyperkey)
that carries one local feature on top of upstream. This document explains what we
add, why, and how to keep pulling upstream updates without losing it.

Read this before syncing with upstream or adding new local changes.

> **Syncing with upstream?** See `UPSTREAM.md` for the sync procedure and the
> record of where we branched from.

---

## 1. Repository topology

| Remote | URL | Role |
|---|---|---|
| `origin` | `https://github.com/Xieyt/hyperkey.git` | our fork (push here) |
| `upstream` | `https://github.com/feedthejim/hyperkey.git` | source of truth (never push here) |

Branches:

- **`xieyt/1`** — the working branch: `upstream/main` plus our local commit on top.
  This is what we build and ship.
- **`main`** — kept as a clean mirror of `upstream/main`. No local work lands here.

> **Rule:** local work never touches upstream. We only ever push to `origin`.

---

## 2. What this fork adds

### A. `feat: Left Command as a second Hyper trigger`
**Files:** `Sources/hyperkey/Constants.swift`, `Sources/hyperkey/EventTap.swift`.

- Upstream's only Hyper trigger is CapsLock (remapped to F18 via `hidutil`, then
  detected by `EventTap`'s `CGEventTap` callback). This fork adds a **second,
  independent trigger: the Left Command key** (virtual keycode `55`), detected via
  `flagsChanged` the same way the CapsLock fallback path already was.
- Both triggers set the same shared `hyperActive` global and are otherwise
  interchangeable — any key pressed while either is held gets the full
  `hyperFlags` mask applied (see §B for what that mask actually is in this fork).
- **Escape-on-tap stays CapsLock-only.** Upstream's `deactivateHyper()` had one
  unconditional behavior: if `escapeOnTap` is enabled and the trigger key was
  released without ever being used as a modifier, synthesize Escape. That is
  correct for a tap-alone CapsLock, but wrong for Left Command — a bare `⌘`
  tap should do nothing, not send Escape. `deactivateHyper` now takes an
  `allowEscape: Bool` parameter; only the CapsLock/F18 call sites pass `true`.
- **Effect on normal Command-key behavior:** since Left Command is now a Hyper
  trigger, it stops producing ordinary `⌘`-modified shortcuts — `⌘C` held with
  the *left* key becomes `Hyper+C`, not copy. Use the **right** Command key for
  normal shortcuts. This is intentional, not a bug.
- **Known limitation:** the Left Command trigger only applies to the CGEventTap
  path (built-in keyboard / macOS <26). `KeyboardMonitor.swift`'s external-keyboard
  HID-seizure path (macOS 26+ external keyboards) still only recognizes
  CapsLock/F18 as a trigger — Left Command behaves normally on a seized external
  keyboard. Extending it there means adding the same trigger check to
  `handleHyperToggle`/`hidInputCallback` in `KeyboardMonitor.swift`.

**Why:** wanted CapsLock reserved purely for Escape-on-tap (vim-style), with Hyper
bound to a key that's still easy to reach and hold — Left Command.
**Conflict risk:** LOW — both touched files are small and upstream changes them
rarely; the diff is additive (new branches in `eventTapCallback`, one new
parameter on a private function), nothing upstream owns is restructured.

### B. `fix: drop Shift from hyperFlags`
**Files:** `Sources/hyperkey/Constants.swift`.

- Upstream's `hyperFlags` is `Cmd+Ctrl+Opt+Shift` — all four. We ship
  `Cmd+Ctrl+Opt` only.
- **Why this matters more than it looks:** our Rift keybindings pervasively use
  `hyper + X` for one action and `hyper + Shift + X` for a related one — e.g.
  `hyper + H` = move focus left, `hyper + Shift + H` = move the window left.
  If the Hyper trigger *itself* already injects Shift, then physically pressing
  Shift on top of it is a no-op: `hyper + Shift + H` and `hyper + H` resolve to
  the exact same modifier set on the wire, Rift's hotkey map treats them as the
  same hotkey, and **both** bound commands fire on every press (confirmed via
  Rift's own event log: every `MoveFocus` was immediately followed by an
  unrequested `MoveNode`). Shift has to stay free as a discriminator, which
  means the trigger's own flags can't already include it.
- If you don't use `hyper + Shift + X` bindings, upstream's 4-modifier default
  is fine. We do, extensively, so we don't ship it.

**Why:** required for the fork's own Rift keybindings to work at all; not a
preference.
**Conflict risk:** LOW — one `enum` constant, upstream touches it rarely.

## 3. Local configuration notes (not in git, but part of "how we run this")

- **Code signing:** built and signed with `fern-codesign`, this machine's stable
  self-signed identity (auto-created and trusted by rift's nix-darwin module on
  activation; `services.rift.signingIdentity` in xnix-config's `fern.nix`, also
  creatable standalone via rift's `just setup-signing-cert`). It is the host's
  identity, not Rift's — it signs every locally-built app needing durable TCC
  grants. Ad-hoc (`-s -`) signatures produced unreliable Accessibility
  grants on this machine — the TCC database showed the grant as present, but
  `AXIsProcessTrustedWithOptions` still failed at runtime for some launches. A
  stable signing identity fixed it. If you rebuild with a different identity (or
  ad-hoc), expect to `tccutil reset Accessibility com.feedthejim.hyperkey` and
  re-grant.
- **`escapeOnTap` default:** set to `true` via
  `defaults write com.feedthejim.hyperkey escapeOnTap -bool true` rather than a
  code change, since it's already a runtime `UserDefaults`-backed toggle exposed
  in the menu bar's "CapsLock alone → Escape" item.
- **Launch path matters.** Launching via `open` from a terminal or from a
  sandboxed/automated tool session was observed to leave the app running but
  stuck before ever creating its `NSStatusItem` (no crash, no error — just no
  menu bar icon, confirmed via a full window-server enumeration and an attached
  debugger showing a healthy idle run loop). A genuine Finder double-click launch
  works correctly. If the icon doesn't appear after a launch, try relaunching via
  Finder before assuming something is broken.
