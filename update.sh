#!/bin/zsh

# update.sh — apply dotfiles updates from git history
#
# Phase-separated execution model:
#   1. PLAN   — fetch, compute ranges, build file lists; source component hooks
#               so they register into _dotfiler_registered_hooks / _dotfiler_hook_*_fn
#               then call each hook's plan_fn in-process (no git writes, no subprocesses)
#   2. PULL   — all git operations (main repo + all components) in registration order
#   3. UNPACK — all setup.sh calls after every repo is at new HEAD
#   4. POST   — commit parent pointers, warn about install scripts, cleanup
#
# Flags: -D/--dry-run, -q/--quiet, -v/--verbose,
#        -c/--commit-hash, -r/--range, --repo-dir, --link-dest

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

script_name="${${(%):-%x}:A}"
helper_script_dir="${script_name:h}"

source "${helper_script_dir}/helpers.sh"
source "${helper_script_dir}/logging.sh"
source "${helper_script_dir}/update_core.sh"

dotfiles_dir=$(find_dotfiles_directory)
script_dir=$(find_dotfiles_script_directory)

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

commit_hash=()
range=()

function usage(){
    echo "Usage: ${script_name} [-D|--dry-run] [-q|--quiet] [-v|--verbose]"
    echo "                      [-c|--commit-hash <hash>] [-r|--range <range>]"
    echo "                      [--repo-dir <path>] [--link-dest <path>]"
}

zmodload zsh/zutil
zparseopts -D -E - \
    q=quiet -quiet=quiet \
    v=verbose -verbose=verbose \
    c+:=commit_hash -commit-hash+:=commit_hash \
    r+:=range -range+:=range \
    D=dry_run -dry-run=dry_run \
    -repo-dir:=opt_repo_dir \
    -link-dest:=opt_link_dest || { usage; exit 1; }

commit_hash=("${(@)commit_hash:#-c}")
commit_hash=("${(@)commit_hash:#--commit-hash}")
range=("${(@)range:#-r}")
range=("${(@)range:#--range}")

[[ ${#quiet[@]} -gt 0 ]]   && quiet_mode=true
[[ ${#verbose[@]} -gt 0 ]] && export DOTFILER_VERBOSE=1

_update_repo_dir="${opt_repo_dir[-1]:-}"
_update_link_dest="${opt_link_dest[-1]:-$HOME}"
[[ -n "$_update_repo_dir" ]] && dotfiles_dir="$_update_repo_dir"

# Is this a component invocation (--repo-dir / --range / --commit-hash)?
# Kept only for informational verbose output — the phase functions handle
# all cases correctly without a separate code path.
_update_component_mode=false
[[ -n "$_update_repo_dir" || ${#range[@]} -gt 0 || ${#commit_hash[@]} -gt 0 ]] \
    && _update_component_mode=true

# ---------------------------------------------------------------------------
# Hook registry
# ---------------------------------------------------------------------------
# Hooks source into this process and call _update_register_hook to declare
# their phase functions.  dotfiler owns the registry; hooks never iterate it.
#
#   _dotfiler_registered_hooks          — ordered array of hook names
#   _dotfiler_hook_check_fn[name]       — fn: 0=available 1=up-to-date 2=error
#   _dotfiler_hook_plan_fn[name]        — fn: populates _dotfiler_plan_<name>_*
#   _dotfiler_hook_pull_fn[name]        — fn: git operations only
#   _dotfiler_hook_unpack_fn[name]      — fn: setup.sh after all pulls
#   _dotfiler_hook_post_fn[name]        — fn: commit parents, markers etc.
#   _dotfiler_hook_cleanup_fn[name]     — fn: unset hook impl fns (check mode)
#   _dotfiler_hook_component_dir[name]  — component repo dir (absolute path)
#   _dotfiler_hook_topology[name]       — standalone|submodule|subtree|subdir

typeset -ga  _dotfiler_registered_hooks
typeset -gA  _dotfiler_hook_check_fn
typeset -gA  _dotfiler_hook_plan_fn
typeset -gA  _dotfiler_hook_pull_fn
typeset -gA  _dotfiler_hook_unpack_fn
typeset -gA  _dotfiler_hook_post_fn
typeset -gA  _dotfiler_hook_cleanup_fn
typeset -gA  _dotfiler_hook_component_dir
typeset -gA  _dotfiler_hook_topology

# _update_register_hook \
#     <name> <check_fn> <plan_fn> <pull_fn> <unpack_fn> <post_fn> \
#     [cleanup_fn] [component_dir] [topology]
# Called by each hook when sourced. cleanup_fn: called by check_update.sh
# after check_fns run. component_dir + topology: used by dotfiler to resolve
# component ranges from a dotfiles range without calling plan_fn first.
function _update_register_hook() {
    local _name=$1
    _dotfiler_registered_hooks+=("$_name")
    _dotfiler_hook_check_fn[$_name]=$2
    _dotfiler_hook_plan_fn[$_name]=$3
    _dotfiler_hook_pull_fn[$_name]=$4
    _dotfiler_hook_unpack_fn[$_name]=$5
    _dotfiler_hook_post_fn[$_name]=$6
    _dotfiler_hook_cleanup_fn[$_name]=${7:-}
    _dotfiler_hook_component_dir[$_name]=${8:-}
    _dotfiler_hook_topology[$_name]=${9:-}
}

# ---------------------------------------------------------------------------
# Helpers: safe operations (dry-run aware)
# ---------------------------------------------------------------------------

function _update_safe_rm(){
    if [[ ${#dry_run[@]} -gt 0 ]]; then
        action "[DRY RUN] Would remove: $1"
    else
        rm -f "$1"
    fi
}

# ---------------------------------------------------------------------------
# PHASE 1 — PLAN
# ---------------------------------------------------------------------------
# Compute diff range and file lists for the main repo, then source each hook
# so it can call _update_register_hook and define its phase functions.
# After all hooks are registered, call each plan_fn in-process to populate
# _dotfiler_plan_<name>_* vars — no git writes, no subprocesses.
#
# Plan variable namespace: _dotfiler_plan_<name>_*
#   _dotfiler_plan_<n>_repo_dir        — repo path
#   _dotfiler_plan_<n>_link_dest       — symlink destination root
#   _dotfiler_plan_<n>_range           — old..new range string
#   _dotfiler_plan_<n>_to_unpack       — array of files to unpack
#   _dotfiler_plan_<n>_to_remove       — array of symlinks to delete
# ---------------------------------------------------------------------------

typeset -gaU _dotfiler_plan_main_to_unpack _dotfiler_plan_main_to_remove

function _update_phase_plan(){
    verbose "update: phase plan: begin"

    # ── Main repo range computation ──────────────────────────────────────
    if [[ ${#commit_hash[@]} -gt 0 ]]; then
        local _target="${commit_hash[1]}"
        local _parent
        _parent=$(git -C "$dotfiles_dir" rev-parse "${_target}^" 2>/dev/null) || {
            warn "Cannot resolve parent of ${_target}"; return 1
        }
        _update_diff_range="${_parent}..${_target}"
        info "Using commit hash mode: ${_update_diff_range}"

    elif [[ ${#range[@]} -gt 0 ]]; then
        _update_diff_range="${range[1]}"
        info "Using range mode: ${_update_diff_range}"

    else
        _update_default_remote=$(_update_core_get_default_remote "$dotfiles_dir")
        _update_default_branch=$(_update_core_get_default_branch \
            "$dotfiles_dir" "$_update_default_remote")
        git -C "$dotfiles_dir" fetch -q \
            "$_update_default_remote" "$_update_default_branch"
        _update_diff_range="HEAD..${_update_default_remote}/${_update_default_branch}"
        info "Using ${_update_default_remote}/${_update_default_branch} mode: ${_update_diff_range}"
    fi

    # ── Main repo file lists ──────────────────────────────────────────────
    typeset -gaU _update_core_files_to_unpack _update_core_files_to_remove
    _update_core_build_file_lists "$dotfiles_dir" "$_update_diff_range"
    _dotfiler_plan_main_to_unpack=("${_update_core_files_to_unpack[@]}")
    _dotfiler_plan_main_to_remove=("${_update_core_files_to_remove[@]}")

    # Register main repo with its phase functions
    _dotfiler_plan_main_repo_dir="$dotfiles_dir"
    _dotfiler_plan_main_link_dest="$_update_link_dest"
    _update_register_hook main \
        '' \
        '' \
        '_update_main_pull' \
        '_update_main_unpack' \
        '_update_main_post'

    verbose "update: phase plan: main repo — \
${#_dotfiler_plan_main_to_unpack[@]} to unpack, \
${#_dotfiler_plan_main_to_remove[@]} to remove"

    # ── Component hooks ───────────────────────────────────────────────────
    # In commit/range mode, resolve each hook's component range from the
    # dotfiles range via marker files, then set _dotfiler_hint_range_<name>
    # before calling the plan_fn. Hook uses the hint if set; falls back to
    # independent fetch if not (e.g. no marker yet on first run).
    local _range_mode=false
    local _old_sha="" _new_sha=""
    if [[ ${#commit_hash[@]} -gt 0 || ${#range[@]} -gt 0 ]]; then
        _range_mode=true
        _old_sha="${_update_diff_range%%..*}"
        _new_sha="${_update_diff_range#*..}"
        info "update: commit/range mode — hooks will attempt range resolution"
    fi

    local _hooks_dir
    zstyle -s ':dotfiler:hooks' dir _hooks_dir \
        || _hooks_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiler/hooks"
    [[ -d "$_hooks_dir" ]] || return 0

    # ── Source each hook — each calls _update_register_hook ──────────────
    local _hook
    for _hook in "$_hooks_dir"/*.zsh(N); do
        [[ -f "$_hook" ]] || continue
        verbose "update: phase plan: sourcing hook ${_hook:t}"
        local _before=${#_dotfiler_registered_hooks}
        source "$_hook"
        if (( ${#_dotfiler_registered_hooks} == _before )); then
            verbose "update: hook '${_hook:t}' did not register (up-to-date or n/a)"
        else
            verbose "update: hook '${_hook:t}' registered: ${_dotfiler_registered_hooks[-1]}"
        fi
    done

    # ── Call each hook's plan_fn in-process ──────────────────────────────
    local _name _fn
    for _name in "${_dotfiler_registered_hooks[@]}"; do
        [[ "$_name" == main ]] && continue
        _fn="${_dotfiler_hook_plan_fn[$_name]:-}"
        [[ -z "$_fn" ]] && continue

        # Resolve component range hint from dotfiles range if in range mode.
        # component_dir and topology are known from registration — no detection needed.
        if [[ "$_range_mode" == true ]]; then
            local _comp_dir="${_dotfiler_hook_component_dir[$_name]:-}"
            local _topology="${_dotfiler_hook_topology[$_name]:-}"
            if [[ -n "$_comp_dir" && -n "$_topology" ]]; then
                _update_core_resolve_component_range \
                    "$dotfiles_dir" "$_old_sha" "$_new_sha" \
                    "$_comp_dir" "$_topology"
                if [[ -n "$REPLY" ]]; then
                    verbose "update: resolved ${_name} range: ${REPLY}"
                    typeset -g "_dotfiler_hint_range_${_name}=${REPLY}"
                else
                    warn "update: cannot resolve ${_name} range from dotfiles range — hook will fetch independently"
                fi
            else
                warn "update: hook '${_name}' did not register component_dir/topology — cannot resolve range hint"
            fi
        fi

        verbose "update: phase plan: calling plan_fn for ${_name}"
        "$_fn"
    done

    verbose "update: phase plan: done"
    return 0
}

# ---------------------------------------------------------------------------
# Main repo phase functions
# ---------------------------------------------------------------------------

function _update_main_pull(){
    [[ ${#dry_run[@]} -gt 0 ]] && return 0
    [[ ${#commit_hash[@]} -gt 0 || ${#range[@]} -gt 0 ]] && return 0
    verbose "update: main pull: git pull"
    git -C "$dotfiles_dir" pull -q \
        "$_update_default_remote" "$_update_default_branch" || {
        warn "Update failed, likely modified files in the way"
        return 1
    }
    return 0
}

function _update_main_unpack(){
    local _link_dest="$_dotfiler_plan_main_link_dest"
    local -a _to_remove=("${_dotfiler_plan_main_to_remove[@]}")
    local -a _to_unpack=("${_dotfiler_plan_main_to_unpack[@]}")

    if [[ ${#_to_remove[@]} -gt 0 ]]; then
        action "Removing files"
        verbose "files to remove: ${_to_remove[*]}"
        local _file _dest
        for _file in "${_to_remove[@]}"; do
            _dest="${_link_dest}/${_file}"
            if [[ -L "$_dest" ]]; then
                action "cleaning up $_dest"
                _update_safe_rm "$_dest"
            else
                warn "$_dest is not a symlink, not removing"
            fi
        done
    fi

    if [[ ${#_to_unpack[@]} -gt 0 ]]; then
        action "Unpacking files"
        verbose "files to unpack: ${_to_unpack[*]}"
        local _dry_run_arg="" _setup_extra=() _quiet_arg=""
        [[ ${#dry_run[@]} -gt 0 ]] && _dry_run_arg="-D"
        [[ -n "$_update_repo_dir" ]] && _setup_extra+=(--repo-dir "$_update_repo_dir")
        [[ "$_link_dest" != "$HOME" ]] && _setup_extra+=(--link-dest "$_link_dest")
        [[ ${#quiet[@]} -gt 0 ]] && _quiet_arg="-q"

        "${script_dir}/setup.sh" \
            ${_dry_run_arg:+"$_dry_run_arg"} \
            "${_setup_extra[@]}" \
            -u \
            ${_quiet_arg:+"$_quiet_arg"} \
            "${_to_unpack[@]}"
        return $?
    fi
    return 0
}

function _update_main_post(){
    local -a _to_unpack=("${_dotfiler_plan_main_to_unpack[@]}")
    [[ ${#_to_unpack[@]} -eq 0 ]] && return 0
    local -a _modified_install=()
    local _file
    for _file in "${_to_unpack[@]}"; do
        [[ "$_file" == .nounpack/install/*.sh ]] && _modified_install+=("$_file")
    done
    if [[ ${#_modified_install[@]} -gt 0 ]]; then
        warn "Install scripts modified, you may need to run dotfile install-module"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# PHASE 2 — PULL
# ---------------------------------------------------------------------------

function _update_phase_pull(){
    verbose "update: phase pull: begin"
    local _name _fn
    for _name in "${_dotfiler_registered_hooks[@]}"; do
        _fn="${_dotfiler_hook_pull_fn[$_name]:-}"
        [[ -z "$_fn" ]] && continue
        verbose "update: phase pull: ${_name} -> ${_fn}"
        "$_fn" || {
            warn "update: pull failed for '${_name}'"
            return 1
        }
    done
    verbose "update: phase pull: done"
    return 0
}

# ---------------------------------------------------------------------------
# PHASE 3 — UNPACK
# ---------------------------------------------------------------------------

function _update_phase_unpack(){
    verbose "update: phase unpack: begin"
    local _name _fn
    for _name in "${_dotfiler_registered_hooks[@]}"; do
        _fn="${_dotfiler_hook_unpack_fn[$_name]:-}"
        [[ -z "$_fn" ]] && continue
        verbose "update: phase unpack: ${_name} -> ${_fn}"
        "$_fn" || warn "update: unpack failed for '${_name}'"
    done
    verbose "update: phase unpack: done"
    return 0
}

# ---------------------------------------------------------------------------
# PHASE 4 — POST
# ---------------------------------------------------------------------------

function _update_phase_post(){
    verbose "update: phase post: begin"
    local _name _fn
    for _name in "${_dotfiler_registered_hooks[@]}"; do
        _fn="${_dotfiler_hook_post_fn[$_name]:-}"
        [[ -z "$_fn" ]] && continue
        verbose "update: phase post: ${_name} -> ${_fn}"
        "$_fn" || warn "update: post failed for '${_name}'"
    done
    verbose "update: phase post: done"
    return 0
}

# ---------------------------------------------------------------------------
# Component mode (backward compat: --repo-dir / --range / --commit-hash)
# ---------------------------------------------------------------------------
# _update_component_mode is true when invoked with explicit repo/range/hash.
# No separate code path needed — _update_phase_plan handles all range modes,
# _update_main_pull skips git pull when range/hash was explicit, and hooks
# are skipped in commit/range mode inside _update_phase_plan already.

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

[[ "$_update_component_mode" == true ]] && \
    verbose "update: component mode (repo=${dotfiles_dir})"

_update_phase_plan || exit $?
_update_phase_pull || exit $?
_update_phase_unpack
_update_phase_post

# Cleanup
unset -f \
    _update_register_hook \
    _update_safe_rm \
    _update_phase_plan \
    _update_main_pull \
    _update_main_unpack \
    _update_main_post \
    _update_phase_pull \
    _update_phase_unpack \
    _update_phase_post \
    2>/dev/null
unset -A \
    _dotfiler_hook_check_fn \
    _dotfiler_hook_plan_fn \
    _dotfiler_hook_pull_fn \
    _dotfiler_hook_unpack_fn \
    _dotfiler_hook_post_fn \
    _dotfiler_hook_cleanup_fn \
    _dotfiler_hook_component_dir \
    _dotfiler_hook_topology \
    2>/dev/null
unset \
    _dotfiler_registered_hooks \
    2>/dev/null
_update_core_cleanup
