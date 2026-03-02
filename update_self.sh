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
setopt ERR_EXIT PIPE_FAIL NO_UNSET

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

info "update_self: topology=$_topology script_dir=$script_dir"

# ---------------------------------------------------------------------------
# Dispatch by topology
# ---------------------------------------------------------------------------

_update_self_exec_update() {
    info "update_self: re-execing update.sh"
    exec "${script_dir}/update.sh" "${_forward_args[@]}"
}

local _force_str="false"
(( _force )) && _force_str="true"
if ! _update_core_should_update "$_self_stamp" "$_self_freq" "$_force_str"; then
    info "update_self: scripts checked recently -- skipping (use -f to force)"
    _update_self_exec_update
    return
fi

case $_topology in

    # -----------------------------------------------------------------------
    standalone)
    # The scripts dir is its own standalone git repo.  Pull if an update is
    # available, then re-exec update.sh.
    # -----------------------------------------------------------------------
        _update_core_is_available "$script_dir"
        local _avail=$?
        if (( _avail == 0 )); then
            info "update_self: update available — pulling scripts"
            if (( _dry_run )); then
                info "update_self: [dry-run] would git pull"
            else
                local _remote _branch
                _remote=$(_update_core_get_default_remote "$script_dir")
                _branch=$(_update_core_get_default_branch "$script_dir" "$_remote")
                git -C "$script_dir" pull --ff-only "$_remote" "$_branch" \
                    || warn "update_self: git pull failed — continuing with existing scripts"
                _update_core_write_timestamp "$_self_stamp"
            fi
        else
            info "update_self: scripts already up to date"
            (( _dry_run )) || _update_core_write_timestamp "$_self_stamp"
        fi
        _update_self_exec_update
        ;;

    # -----------------------------------------------------------------------
    submodule)
    # The scripts dir is a submodule inside the user's dotfiles repo.  Update
    # the submodule, optionally commit the parent, then re-exec update.sh.
    # -----------------------------------------------------------------------
        # git -C script_dir --show-toplevel gives script_dir's own git root
        # (the submodule root).  Walk up from there to find the parent repo.
        local _submod_root _parent _rel
        _submod_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)
        # Find the parent repo by walking up from _submod_root
        _parent=$(git -C "${_submod_root}/.." rev-parse --show-toplevel 2>/dev/null) \
            || { warn "update_self: cannot find parent repo"; _update_self_exec_update; return }
        _rel=${_submod_root#${_parent}/}

        local _mode
        zstyle -s ':dotfiler:update' in-tree-commit _mode 2>/dev/null || _mode="auto"

        if (( _dry_run )); then
            info "update_self: [dry-run] would: git -C $_parent submodule update --remote -- $_rel"
        else
            git -C "$_parent" submodule update --remote -- "$_rel" \
                || warn "update_self: submodule update failed — continuing"
            _update_core_commit_parent \
                "$_parent" "$_rel" \
                "dotfiler submodule updated" \
                "dotfiler: update scripts submodule" \
                "$_mode"
            _update_core_write_timestamp "$_self_stamp"
        fi
        _update_self_exec_update
        ;;

    # -----------------------------------------------------------------------
    subtree)
    # The scripts dir lives as a subtree prefix inside the user's dotfiles
    # repo.  Pull the subtree, optionally commit, then re-exec update.sh.
    # -----------------------------------------------------------------------
        local _parent _rel
        _parent=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) \
            || { warn "update_self: cannot find parent repo"; _update_self_exec_update; return }
        _rel=${script_dir:A#${_parent:A}/}

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
            git -C "$_parent" subtree pull \
                --prefix="$_rel" "$_remote" "$_branch" --squash \
                || warn "update_self: subtree pull failed — continuing"
            _update_core_commit_parent \
                "$_parent" "$_rel" \
                "dotfiler subtree updated" \
                "dotfiler: update scripts subtree" \
                "$_mode"
            _update_core_write_timestamp "$_self_stamp"
        fi
        _update_self_exec_update
        ;;

    # -----------------------------------------------------------------------
    subdir)
    # Plain subdirectory — parent repo manages the scripts.  Self-update is a
    # no-op; exec update.sh directly.
    # -----------------------------------------------------------------------
        info "update_self: subdir topology — parent repo manages scripts, skipping self-update"
        _update_self_exec_update
        ;;

    # -----------------------------------------------------------------------
    none|*)
    # Not inside a git repo at all.  Just exec update.sh.
    # -----------------------------------------------------------------------
        warn "update_self: scripts directory is not a git repo — skipping self-update"
        _update_self_exec_update
        ;;
esac
