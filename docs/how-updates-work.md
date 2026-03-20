# How Updates Work
<!-- v0.9.1 -->

## From a User Perspective

dotfiler monitors your dotfiles repository for upstream changes and either
notifies you or applies updates automatically, depending on how it is configured.

### Setting Up Automatic Checks

Add the following to your shell rc file (e.g. `.zshrc`) to enable update checks
at login:

```zsh
# In ~/.zshrc (or your dotfiles' shell init):
if command -v dotfiler &>/dev/null; then
    source "$(dotfiler scripts-dir)/check_update.zsh"
fi
```

If you use zdot, this is handled automatically by the zdot integration — see
[zdot-integration.md](zdot-integration.md).

### Update Modes

Configure how dotfiler behaves when an update is available:

```zsh
zstyle ':dotfiler:update' mode prompt      # ask before updating (default)
zstyle ':dotfiler:update' mode auto        # update silently
zstyle ':dotfiler:update' mode background  # update in a background subshell
zstyle ':dotfiler:update' mode reminder    # just print a nudge
zstyle ':dotfiler:update' mode disabled    # no checks at all
```

### Update Frequency

By default, dotfiler checks at most once per hour. Override with:

```zsh
zstyle ':dotfiler:update' frequency 86400  # seconds; once per day
```

### Release Channel

By default, **self-directed (Round 2) updates only advance to published
releases** — commits that are reachable from a semver tag matching
`v<N>.<N>.<N>[…]`. If no such tag exists ahead of your current position, no
update is offered.

```zsh
zstyle ':dotfiler:update' release-channel release   # default — wait for a release tag
zstyle ':dotfiler:update' release-channel any    # track branch tip (developers/CI)
```

This applies to both dotfiler's own scripts and to the zdot component (via
`zstyle ':zdot:update' release-channel`). Round 1 (dotfiles-driven) is always
unaffected — when your dotfiles repo records a specific SHA, that SHA is what
gets installed regardless of tags.

The rationale: you control when average users receive an update by publishing a
new `v<N>.<N>.<N>` tag. Commits pushed to `main` between releases are invisible
to users with the default channel — only you (with `release-channel any`) and
automated CI will pick them up immediately.

---

## Two Rounds of Four Phases

An update runs in two rounds, each consisting of four phases in strict order.
All plan state is reset between rounds so that no variables set in Round 1 can
influence Round 2.

**Round 1 — dotfiles-driven:** the main dotfiles repo is the authority.
Component hints (e.g. which zdot commit dotfiles now records) are resolved from
the incoming dotfiles commit range and handed to each hook's plan function.

**Round 2 — self-directed:** each component checks its own remote for updates
that are not yet reflected in dotfiles (e.g. zdot commits that were pushed since
the last dotfiles submodule pin bump). By default the check is constrained to
published releases — see [Release Channel](#release-channel) below.

### 1. Plan

Fetches remote state, computes the commit range that will be applied, and builds
the list of files to unpack and remove. No changes are made to disk at this
point. This phase is safe to run in dry-run mode (`dotfiler update --dry-run`).

**Hint resolution (Round 1 only):** when dotfiles has incoming commits, dotfiler
reads the old and new submodule/marker pointer for each registered hook from
the dotfiles commit range. This is only performed when `_new_sha` is strictly
ahead of `_old_sha` — verified with `git merge-base --is-ancestor`. If dotfiles
is up to date, ahead of remote, or diverged, no hints are set and components are
left to Round 2 for self-directed checks.

File discovery uses two independent find passes:

- **Shallow pass** (depth 1 only): top-level entries whose name begins with `.`
  followed by a letter. Directories are never symlinked — this pass gates which
  top-level directories are created in `$HOME`.
- **Deep pass** (all depths, files and symlinks only): all files under the repo
  root, pruned by exclusion patterns (`.git/`, `.nounpack/`, user-defined
  exclusions). This pass is independent of the shallow pass.

**Exclusion patterns are the authoritative gate** for controlling whether files
inside non-dotted top-level directories (e.g. `bin/`, `notes/`) get unpacked.
Any directory not in the exclusion list will have its files unpacked via the
deep pass. Files under `.nounpack/` are never included at any depth.

### 2. Pull

All git operations: fetch and merge/rebase each registered repository. The main
dotfiles repo is pulled first, then each hook's repo in registration order.
**No unpacking happens until every repo has been pulled to its new HEAD.**

A pull is skipped for a component when:
- its plan range is empty (nothing to do), or
- its current HEAD already matches the target SHA recorded in dotfiles
  (e.g. it was already advanced by the shell-hook before `dotfiler update` ran)

Each hook is responsible for emitting its own `pulling...` and `up to date`
messages from inside its pull function. The framework does not emit these.**

### 3. Unpack

Runs `setup.zsh` for each registered component (main dotfiles first, then hooks
in registration order). This is where symlinks in `$HOME` are updated to reflect
the new files on disk.

### 4. Post

Post-update housekeeping: commits updated submodule pointers into the parent
repo (if applicable), writes SHA marker files for subtree and standalone
topologies, and warns about any install scripts that may need to be re-run.

---

## Why Dotfiles Run First

Within each phase, the **main dotfiles repo always runs before any hook**.

This ordering is critical for hooks whose code lives *inside* your dotfiles repo
(such as the zdot hook). Consider a zdot update that also ships a new version of
`dotfiler-hook.zsh`:

1. **Pull phase**: dotfiles repo is pulled first → new `dotfiler-hook.zsh`
   arrives on disk inside the dotfiles repo
2. **Unpack phase**: dotfiles are unpacked first → `dotfiler-hook.zsh` is
   symlinked from the repo into its linktree destination
   (`~/.config/zdot/core/dotfiler-hook.zsh`)
3. **Only then** does zdot's pull and unpack run — using the now-current hook
   code from the linktree

If the order were reversed, the hook could execute against a version of its own
code that had arrived via `git pull` but had not yet been symlinked into the
linktree — a partially-updated, inconsistent state.

The linktree destination is only updated when `setup.zsh` runs successfully.
Until then it reflects the last fully-installed state, which is always safe to
execute.

---

## dotfiler Self-Update

dotfiler keeps its own scripts up to date separately. The self-update runs
**after** the main dotfiles + hooks cycle and does not require an unpack phase
(dotfiler's scripts are not symlinked via the link-tree — they live in
`.nounpack/dotfiler/` and are accessed directly).

Self-update frequency is controlled independently:

```zsh
zstyle ':dotfiler:update' self-frequency 86400  # default: 3600
```

---

## Deployment Topologies

dotfiler detects how your dotfiles repo is structured and adapts its pull
strategy accordingly:

| Topology | Detection | Pull strategy |
|----------|-----------|---------------|
| **Submodule** | `.git` is a file (gitdir pointer) | `git submodule update --remote` |
| **Subtree** | SHA marker file adjacent to component dir | `git subtree pull --squash` |
| **Standalone** | Own `.git` directory, no parent | `git pull --autostash` |
| **Subdir** | Parent repo found, no submodule/subtree indicator | No-op (parent manages it) |

Note: `.git` symlinks are resolved correctly — a component stored under a
linktree directory (where `.git` may be a symlink) is still detected as a
submodule if appropriate.

### In-Tree Commits (Submodule Topology)

After updating a submodule, dotfiler can automatically commit the new submodule
pointer into the parent dotfiles repo:

```zsh
zstyle ':dotfiler:update' in-tree-commit auto    # commit silently (default)
zstyle ':dotfiler:update' in-tree-commit prompt  # ask first
zstyle ':dotfiler:update' in-tree-commit none    # never commit
```

---

## Manual Update Commands

```zsh
# Check for updates now (ignoring frequency stamp)
dotfiler check-updates --force

# Apply update
dotfiler update

# Dry run — plan only, no pull/unpack
dotfiler update --dry-run

# Debug output
dotfiler update --debug

# Update only dotfiler scripts themselves
dotfiler update --update-phases dotfiler

# Update only dotfiles (skip self-update)
dotfiler update --update-phases dotfiles
```
