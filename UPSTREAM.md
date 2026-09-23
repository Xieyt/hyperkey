# Upstream sync record

Companion to `FORK.md`. `FORK.md` says *what we carry and why*; this says *where
we branched from* and *how to pull upstream updates* when `feedthejim/hyperkey`
moves.

## 0. Status

```
branch                    xieyt/1
forked from               upstream/main @ 532f2b3
                           ("Update AGENTS.md with comprehensive architecture
                            and debugging guide", 2026-02-25)
behind upstream            0   (at fork time)
ahead                      1   (§2.A in FORK.md)
```

`main` is a clean mirror of `upstream/main` — it was identical to upstream at
fork time (`0 ahead / 0 behind`, verified via the GitHub compare API) and should
stay that way. All local work lives on `xieyt/1`.

## 1. Sync procedure

This fork is small (one feature, two files touched) — a full staged-merge process
like `rift`'s isn't warranted yet. Straightforward rebase workflow:

```bash
git fetch upstream
git log --oneline main..upstream/main        # see what's new
git checkout main
git merge --ff-only upstream/main            # main always fast-forwards
git checkout xieyt/1
git rebase main                              # replay our one commit on top
```

If the rebase conflicts, it will be in `Sources/hyperkey/Constants.swift` and/or
`Sources/hyperkey/EventTap.swift` — see `FORK.md` §2.A for exactly what our
commit changes and why, so you can tell which side of a conflict is upstream's
new behavior vs. our Left-Command-trigger addition.

After resolving:

```bash
swift build -c release      # must succeed
# manual smoke test (no automated test suite in this repo):
#   - CapsLock alone -> Escape
#   - CapsLock held + letter -> Hyper+letter
#   - Left Command held + letter -> Hyper+letter
#   - Left Command alone -> nothing (no Escape)
#   - Right Command + letter -> normal shortcut, unaffected
git push origin main xieyt/1
```

## 2. When upstream bumps its own version

`Constants.swift`'s `version` string is a manually-maintained literal (upstream
doesn't derive it from `git describe` or the tag). When syncing past a new
upstream tag, check whether `version` was bumped in the commits you pulled; if
not, it's a known upstream gap (see `FORK.md` §2.A note on `version = "0.2.0"`
being stale even at the `v0.5.0` tag) — not something to fix here unless you're
also upstreaming it.

## 3. What to re-verify after any sync

- `EventTap.swift`'s `eventTapCallback`: upstream could restructure the
  F18/CapsLock branches (it's the file our commit touches most). Confirm the
  Left Command `flagsChanged` branch (keycode `55`) still sits alongside the
  CapsLock one, and that `deactivateHyper`'s `allowEscape` parameter still gates
  correctly — CapsLock/F18 call sites `true`, Left Command call site `false`.
- `KeyboardMonitor.swift`: if upstream changes the external-keyboard HID path,
  re-check whether Left Command should also be extended there (currently it
  is *not* — see `FORK.md` §2.A "Known limitation").
