# Plan 038: Drop the empty selection before the debloat picker's removal phase

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `f1496e3`, 2026-09-11
- **Executed**: 2026-09-11, in the same commit as this file.

## Why this matters

Found by the release-gate-3 debloat TUI run on the Omarchy 4 guest — the
first time the picker was driven interactively. Selecting one package and one
web app while submitting the TUIs category empty produced:

```
Selected for removal:
  Packages: aether
  Web apps: WhatsApp
  TUIs:
  Agent CLI stubs:
…
(1/1) removing aether
You must select a TUI to remove.
```

Two things are wrong there:

1. `gum choose --no-limit` prints **one empty line when nothing is checked**,
   so `selected_tuis` is `("")` — length 1 — and the summary prints a bare
   `TUIs:` line instead of omitting the category.
2. The removal phase iterates that empty string and calls
   `omarchy-tui-remove ""`; upstream refuses with the message above and exits
   non-zero, which under `set -e` **aborts the rest of the run**: the agent-CLI
   stub removals, the bindings cleanup, the `hyprctl reload` and the closing
   "restore everything" note never happen, after the packages and web apps
   have already been removed. A user who selected a stub and skipped TUIs gets
   half a debloat with no error they can act on.

## What changed

- `bin/debloat-quattro.sh`: the four `gum choose` pipelines
  (`selected_pkgs`, `selected_webapps`, `selected_tuis`, `selected_stubs`) now
  filter empty lines (`| sed '/^$/d'`), so an unchecked category yields a
  genuinely empty array.
- `tests/run.sh` (`picker` section): a case drives the whole
  selection → summary → removal-plan flow with a stub `gum` that answers only
  the Packages prompt, and asserts that the selected package is planned
  (`DRYRUN: omarchy-pkg-drop bash`) and that no empty-category removal is
  planned (`DRYRUN: omarchy-tui-remove` absent).

## Verification

- `tests/run.sh` → `250 passed, 0 failed`; lint gate exit 0.
- Falsifiability: the same stub-driven run against the pre-fix script
  (`git show <pre-fix>:bin/debloat-quattro.sh`) prints
  `DRYRUN: omarchy-tui-remove ` — the assertion fails there and passes after
  the fix.
- Live re-run on the v4 guest with the TUIs category submitted empty: the
  selected stub is removed, no "You must select" message appears, and the run
  reaches its closing note.

## Considered and rejected

- **Filtering inside the removal loops** (`[[ -n $name ]] || continue`): leaves
  the summary and the `full_selection` calculation reading a bogus element, and
  fixes only one of the four sites.
- **Passing `--no-limit` differently or replacing gum**: out of scope; the
  empty-line behaviour is gum's contract and filtering at the boundary is the
  smallest correct fix.
