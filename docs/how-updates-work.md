# How Updates Work
<!-- v0.9.1 -->

## From a User Perspective

dotfiler monitors your dotfiles repository for upstream changes and either
notifies you or applies updates automatically, depending on how it is configured.

Every update pass runs in two **rounds**. **Round 1 (dotfiles-driven)**
applies whatever your dotfiles repo records — the submodule pointers and SHA
markers its history says each component should be at. **Round 2
(self-directed)** then lets each component (dotfiler itself, zdot, any hook
you register) check its *own* upstream for newer work not yet recorded in
dotfiles. The release channel and branch overrides below apply only to
Round 2; Round 1 always follows the recorded pointer faithfully. The full
lifecycle is described in
[Two Rounds of Four Phases](#two-rounds-of-four-phases).

### Setting Up Automatic Checks

Add the following to your shell rc file (e.g. `.zshrc`) to enable update checks
at login (`check_update.zsh` must be **sourced**, not executed, so it can
interact with your shell):

```zsh
# In ~/.zshrc (or your dotfiles' shell init):
[[ -f ~/.dotfiles/.nounpack/dotfiler/check_update.zsh ]] && \
    source ~/.dotfiles/.nounpack/dotfiler/check_update.zsh
```

(Adjust the path for standalone installs, or set
`zstyle ':dotfiles:scripts' path` — see
[Configuration](configuration.md#paths--dotfiles).)

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

The timestamp lives at `${XDG_CACHE_HOME:-~/.cache}/dotfiles/dotfiles_update`;
delete it or run `dotfiler check-updates --force` to check immediately.

### How the Login Check Works

1. A `git fetch` of the tracked remote and branch (silent).
2. Local `HEAD` is compared against `remote/branch` — a difference means
   updates are available.
3. If the fetch fails (no network), the GitHub REST API is tried via
   `curl`/`wget` to compare SHAs. Set `GH_TOKEN` (or `GITHUB_TOKEN`) to
   authenticate these requests and avoid rate-limiting on shared IPs.
4. With no network tools at all, updates are assumed available (fail-open).

A lock directory under `~/.cache/dotfiler/` prevents concurrent runs; stale
locks are recovered after 10 minutes.

The check is skipped silently when the mode is `disabled`, the dotfiles
directory is not owned/writable by the current user, `git` is missing, or
the directory is not a git repo.

### Background Mode and Typed Input

With `mode background`, the check and apply run in background subshells and
the result is surfaced on the **next prompt** via a `precmd` hook — the
login shell never blocks. If you have already typed input when the result
arrives, dotfiler will not interrupt with a `[Y/n]` question; it falls back
to a reminder and leaves `dotfiler update` to you.

### Debugging the Login Check

```zsh
export DOTFILER_VERBOSE=1   # progress output (set before opening a shell)
export DOTFILER_DEBUG=1     # full tracing

dotfiler check-updates --verbose
dotfiler check-updates --debug
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

### Branch Overrides (Round 2 only)

To track a branch other than a component's default — for example testing a
`dev` branch while your dotfiles repo stays on `main`:

```zsh
# Test dotfiler's dev branch in your normal main-tracking dotfiles repo
zstyle ':dotfiler:update' branch dev

# Or for zdot
zstyle ':zdot:update' branch dev
```

An explicit override makes Round 2 actively check the configured branch out
(creating local tracking if missing) and fast-forward there. Without one,
Round 2 pulls whatever branch is currently checked out — a manually
checked-out feature branch is never overridden. Round 1 is unaffected
either way: it follows the recorded pointer faithfully.

The full resolution chain (zstyle → `.gitmodules` → remote default), the
switch behavior, and the subtree `subtree-remote` interaction are in
[Update Internals → Branch Resolution](update-internals.md#branch-resolution).

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

Fetches remote state, computes the commit range that will be applied, and
builds the exact list of files to unpack and remove (only what changed gets
touched). No changes are made to disk at this point — this phase is what
`dotfiler update --dry-run` shows you. In Round 1 it also resolves the
per-component pointer hints from the dotfiles history.

### 2. Pull

All git operations: fetch and merge/fast-forward each registered repository.
The main dotfiles repo is pulled first, then each hook's repo in
registration order. **No unpacking happens until every repo has been pulled
to its new HEAD.** A component whose plan found nothing to do (or whose
HEAD already matches the target) is skipped.

Each hook emits its own `pulling...` and `up to date` messages — the
framework never emits them on a hook's behalf. (The main dotfiles repo is
the framework's own component; its `dotfiles: pulling...` lines do come
from the framework.)

### 3. Unpack

Updates the symlinks in `$HOME` to reflect the new files on disk — main
dotfiles first, then each hook in registration order.

### 4. Post

Housekeeping: records what was installed (submodule pointer commits, SHA
markers — see
[Update Internals → Pointer and Marker Bookkeeping](update-internals.md#pointer-and-marker-bookkeeping-post-phase))
and warns about any install scripts that may need re-running.

---

## Why Dotfiles Run First

Within each phase, the main dotfiles repo always runs before any hook. For
hooks whose code lives *inside* your dotfiles repo (like zdot's), this means
new hook code is pulled **and symlinked into place** before dotfiler ever
executes it — a hook never runs a partially-updated version of itself. The
mechanism is detailed in
[Update Internals → Ordering](update-internals.md#ordering-dotfiles-first-hooks-from-the-linktree).

---

## After a Submodule Update

When a component is a submodule of your dotfiles repo, advancing it leaves a
pointer change in the parent. dotfiler records it for you, controlled by:

```zsh
zstyle ':dotfiler:update' in-tree-commit auto    # commit silently (default)
zstyle ':dotfiler:update' in-tree-commit prompt  # ask first
zstyle ':dotfiler:update' in-tree-commit none    # never commit
```

The same setting governs the SHA marker files used by subtree and standalone
components — per-topology details in
[Update Internals → Deployment Topologies](update-internals.md#deployment-topologies).

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

# Update only dotfiles (skip hooks and self-update)
dotfiler update --update-phases dotfiles

# Update only hook components (repeatable; default is all three)
dotfiler update --update-phases hooks
```
