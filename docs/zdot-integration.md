# zdot Integration

dotfiler integrates with [zdot](https://github.com/georgeharker/zdot), a modular
zsh configuration manager, but **does not require it**. dotfiler works with any
shell setup.

---

## What zdot Provides

When used together, zdot and dotfiler form a layered system:

- **dotfiler** manages your dotfiles repo: link-tree unpacking, config file
  ingestion, and keeping the repo up to date
- **zdot** manages your zsh configuration: modular loading of plugins, themes,
  and shell config, all stored inside your dotfiles repo

zdot is itself managed by dotfiler — it lives in your dotfiles repo as a
submodule, subtree, or plain directory, and dotfiler keeps it updated alongside
everything else.

---

## How the Integration Works

### Components

There are two code paths, depending on context:

**`dotfiler-hook.zsh`** (sourced by dotfiler during update/check runs)

This hook is discovered from the hooks directory
(`$XDG_CONFIG_HOME/dotfiler/hooks/zdot.zsh`), which is an ordinary linktree
symlink unpacked from your dotfiles repo:

```
~/.config/dotfiler/hooks/zdot.zsh
    → ~/.dotfiles/.config/dotfiler/hooks/zdot.zsh   (in-dotfiles symlink)
        → ../../zdot/core/dotfiler-hook.zsh          (relative)
            = ~/.dotfiles/.config/zdot/core/dotfiler-hook.zsh
```

The double-symlink means the hook is always sourced from its **linktree
destination** — which reflects the last cleanly installed state, not a
partially-pulled intermediate.

When dotfiler runs an update, it sources this hook to register zdot as a
component. The hook calls `_update_register_hook`, providing functions for
each update phase (check, plan, pull, unpack, post).

**`update.zsh`** (sourced at shell startup by zdot)

This file is loaded by zdot's standard init when update mode is enabled. It
registers a startup callback that runs `_zdot_update_handle_update` at each
interactive shell login (rate-limited by a timestamp file).

### Lifecycle for a zdot Update

The update runs in two rounds:

**Round 1 — dotfiles-driven.** dotfiler reads the dotfiles commit range
(`HEAD..origin/main`) and extracts the old and new zdot submodule pointer.
This hint is only resolved when `origin/main` is strictly ahead of `HEAD`
(verified with `git merge-base --is-ancestor`). If dotfiles is up to date,
ahead of remote, or diverged, no hint is set and zdot is left entirely to
Round 2. When a hint is set, zdot's plan computes the file list for that range
and pull advances zdot to the new submodule pointer — but only if zdot is not
already at that commit.

**Round 2 — self-directed.** zdot checks its own remote for commits that
postdate the current dotfiles submodule pin. By default only commits reachable
from a semver tag (`v<N>.<N>.<N>[…]`) are considered — see
[Release Channel](#release-channel) below. The framework emits
`Checking for component updates beyond dotfiles...`, then zdot's plan emits
`Checking zdot...` and either `zdot: up to date` or proceeds to pull.

```
ROUND 1:
  PLAN:    dotfiles range computed  →  zdot hint resolved (if incoming commits)
  PULL:    main dotfiles repo       →  zdot (if hint set and not already at target)
  UNPACK:  main dotfiles            →  zdot
  POST:    commit submodule pin in parent repo (if applicable)

ROUND 2:
  PLAN:    zdot checks own remote   →  Checking zdot...
  PULL:    zdot (if behind remote)
  UNPACK:  zdot (if files changed)
  POST:    (none)
```

Pulling the main dotfiles repo first ensures that any new version of zdot's own
hook code (`dotfiler-hook.zsh`, `update-impl.zsh`) is delivered to disk and
symlinked before dotfiler ever executes it. See
[how-updates-work.md](how-updates-work.md#why-dotfiles-run-first) for the full
explanation of this ordering.

### The Symlinked Hook and Partial Updates

This is the most important safety property of the integration:

> **The hook file is always sourced from its linktree path, which is only
> updated during a successful unpack phase.**

Until `setup.zsh` has run successfully for the current update, the linktree
symlink still points to the previous commit's files. The hook that dotfiler
sources is therefore the last version that was fully and cleanly installed — not
the new version that just arrived via `git pull`. New hook code only becomes
active after the unpack phase completes and updates the symlinks.

### Finding update_core.zsh

Both `dotfiler-hook.zsh` and `update.zsh` need to locate `update_core.zsh`
(dotfiler's shared update primitives). They use a three-step priority search:

1. `zstyle ':zdot:dotfiler' scripts-dir /path/to/dotfiler/scripts` — explicit override
2. Parent repo's `.nounpack/dotfiler/update_core.zsh` (detected via
   `git rev-parse --show-superproject-working-tree`)
3. Plugin cache directory (e.g. `~/.cache/zdot/dotfiler/`)

Step 2 is the normal case: zdot detects that it lives inside your dotfiles repo
(either as a submodule or subtree), walks up to the parent, and finds dotfiler
in `.nounpack/dotfiler/`.

### Topology Detection

zdot supports being included in your dotfiles repo as a:

| Topology | How it's detected | How updates are pulled |
|----------|------------------|----------------------|
| **Submodule** | `.git` is a file pointing to the parent's `.git/modules/...` | `git submodule update --remote` |
| **Subtree** | SHA marker file `.<dir>-subtree-sha` adjacent to the component dir | `git subtree pull --squash` |
| **Standalone** | No parent repo detected; zdot has its own `.git` | `git pull --autostash` |
| **Subdir** | Parent repo found but no submodule/subtree indicator | No-op (parent manages everything) |

For submodule topology, dotfiler automatically commits the new submodule pointer
into the parent dotfiles repo after each successful zdot update (controlled by
`zstyle ':dotfiler:update' in-tree-commit auto`).

Note: `.git` symlinks are handled correctly — the integration resolves symlinks
when walking up to find the parent, so zdot stored under a linktree directory
(where `.git` may be a symlink) is detected as a submodule if appropriate.

### Hook Symlink

The hook symlink at `$XDG_CONFIG_HOME/dotfiler/hooks/zdot.zsh` is an ordinary
linktree symlink — it is unpacked from `$DOTFILES/.config/dotfiler/hooks/zdot.zsh`
(which is itself a relative symlink into the zdot tree). It is managed entirely
by the dotfiler unpack process; **nothing installs it at shell startup**.

On a fresh machine the hook symlink must be bootstrapped once before the first
unpack (see [Bootstrap: New Machine](#bootstrap-new-machine) below).

---

## Environment Variables

| dotfiler | zdot | Purpose |
|----------|------|---------|
| `DOTFILER_VERBOSE` | `ZDOT_VERBOSE` | Enable verbose progress output |
| `DOTFILER_DEBUG` | `ZDOT_DEBUG` | Enable debug tracing (implies verbose) |

Setting either debug variable automatically enables verbose output for that
system. The hook bridges these where needed — if you set `ZDOT_DEBUG=1` you will
see debug output from both zdot and dotfiler phases of the update.

---

## Using dotfiler Without zdot

dotfiler requires no zdot-specific code to function. If you use a different shell
configuration manager (or none at all), dotfiler works identically — you simply
won't have the zdot update hook registered.

---

## Setting Up the Integration (First Time)

Choose a deployment topology for zdot inside your dotfiles repo. Submodule is
recommended — it gives you an explicit, pinned version tracked in git history.

### Step 1: Add zdot to your dotfiles repo

**Submodule (recommended):**
```zsh
cd ~/.dotfiles
git submodule add https://github.com/georgeharker/zdot .config/zdot
git submodule update --init --recursive
```

**Subtree:**
```zsh
cd ~/.dotfiles
git subtree add --prefix=.config/zdot \
    https://github.com/georgeharker/zdot main --squash
```

**Subdir (simplest — no pinning):**
```zsh
cd ~/.dotfiles
git clone https://github.com/georgeharker/zdot .config/zdot
```

### Step 2: Install the dotfiler hook symlink into the repo

This creates `$DOTFILES/.config/dotfiler/hooks/zdot.zsh` as a relative symlink
into the zdot tree, and commits it:

```zsh
dotfiler setup --bootstrap-hook ~/.dotfiles/.config/zdot/core/dotfiler-hook.zsh
```

This writes the symlink into `$XDG_CONFIG_HOME/dotfiler/hooks/` (the live hooks
directory). You will be prompted to confirm the git commit that records the
symlink in your dotfiles repo; use `--yes` to skip the prompt.

### Step 3: Unpack everything

```zsh
dotfiler setup -u
```

`-u` unpacks the main dotfiles tree and all registered hook components'
setup functions. After this step:

- `~/.config/dotfiler/hooks/zdot.zsh → ~/.dotfiles/.config/dotfiler/hooks/zdot.zsh`
- All zdot files are symlinked into `~/.config/zdot/`

Steps 2 and 3 can be combined:
```zsh
dotfiler setup \
    --bootstrap-hook ~/.dotfiles/.config/zdot/core/dotfiler-hook.zsh \
    -u
```

### Step 4: Configure zdot's update mode

```zsh
# In your zdot config (e.g. .config/zdot/config.zsh)
zstyle ':zdot:update' mode prompt     # prompt before updating
# or
zstyle ':zdot:update' mode background # update silently in background
```

### Step 4a: Release channel (optional)

By default, self-directed (Round 2) updates for both zdot and dotfiler only
advance to commits reachable from a semver release tag (`v<N>.<N>.<N>[…]`).
This means you control the release gate: no update appears to users until you
push a tag.

```zsh
# Default — only update to published releases:
zstyle ':zdot:update'     release-channel release
zstyle ':dotfiler:update' release-channel release

# Track every commit (for maintainers / automated testing):
zstyle ':zdot:update'     release-channel any
zstyle ':dotfiler:update' release-channel any
```

Round 1 (dotfiles-driven) is unaffected — when your dotfiles repo records a
specific SHA via its submodule pointer or SHA marker, that SHA is installed
exactly regardless of tags.

### Step 5: Configure submodule pin commits (submodule topology only)

```zsh
zstyle ':dotfiler:update' in-tree-commit auto  # default — auto-commit pin bumps
```

---

## Release Channel

Self-directed (Round 2) updates for zdot and dotfiler default to a tag-only
release channel. Only commits reachable from a semver tag matching
`v<N>.<N>.<N>[…]` are offered as updates. This gives the maintainer explicit
control over what users receive: pushing commits to `main` without a tag has no
effect on users with the default configuration.

| Setting | Behaviour |
|---------|-----------|
| `release` (default) | Only advance to the latest semver-tagged commit reachable from the remote branch tip. No tag ahead of current position = no update. |
| `any` | Advance to the branch tip on every check (pre-v0.x behaviour). |

```zsh
# Default (explicit):
zstyle ':zdot:update'     release-channel release
zstyle ':dotfiler:update' release-channel release

# Track every commit pushed to main:
zstyle ':zdot:update'     release-channel any
zstyle ':dotfiler:update' release-channel any
```

**Phase boundary:** this setting has no effect in Round 1 (dotfiles-driven).
When the dotfiles repo records a new submodule pointer or SHA marker for zdot,
that exact SHA is installed regardless of whether it carries a tag.

**Tag resolution:** the check uses the GitHub API (`/repos/<owner>/<repo>/tags`)
to resolve the latest semver tag without a full `git fetch`. On failure or
non-GitHub remotes it falls back to `git ls-remote --tags` combined with local
`merge-base` ancestry checks (which require that a prior `git fetch` has been
done, as it is in the plan phase).

---

## Bootstrap: New Machine

On a fresh machine with your dotfiles repo already cloned:

```zsh
# 1. Clone dotfiles
git clone <your-dotfiles-repo> ~/.dotfiles

# 2. Initialise submodules (submodule topology only)
git -C ~/.dotfiles submodule update --init --recursive

# 3. Bootstrap unpack — reads hooks from repo, unpacks everything
dotfiler setup --bootstrap
```

`--bootstrap` tells dotfiler to read hook files directly from the dotfiles repo
(since the linktree hasn't been set up yet), and implies `-u` —
unpacking both the main dotfiles tree and every registered hook component,
including zdot. After this run the linktree is complete, including
`~/.config/dotfiler/hooks/zdot.zsh`.

After the first `--bootstrap` run, subsequent unpacks use the normal command:
```zsh
dotfiler setup -u   # unpack main dotfiles + all hook components
```

---

## Manual Verification

```zsh
# Check that the hook symlink is in place
ls -la "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiler/hooks/"

# Verify the full symlink chain
readlink ~/.config/dotfiler/hooks/zdot.zsh
readlink ~/.dotfiles/.config/dotfiler/hooks/zdot.zsh

# Force a full update check with debug output
dotfiler check-updates --force --debug

# Full update dry run
dotfiler update --dry-run --debug
```
