# Update Hooks

Update hooks allow components of your dotfiles (or external tools integrated with
dotfiler) to participate in the update lifecycle. A hook can check whether its
component has upstream changes available, and if so, apply them as part of the
normal `dotfiler update` run.

The zdot shell configuration manager ships a hook (`dotfiler-hook.zsh`) as the
reference implementation.

---

## Hook Lifecycle

When dotfiler runs an update check or applies an update, it invokes each
registered hook through five phases:

| Phase | Function | Purpose |
|-------|----------|---------|
| `check` | `check_fn` | Is an update available? Return 0=yes, 1=no |
| `plan` | `plan_fn` | Compute what will change (dry-run safe) |
| `pull` | `pull_fn` | Fetch/pull from remote |
| `unpack` | `unpack_fn` | Apply changes (symlinks, post-processing) |
| `post` | `post_fn` | Post-update actions (reload shell, etc.) |

Not all phases need to be implemented. Pass empty strings for phases you don't
need.

### Phase Ordering

All registered hooks participate in each phase together before the next phase
starts. The order within a phase is **main dotfiles first, then hooks in
registration order**. This is critical:

- `pull` for main dotfiles runs before any hook's `pull` — every repo is pulled
  before any unpack begins
- `unpack` for main dotfiles runs before any hook's `unpack` — if a hook's new
  code lives inside the dotfiles repo, it will be symlinked to its linktree
  destination (and therefore up-to-date) before dotfiler executes it

This design prevents a hook from ever running against partially-updated code that
arrived via the dotfiles pull but hasn't yet been unpacked.

See [how-updates-work.md](how-updates-work.md#why-dotfiles-run-first) for full
phase sequencing details.

---

## Hook File Structure

A hook is a `.zsh` file placed in the hooks directory
(default: `$XDG_CONFIG_HOME/dotfiler/hooks/`, configurable via
`zstyle ':dotfiler:hooks' dir /path/to/hooks`).

dotfiler sources each `*.zsh` file in that directory and expects it to call
`_update_register_hook` to register itself.

```zsh
# ~/.config/dotfiler/hooks/my-component.zsh

_update_register_hook \
    "my-component" \          # unique name
    "_my_check_fn" \          # check phase function name
    "_my_plan_fn" \           # plan phase function name
    "_my_pull_fn" \           # pull phase function name
    "_my_unpack_fn" \         # unpack phase function name
    "_my_post_fn" \           # post phase function name
    "_my_cleanup_fn" \        # cleanup function (unsets your functions)
    "/path/to/component" \    # component directory
    "submodule"               # topology hint: submodule|subtree|standalone

# --- Phase functions ---

function _my_check_fn() {
    _update_core_is_available "/path/to/component"
}

function _my_plan_fn() {
    # populate info about pending changes
    # see _update_core_build_file_lists
}

function _my_pull_fn() {
    git -C "/path/to/component" pull --ff-only
}

function _my_unpack_fn() {
    # apply symlinks, compile files, etc.
}

function _my_post_fn() {
    info "Restart your shell to apply changes"
}

function _my_cleanup_fn() {
    unset -f _my_check_fn _my_plan_fn _my_pull_fn \
             _my_unpack_fn _my_post_fn _my_cleanup_fn
}
```

### Optional `setup_fn` (Tenth Argument)

You may pass a tenth argument to `_update_register_hook` — a setup function name.
This function is called by `dotfiler setup --all` or
`dotfiler setup --component <name>` to perform a full unpack outside of the
incremental update flow (e.g. on a fresh clone or forced reinstall).

```zsh
_update_register_hook \
    "my-component" \
    "_my_check_fn" "_my_plan_fn" "_my_pull_fn" \
    "_my_unpack_fn" "_my_post_fn" \
    "_my_cleanup_fn" \
    "/path/to/component" \
    "submodule" \
    "_my_setup_fn"            # called by: dotfiler setup --component my-component
```

---

## Hook Discovery and Auto-Installation

When a hook is delivered *inside* your dotfiles repo (e.g. a zdot hook at
`.config/zdot/core/dotfiler-hook.zsh`), the recommended pattern is to create a
symlink in the hooks directory pointing into the linktree:

```
~/.config/dotfiler/hooks/my-component.zsh  →  ~/.config/zdot/core/dotfiler-hook.zsh
                                               (linktree destination)
```

This way the hook is sourced from its post-unpacked linktree path, which is
always the version that was last cleanly installed — never a partially-updated
intermediate state. zdot's `update.zsh` creates this symlink automatically on
first load; you can replicate the pattern for your own components.

---

## The `_update_core_*` API

The `update_core.zsh` library provides helpers for all common update operations.
These are available to your hook functions when dotfiler sources your hook.

### Availability Checks

```zsh
# Is an update available in this repo?
_update_core_is_available "/path/to/repo"
# Returns 0=yes, 1=no-update, 2=no-network

# For subtree deployments
_update_core_is_available_subtree "/path/to/repo" "origin/main"
```

`_update_core_is_available` prefers the GitHub REST API (via curl or wget) to
avoid an expensive `git fetch` when possible. It falls back to `git fetch` on
non-GitHub remotes.

### Deployment Detection

```zsh
_update_core_detect_deployment "/path/to/repo"
# Sets REPLY=submodule|subtree|standalone|subdir|none
```

### Parent Repo

```zsh
_update_core_get_parent_root "/path/to/repo"
# Sets reply=( path kind )
# kind: superproject | toplevel | none
```

Correctly handles the case where `.git` is a symlink (common when a component
lives under a linktree directory) by resolving the symlink target to find the
real superproject.

### File Change Lists

```zsh
_update_core_build_file_lists "/path/to/repo" "HEAD..origin/main"
# Sets _update_core_files_to_unpack and _update_core_files_to_remove
```

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

Squashed subtree merge commits are skipped automatically.

### Component Range Resolution

```zsh
_update_core_resolve_component_range \
    "/path/to/dotfiles" "$old_sha" "$new_sha" \
    "/path/to/component" "submodule"
# → REPLY = "old_sha..new_sha" for the component
```

Dispatches by topology:
- `submodule` — reads from `git ls-tree` in the parent at the old/new SHAs
- `subtree` — reads from the SHA marker file
- `standalone` — reads from the external marker file

### SHA Markers

Used to track which version of a component was last unpacked:

```zsh
_update_core_sha_marker_path "/path/to/repo"  # → reply[1]
_update_core_read_sha_marker "/path/to/repo"  # → reply[1] (SHA or empty)
_update_core_write_sha_marker "/path/to/repo" "$new_sha"

# External (non-git) version markers
_update_core_ext_marker_path "/path/to/repo"
_update_core_read_ext_marker "/path/to/repo"
_update_core_write_ext_marker "/path/to/repo" "$version_string"
```

### Locking

Prevent concurrent update runs:

```zsh
local _lock_dir="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiler/my-component.lock"
_update_core_acquire_lock "$_lock_dir" || return 0
# ... do work ...
_update_core_release_lock "$_lock_dir"
```

Stale locks (older than 600 seconds) are recovered automatically.

### Timestamps

```zsh
_update_core_write_timestamp "/path/to/timestamp" 0 "Update successful"
_update_core_write_timestamp "/path/to/timestamp" 1 "Error message"
```

### Committing Parent

If your component is a submodule, commit the parent repo after updating:

```zsh
_update_core_commit_parent "/path/to/component" "HEAD~1..HEAD"
```

The commit mode (`auto|prompt|none`) is read from:
```zsh
zstyle ':dotfiler:update' in-tree-commit auto   # default: auto-commit
```

### Update Frequency

```zsh
_update_core_should_update "$stamp_file" "$freq_seconds" "$force_flag"
# Returns 0=proceed, 1=too-soon

_update_core_get_update_frequency "scope"  # reads ':scope:update' frequency zstyle
```

---

## Logging in Hooks

Use the standard logging functions — they are available as shims when your hook
runs in the dotfiler hook-check context (where zdot logging may not be loaded):

```zsh
info "message"       # plain output
action "message"     # blue — doing something
success "message"    # green — succeeded
warn "message"       # yellow stderr — non-fatal
error "message"      # red stderr — fatal
verbose "message"    # shown with --verbose or DOTFILER_VERBOSE
log_debug "message"  # shown with --debug or DOTFILER_DEBUG
```

If your hook is sourced from the zdot startup context (where `zdot_info` etc.
are already defined), the hook automatically maps them to dotfiler's equivalents
and cleans up the shims on completion.

---

## Minimal Check-Only Hook

If you only need to participate in the `check` phase (e.g. to notify the user
that a component needs attention but not auto-update it):

```zsh
_update_register_hook \
    "my-readonly-component" \
    "_my_check_fn" \
    "" "" "" "" \
    "_my_cleanup_fn" \
    "/path/to/component" \
    "standalone"

function _my_check_fn() {
    local current desired
    current=$(cat /path/to/component/.version 2>/dev/null)
    desired=$(curl -sf https://example.com/version)
    [[ "$current" != "$desired" ]]  # 0=update available
}

function _my_cleanup_fn() {
    unset -f _my_check_fn _my_cleanup_fn
}
```

---

## Testing Your Hook

```zsh
# Check phase only
dotfiler check-updates --force --debug

# Full update run
dotfiler update --debug

# Dry run (plan only, no pull/unpack)
dotfiler update --dry-run --debug
```

See `dotfiler-hook.zsh` in the zdot repo for a complete production hook example.
