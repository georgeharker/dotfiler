# Update Hooks

Update hooks allow components of your dotfiles (or external tools integrated with
dotfiler) to participate in the update lifecycle. A hook can check whether its
component has upstream changes available, and if so, apply them as part of the
normal `dotfiler update` run.

The zdot shell configuration manager ships a hook as the reference example.

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

---

## Hook File Structure

A hook is a `.zsh` file placed in the hooks directory
(default: `$XDG_CONFIG_HOME/dotfiler/hooks/`, configurable via
`zstyle ':dotfiler:hooks' dir /path/to/hooks`).

dotfiler sources each `*.zsh` file in that directory and expects it to call
`_update_register_hook` to register itself.

```zsh
# ~/.config/dotfiler/hooks/my-component.zsh

# Source any helpers you need, then register:
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
    # populate reply with info about pending changes
    # see _update_core_build_file_lists
}

function _my_pull_fn() {
    git -C "/path/to/component" pull --ff-only
}

function _my_unpack_fn() {
    # apply symlinks, compile files, etc.
}

function _my_post_fn() {
    # e.g. reload shell config
    info "Restart your shell to apply changes"
}

function _my_cleanup_fn() {
    unset -f _my_check_fn _my_plan_fn _my_pull_fn \
             _my_unpack_fn _my_post_fn _my_cleanup_fn
}
```

---

## The `_update_core_*` API

The `update_core.zsh` library provides helpers for all common update operations.
These are available to your hook functions when dotfiler sources your hook.

### Availability Checks

```zsh
# Is an update available in this repo?
_update_core_is_available "/path/to/repo"
# Returns 0=yes, 1=no-update, 2=no-network

# Lower-level: check a specific remote+branch
_update_core_is_available_fetch "/path/to/repo" "origin" "main"

# For subtree deployments
_update_core_is_available_subtree "/path/to/repo" "origin/main"
```

### Deployment Detection

```zsh
_update_core_detect_deployment "/path/to/repo"
# Sets reply=( mode remote branch )
# mode: submodule | subtree | standalone
local mode=$reply[1] remote=$reply[2] branch=$reply[3]
```

### Remote / Branch Info

```zsh
_update_core_get_default_remote "/path/to/repo"   # → reply[1]
_update_core_get_default_branch "/path/to/repo" "origin"  # → reply[1]
_update_core_resolve_remote_sha "/path/to/repo" "origin" "main"  # → reply[1]
```

### Parent Repo

```zsh
_update_core_get_parent_root "/path/to/repo"
# Sets reply=( path kind )
# kind: superproject | toplevel | none
```

### File Change Lists

```zsh
_update_core_build_file_lists "/path/to/repo" "HEAD..origin/main"
# Sets reply=( added_files modified_files deleted_files )
```

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

---

## Logging in Hooks

Use the standard logging functions — they are available as shims when your hook
runs:

```zsh
info "message"       # plain output
action "message"     # blue — doing something
success "message"    # green — succeeded
warn "message"       # yellow stderr — non-fatal
error "message"      # red stderr — fatal
verbose "message"    # shown with --verbose or DOTFILER_VERBOSE
log_debug "message"  # shown with --debug or DOTFILER_DEBUG
```

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
```

See `dotfiler-hook.zsh` in the zdot repo for a complete production hook example.
