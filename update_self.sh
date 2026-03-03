#!/bin/zsh

# update_self.sh — topology-aware self-update for dotfiler scripts
#
# Updates the dotfiler scripts directory itself (standalone, submodule, or
# subtree), then re-execs the freshly-updated update.sh to process user
# dotfiles.  For subdir and none topologies, self-update is a no-op and
# update.sh is exec'd directly.
#
# Usage: update_self.sh [-f|--force] [--dry-run] [-q|--quiet] [-v|--verbose]
#
# Flags are forwarded to the exec'd update.sh unchanged.

emulate -L zsh
# PIPE_FAIL and NO_UNSET are useful hardening; ERR_EXIT is intentionally
# omitted — this script does deliberate error recovery (subtree pull can fail
# and we continue) so ERR_EXIT would abort those paths prematurely.
setopt PIPE_FAIL NO_UNSET

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

script_name="${${(%):-%x}:A}"
script_dir="${script_name:h}"

source "${script_dir}/helpers.sh"
source "${script_dir}/update_core.sh"

# ---------------------------------------------------------------------------
# Parse flags (forward all to exec'd update.sh)
# ---------------------------------------------------------------------------

local -a _forward_args
_forward_args=("$@")

local _dry_run=0
local _force=0
for _arg in "$@"; do
    case $_arg in
        --dry-run) _dry_run=1 ;;
        -f|--force) _force=1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Detect deployment topology
# ---------------------------------------------------------------------------

local _subtree_spec
zstyle -s ':dotfiler:update' subtree-remote _subtree_spec 2>/dev/null || _subtree_spec=""

local _self_stamp="${XDG_CACHE_DIR:-$HOME/.cache}/dotfiler/dotfiler_scripts_update"
local _self_freq
zstyle -s ':dotfiler:update' frequency _self_freq 2>/dev/null || _self_freq=3600

_update_core_detect_deployment "$script_dir" "$_subtree_spec"
local _topology=$REPLY

verbose "update_self: topology=$_topology script_dir=$script_dir"


# ---------------------------------------------------------------------------
# Dispatch by topology
# ---------------------------------------------------------------------------

_update_self_exec_update() {
    info "update_self: re-execing update.sh"
    exec "${script_dir}/update.sh" "${_forward_args[@]}"
    # exec only returns on failure
    error "update_self: exec of update.sh failed."
    return 1
}

local _force_str="false"
(( _force )) && _force_str="true"
if ! _update_core_should_update "$_self_stamp" "$_self_freq" "$_force_str"; then
    info "update_self: scripts checked recently -- skipping (use -f to force)"
    _update_self_exec_update
    return $?  # propagate exec failure if it occurs
fi

case $_topology in

    # -----------------------------------------------------------------------
    standalone)
    # The scripts dir is its own standalone git repo.  Pull if an update is
    # available, then re-exec update.sh.
    # -----------------------------------------------------------------------
        local _avail
        _update_core_is_available "$script_dir" && _avail=0 || _avail=$?
        if (( _avail == 0 )); then
            info "update_self: update available — pulling scripts"
            if (( _dry_run )); then
                info "update_self: [dry-run] would git pull"
            else
                local _remote _branch
                _remote=$(_update_core_get_default_remote "$script_dir")
                _branch=$(_update_core_get_default_branch "$script_dir" "$_remote")
                if ! git -C "$script_dir" pull --ff-only "$_remote" "$_branch"; then
                    error "update_self: git pull failed."
                    return 1
                fi
                _update_core_write_timestamp "$_self_stamp"
            fi
        else
            info "update_self: scripts already up to date"
            (( _dry_run )) || _update_core_write_timestamp "$_self_stamp"
        fi
        _update_self_exec_update
        return $?
        ;;

    # -----------------------------------------------------------------------
    submodule)
    # The scripts dir is a submodule inside the user's dotfiles repo.  Update
    # the submodule, optionally commit the parent, then re-exec update.sh.
    # -----------------------------------------------------------------------
        local _submod_root _parent _rel
        _submod_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)
        # Find the parent repo by walking up from _submod_root
        if ! _parent=$(git -C "${_submod_root}/.." rev-parse --show-toplevel 2>/dev/null); then
            error "update_self: cannot find parent repo for submodule."
            _update_self_exec_update
            return $?
        fi
        _rel=${_submod_root#${_parent}/}

        local _mode
        zstyle -s ':dotfiler:update' in-tree-commit _mode 2>/dev/null || _mode="auto"

        if (( _dry_run )); then
            info "update_self: [dry-run] would: git -C $_parent submodule update --remote -- $_rel"
        else
            if ! git -C "$_parent" submodule update --remote -- "$_rel"; then
                error "update_self: submodule update failed."
                _update_self_exec_update
                return $?
            fi
            _update_core_commit_parent \
                "$_parent" "$_rel" \
                "dotfiler submodule updated" \
                "dotfiler: update scripts submodule" \
                "$_mode"
            _update_core_write_timestamp "$_self_stamp"
        fi
        _update_self_exec_update
        return $?
        ;;

    # -----------------------------------------------------------------------
    subtree)
    # The scripts dir lives as a subtree prefix inside the user's dotfiles
    # repo.  Pull the subtree, optionally commit, then re-exec update.sh.
    # -----------------------------------------------------------------------
        local _parent _rel
        if ! _parent=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null); then
            error "update_self: cannot find parent repo for subtree."
            _update_self_exec_update
            return $?
        fi
        local _parent_real _script_real
        _parent_real=${_parent:A}
        _script_real=${script_dir:A}
        _rel=${_script_real#${_parent_real}/}

        # Parse subtree-remote zstyle: "<remote> [<branch>]"
        local _remote _branch
        _remote="${_subtree_spec%% *}"
        _branch="${_subtree_spec#* }"
        [[ "$_branch" == "$_remote" ]] && _branch=""   # no space = no branch given
        [[ -z "$_branch" ]] && \
            _branch=$(_update_core_get_default_branch "$script_dir" "$_remote")

        local _mode
        zstyle -s ':dotfiler:update' in-tree-commit _mode 2>/dev/null || _mode="auto"

        if (( _dry_run )); then
            info "update_self: [dry-run] would: git subtree pull --prefix=$_rel $_remote $_branch --squash"
        else
            if git -C "$_parent" subtree pull \
                --prefix="$_rel" "$_remote" "$_branch" --squash; then

                # Record the remote SHA we just pulled so future
                # _update_core_is_available_subtree can compare against it.
                local _remote_url _pulled_sha
                _remote_url=$(git -C "$script_dir" config "remote.${_remote}.url" 2>/dev/null)
                _pulled_sha=$(_update_core_resolve_remote_sha "$_remote_url" "$_branch" 2>/dev/null)
                if [[ -n "$_pulled_sha" ]]; then
                    _update_core_write_sha_marker "$script_dir" "$_pulled_sha"
                fi

                # Stage the SHA marker alongside the subtree when committing
                # to the parent repo.
                _update_core_sha_marker_path "$script_dir"
                local _marker_path=$REPLY
                if [[ "$_mode" != "none" && -f "$_marker_path" ]]; then
                    git -C "$_parent" add "$_marker_path" 2>/dev/null
                fi

                _update_core_commit_parent \
                    "$_parent" "$_rel" \
                    "dotfiler subtree updated" \
                    "dotfiler: update scripts subtree" \
                    "$_mode"
            else
                error "update_self: subtree pull failed (working tree may have uncommitted changes)."
                # Continue to re-exec update.sh with existing scripts rather
                # than failing hard — the user's dotfiles can still be updated.
            fi
            _update_core_write_timestamp "$_self_stamp"
        fi
        _update_self_exec_update
        return $?
        ;;

    # -----------------------------------------------------------------------
    subdir)
    # Plain subdirectory — parent repo manages the scripts.  Self-update is a
    # no-op; exec update.sh directly.
    # -----------------------------------------------------------------------
        info "update_self: subdir topology — parent repo manages scripts, skipping self-update"
        _update_self_exec_update
        return $?
        ;;

    # -----------------------------------------------------------------------
    none|*)
    # Not inside a git repo at all.  Just exec update.sh.
    # -----------------------------------------------------------------------
        warn "update_self: scripts directory is not a git repo — skipping self-update"
        _update_self_exec_update
        return $?
        ;;
esac
