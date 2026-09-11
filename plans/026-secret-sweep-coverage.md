# Plan 026: Make the inline-credential sweep case-insensitive and complete

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If any
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row for this plan in `plans/README.md` (or leave it to the
> reviewer).
>
> **Drift check (run first)**: `git diff --stat e80b564..HEAD -- bin/lib/profile.sh bin/omocachy-profile-export.sh`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `e80b564`, 2026-09-11
- **Executed**: 2026-09-11 (landed at `f4a3836`); Step 1's literal alternation could not match `GITHUB_TOKEN`/`AWS_SECRET_ACCESS_KEY`, so `secret[_-]?access[_-]?key` and `token` were added; the STOP-1 false-positive probe (19→31→54 files on the real capture list, all non-config) is recorded in the batch report.

## Why this matters

The exporter's sensitivity report (`SUMMARY.md`: "files with inline
credentials: N") is what tells the operator whether a bundle is safe to hand
around. The sweep behind it is case-sensitive and its alternation is lowercase
only: `apiKey`, `API_KEY`, `GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY` never match,
and `grep -rlIE` without `-i` cannot rescue them. The plan that introduced the
report (`plans/018-*.md`) names `shell.json` as the canonical example of a file
that carries API keys — and `"apiKey": "…"` is exactly the shape the regex
misses. A "0" count is therefore not trustworthy, and neither is the
instruction to treat a clean bundle as clean.

## Current state

- `bin/lib/profile.sh`:
  - `:55-69` — `PROFILE_SECRET_DIRS` (credential stores, refused at capture).
  - `:71-102` — `PROFILE_SECRET_FILE_GLOBS` (`*.pem`, `*.key`, `.netrc`,
    `.npmrc`, `*token*`, `*secret*`, `*credential*`, `*password*`, …).
  - `:104-108`:
    ```bash
    # Text that suggests a captured config carries a credential inline. Used for
    # a warning only — these files (shell.json above all: plugin service URLs and
    # API keys live there) are part of the desktop profile and must travel.
    PROFILE_SECRET_CONTENT_RE='(api[_-]?key|apikey|access[_-]?token|bearer |client[_-]?secret|password)['"'"'"]?\s*[:=]'
    ```
- `bin/omocachy-profile-export.sh:245-252`:
  ```bash
  INLINE_SECRETS="$WORK/inline-secrets.txt"
  : >"$INLINE_SECRETS"
  if ! $DRY_RUN; then
      grep -rlIE "$PROFILE_SECRET_CONTENT_RE" "$BUNDLE/home" 2>/dev/null |
          sed "s|^$BUNDLE/home/||" | sort >"$INLINE_SECRETS" || true
  fi
  INLINE_HITS=$(wc -l <"$INLINE_SECRETS" | tr -d ' ')
  ```
  (`PROFILE_SECRET_CONTENT_RE` reaches the script through
  `source "$SCRIPT_DIR/lib/profile.sh"`.)

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Regex unit check | the `printf | grep` loop in Step 2 | every line matches |
| Export dry run | `bin/omocachy-profile-export.sh --out /tmp/omocachy-sweep --dry-run` | exit 0, prints the plan |
| Lint | `bash -n bin/*.sh bin/lib/*.sh tests/run.sh && shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh` | exit 0 |
| Fixture suite | `tests/run.sh` | `0 failed` |

## Scope

**In scope**: `bin/lib/profile.sh`, `bin/omocachy-profile-export.sh` (the one
grep invocation), one regression case in `tests/run.sh`.

**Out of scope**: the name sweep's decision to let `shell.json` travel (that
is deliberate — the report is the mitigation), the secret-store directory list,
the manifest/remotes scrub (plan 020).

## Git workflow

- Branch: `advisor/026-secret-sweep-coverage`
- Commit message, e.g.: `Make the inline-credential sweep case-insensitive and cover common key shapes`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Broaden the pattern

Replace the regex with:

```bash
PROFILE_SECRET_CONTENT_RE='(api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|auth[_-]?token|bearer|client[_-]?secret|secret[_-]?key|private[_-]?key|password|passwd)['"'"'"]?[[:space:]]*[:=]'
```

(`\s` is a GNU extension; use `[[:space:]]` so the pattern stays portable
across the greps that consume it. Case-insensitivity comes from the caller —
Step 2.)

**Verify**: the Step 2 loop.

### Step 2: Sweep case-insensitively and prove the shapes match

Change the export's grep to `grep -rliE`. Then:

```bash
cd /home/t1nk33r/Projects/omocachy/omocachy
bash -c '
source bin/lib/profile.sh
for s in "apiKey = \"x\"" "API_KEY: y" "GITHUB_TOKEN=z" "AWS_SECRET_ACCESS_KEY=w" "access_token: t" "password: p"; do
    printf "%s\n" "$s" | grep -qiE "$PROFILE_SECRET_CONTENT_RE" || echo "MISSED: $s"
done
for s in "keyboard = us" "monitor = DP-1"; do
    printf "%s\n" "$s" | grep -qiE "$PROFILE_SECRET_CONTENT_RE" && echo "FALSE: $s"
done
echo regex-done'
```

Expected: `regex-done` with no `MISSED`/`FALSE` lines.

**Verify**: as above.

### Step 3: Add the missing credential-shaped names

Extend `PROFILE_SECRET_FILE_GLOBS` with the names that are unambiguously
credential stores but missing today:

```bash
'.pgpass'
'*.keystore'
'fish_variables'
```

Do NOT add generic names (`auth.json`, `mise/config.toml`) here: they can hold
non-secret state, and the content sweep now reports them when they do. Record
that decision in the commit body.

**Verify**: `grep -n 'pgpass\|keystore\|fish_variables' bin/lib/profile.sh` →
three new globs.

### Step 4: Regression case in `tests/run.sh`

Add a case that sources `bin/lib/profile.sh` and runs the Step 2 loops (the
`MISSED` set as `bad`, the `FALSE` set as `bad`). One case, no temp files.

**Verify**: `tests/run.sh` → `0 failed`, including the new case.

### Step 5: Export dry run

**Verify**: `bin/omocachy-profile-export.sh --out /tmp/omocachy-sweep --dry-run`
→ exit 0. (Dry run does not perform the sweep; this only proves the script
still parses.)

## Test plan

- Step 4's case fails against the old pattern (`apiKey`, `API_KEY`,
  `GITHUB_TOKEN` lines) and passes after Step 1–2 — that is the regression.
- A live end-to-end sweep is exercised in the lab VM per `plans/018-*.md`'s
  verification notes; note in your report if you could not run it.

## Done criteria

- [ ] All six credential shapes match; both non-secret shapes do not
- [ ] `grep -rliE` is the sole consumer of the pattern (no other `grep -rlIE`)
- [ ] The three new globs are in `PROFILE_SECRET_FILE_GLOBS`
- [ ] Lint gate exit 0; `tests/run.sh` `0 failed`
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- Broadening the pattern turns a common config into a false positive on the
  dev host's own export (check the count in a real run before/after; if the
  count explodes, report the file list instead of narrowing silently).
- The code no longer matches the excerpts (drift).

## Maintenance notes

- False positives remain visible (`system/inline-secrets.txt` lists paths) —
  keep that property; never suppress a hit.
- Deferred: a content sweep over the manifest and `system/*.tsv` (plan 020
  scrubs the remotes themselves; a full sweep of the metadata files would be
  the belt-and-braces follow-up).
