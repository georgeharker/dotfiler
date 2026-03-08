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
submodule, subtree, or checked-out directory, and dotfiler keeps it updated
alongside everything else.

---

## How the Integration Works

### Components

There are two code paths, depending on context:

**`dotfiler-hook.zsh`** (sourced by dotfiler during update/check runs)

This hook is discovered automatically from the hooks directory
(`$XDG_CONFIG_HOME/dotfiler/hooks/zdot.zsh`), which is a symlink pointing into
the linktree destination of the zdot hook file:

```
~/.config/dotfiler/hooks/zdot.zsh
    → ~/.config/zdot/core/dotfiler-hook.zsh      (linktree symlink)
        → ~/.dotfiles/.config/zdot/core/dotfiler-hook.zsh  (real file)
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
interactive shell login (rate-limited by a timestamp file). It also installs the
`zdot.zsh` symlink in the hooks directory automatically on first load.

### Lifecycle for a zdot Update

1. Shell starts, zdot's `update.zsh` fires its startup hook
2. Frequency check: if updated recently, skip
3. dotfiler checks for updates to the main dotfiles repo and to zdot
4. If updates are available, applies them in the correct phase order:

```
PULL:    main dotfiles repo  →  zdot repo
UNPACK:  main dotfiles       →  zdot
POST:    commit submodule pin in parent repo (if applicable)
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

This means it is safe to:
- Pull zdot's repo to a new commit that contains changes to `dotfiler-hook.zsh`
- Use the old hook code to drive the unpack of that commit

The new code takes effect on the next update cycle.

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
| **Submodule** | `.git` is a file (or symlink to a file) pointing to the parent's `.git/modules/...` | `git submodule update --remote` |
| **Subtree** | SHA marker file `.<dir>-subtree-sha` adjacent to the component dir | `git subtree pull --squash` |
| **Standalone** | No parent repo detected; zdot has its own `.git` | `git pull --autostash` |
| **Subdir** | Parent repo found but no submodule/subtree indicator | No-op (parent manages everything) |

For submodule topology, dotfiler automatically commits the new submodule pointer
into the parent dotfiles repo after each successful zdot update (controlled by
`zstyle ':dotfiler:update' in-tree-commit auto`).

Note: `.git` symlinks are handled correctly — the integration resolves symlinks
when walking up to find the parent, so zdot stored under a linktree directory
(where `.git` may be a symlink) is detected as a submodule if appropriate.

### Auto-Installation of the Hook Symlink

`update.zsh` installs the hooks symlink automatically the first time it runs:

```
$XDG_CONFIG_HOME/dotfiler/hooks/zdot.zsh  →  <ZDOT_REPO>/core/dotfiler-hook.zsh
```

This only happens if dotfiler is detected in the parent repo (step 2 above). If
dotfiler is not found, the symlink is not created and zdot operates in
standalone update mode only (using `_zdot_update_handle_update` directly,
without the full hook registry).

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

All of dotfiler's core features are standalone:

- Link-tree unpacking of config files
- Config file ingestion
- Auto-update for your dotfiles repo
- Modular install scripts for new machine setup
- Shell completions

---

## Setting Up the Integration

If you use zdot and want dotfiler to manage it:

1. Add zdot to your dotfiles repo (submodule is recommended):
   ```zsh
   git submodule add https://github.com/georgeharker/zdot .config/zdot
   ```

2. Enable zdot's update mode in your zdot configuration:
   ```zsh
   # In your zdot config (e.g. .config/zdot/config.zsh)
   zstyle ':zdot:update' mode prompt     # prompt before updating
   # or
   zstyle ':zdot:update' mode background # update silently
   ```

3. Source zdot's `update.zsh` from your shell init (zdot does this automatically
   if you use the standard loading mechanism):
   ```zsh
   source "$ZDOT_DIR/core/update.zsh"
   ```

4. On first shell startup, `update.zsh` will auto-install the
   `$XDG_CONFIG_HOME/dotfiler/hooks/zdot.zsh` symlink if it finds dotfiler in
   the parent repo.

5. Configure the in-tree commit mode (for submodule topology):
   ```zsh
   zstyle ':dotfiler:update' in-tree-commit auto  # default — auto-commit pin bumps
   ```

### Manual Verification

```zsh
# Check that the hook symlink is in place
ls -la "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiler/hooks/"

# Force a full update check with debug output
dotfiler check-updates --force --debug

# Full update dry run
dotfiler update --dry-run --debug
```
