# Plan 039: Ship chromium in the ISO closure (seeding sets it as default browser)

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 037 (same closure mechanism)
- **Category**: bug
- **Planned at**: commit `e703ad0`, 2026-09-11
- **Executed**: 2026-09-11, in the same commit as this file.

## Why this matters

Third gap found by the same release-gate run (a fresh install onto the minimal
CachyOS golden, systemd-boot guest). After plans 037's two gaps were fixed, the
seeding step still aborted with `exit 2` and **no message**:

```
+ env -u BROWSER xdg-settings set default-web-browser chromium.desktop
Error: aborted at line 43 (exit 2) during step: User-level config seeding
```

`omarchy-provision-user` ends with
`env -u BROWSER xdg-settings set default-web-browser chromium.desktop`, and
`xdg-settings` exits **2** when the named desktop file does not exist. The
minimal golden has no browser and the wrapper's closure never installed one, so
the last line of user seeding could never run: the bookmark/desktop-database
work before it was done, `omarchy-done mark finalize-user` was not, and the
wrapper aborted with an opaque exit code. Chromium is what Omarchy's own ISO
ships and what every `omarchy-webapp-install` entry (`chromium --app=…`) and the
XDG default-browser registration assume.

Two earlier failures (plan 037) aborted the same step *before* this line, which
is why it only surfaced now.

## What changed

- `bin/install-omarchy-quattro.sh`:
  - `OMARCHY_ISO_CLOSURE` gains `chromium`.
  - `APPLY_REQUIREMENTS` gains `"cmd:chromium=chromium"`, so the pre-apply gate
    proves the browser before any system file is written.
- `tests/fixtures/cachyos-limine-luks/expected.decisions`: `iso_closure` line
  extended with `chromium`.

## Verification

- `tests/run.sh` → `255 passed, 0 failed`; lint gate exit 0.
- Guest (systemd-boot, minimal golden, no browser): after installing the closure
  package, the same run passes the seeding step — `xdg-settings` returns 0 and
  `omarchy-done mark finalize-user` runs — and the wrapper proceeds to its later
  steps instead of aborting at line 43.
- Falsifiability: on a guest without chromium, the faithful probe
  `sudo -u <user> xdg-settings set default-web-browser chromium.desktop`
  returns 2 (measured), which is exactly the observed abort.

## Considered and rejected

- **Drop the `xdg-settings` registration on CachyOS**: the default browser is
  user-visible state (`xdg-open`, mail/webapp links) and Omarchy's own ISO sets
  it; leaving it unset ships a desktop where links open nothing.
- **Substituting another browser already present**: no browser is present in the
  golden, and Omarchy's webapp helper is chromium-specific
  (`chromium --app=`), so any substitute would also need code changes upstream
  of this repo.
