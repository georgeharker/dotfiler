#!/bin/zsh

# update_core.sh — shared update primitives for dotfiler and zdot
#
# All functions take explicit _repo_dir arguments rather than relying on
# ambient globals.  Callers (check_update.sh, update.sh, update.zsh) read
# zstyle values and pass resolved strings/bools as arguments.
#
# Logging: uses dotfiler's logging.sh macros (info, warn, error, action,
# report, verbose).  When sourced by zdot's update.zsh, a thin shim must be
# installed first that aliases those names to zdot_info / zdot_warn.
#
# Return-value convention:
#   Most functions that produce a single string value write it to stdout
#   (print -n) so callers can capture with $(...).  Functions that return a
#   status code document the values inline.

# ---------------------------------------------------------------------------
# Epoch
# ---------------------------------------------------------------------------

_update_core_current_epoch() {
    zmodload zsh/datetime 2>/dev/null
    print -n $EPOCHSECONDS
}

# ---------------------------------------------------------------------------
# Remote / branch detection
# ---------------------------------------------------------------------------

# _update_core_get_default_remote <repo_dir>
# Prints the tracking remote for the current branch, falling back to 'origin'.
_update_core_get_default_remote() {
    local _repo_dir=$1
    local _branch _upstream
    _branch=$(git -C "$_repo_dir" branch --show-current 2>/dev/null)
    if [[ -n "$_branch" ]]; then
        _upstream=$(git -C "$_repo_dir" config --get "branch.${_branch}.remote" 2>/dev/null)
    fi
    if [[ -z "$_upstream" ]]; then
        _upstream=$(git -C "$_repo_dir" remote 2>/dev/null | head -n1)
    fi
    print -n "${_upstream:-origin}"
}

# _update_core_get_default_branch <repo_dir> <remote>
# Prints the default branch name for <remote>.  Tries symbolic-ref, then
# `git remote show`, then falls back to main/master.
_update_core_get_default_branch() {
    local _repo_dir=$1 _remote=${2:-origin}
    local _branch _line _remote_output

    _branch=$(git -C "$_repo_dir" symbolic-ref \
        "refs/remotes/${_remote}/HEAD" 2>/dev/null)
    _branch=${_branch#refs/remotes/${_remote}/}

    if [[ -z "$_branch" ]]; then
        _remote_output=$(git -C "$_repo_dir" remote show "$_remote" 2>/dev/null)
        for _line in ${(f)_remote_output}; do
            if [[ "$_line" == *"HEAD branch:"* ]]; then
                _branch="${${_line#*: }// /}"
                break
            fi
        done
    fi

    if [[ -z "$_branch" ]]; then
        local _b
        for _b in main master; do
            git -C "$_repo_dir" show-ref --verify --quiet \
                "refs/remotes/${_remote}/${_b}" 2>/dev/null && {
                _branch=$_b; break
            }
        done
    fi

    print -n "${_branch:-main}"
}

# ---------------------------------------------------------------------------
# Stdin guard
# ---------------------------------------------------------------------------

# _update_core_has_typed_input
# Returns 0 if stdin has buffered (typed) input, 1 if stdin is clear.
# Follows the technique from Philippe Troin: https://zsh.org/mla/users/2022/msg00062.html
_update_core_has_typed_input() {
    emulate -L zsh
    zmodload zsh/zselect 2>/dev/null || return 1
    local _saved
    _saved=$(stty --save 2>/dev/null) || return 1
    {
        stty -icanon
        zselect -t 0 -r 0
        return $?
    } always {
        stty $_saved
    }
}

# ---------------------------------------------------------------------------
# Lock management
# ---------------------------------------------------------------------------

# _update_core_acquire_lock <lock_dir>
# Creates <lock_dir> atomically.  If the directory already exists and is
# older than 24 h, removes and recreates it (stale lock recovery).
# Returns 0 on success, 1 if the lock is held by another process.
_update_core_acquire_lock() {
    local _lock=$1
    mkdir -p "${_lock:h}" 2>/dev/null
    if mkdir "$_lock" 2>/dev/null; then
        return 0
    fi
    # Stale lock: remove if older than 24 h
    zmodload zsh/stat 2>/dev/null
    zmodload zsh/datetime 2>/dev/null
    local _mtime
    _mtime=$(zstat +mtime "$_lock" 2>/dev/null) || _mtime=0
    if (( EPOCHSECONDS - _mtime > 86400 )); then
        rm -rf "$_lock" && mkdir "$_lock" 2>/dev/null && return 0
    fi
    return 1
}

# _update_core_release_lock <lock_dir>
# Removes <lock_dir>.  Always returns 0.
_update_core_release_lock() {
    rmdir "$1" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# Timestamp file
# ---------------------------------------------------------------------------

# _update_core_write_timestamp <ts_file> [exit_status [error]]
# Writes LAST_EPOCH (always), EXIT_STATUS and ERROR (when provided and
# non-zero/non-empty).  Creates parent directory if needed.
# Always returns 0; a failed write is warned but never poisons the caller's $?.
_update_core_write_timestamp() {
    local _ts=$1 _exit_status=${2:-} _error=${3:-}
    mkdir -p "${_ts:h}" 2>/dev/null
    {
        print "LAST_EPOCH=$(_update_core_current_epoch)"
        if [[ -n "$_exit_status" && "$_exit_status" != 0 ]]; then
            print "EXIT_STATUS=$_exit_status"
        fi
        if [[ -n "$_error" ]]; then
            print "ERROR=${_error//\'/\'}"
        fi
    } >| "$_ts" || {
        print "update_core: warning: failed to write timestamp file: $_ts" >&2
    }
    return 0
}

# ---------------------------------------------------------------------------
# Update availability check (no GitHub API fallback — stays in check_update.sh)
# ---------------------------------------------------------------------------

# _update_core_is_available_fetch <repo_dir>
# Returns 0 if an update is available, 1 if up to date, 2 on fetch/parse error.
_update_core_is_available_fetch() {
    local _repo_dir=$1
    local _remote _branch _local_sha _remote_sha
    _remote=$(_update_core_get_default_remote "$_repo_dir")
    _branch=$(_update_core_get_default_branch "$_repo_dir" "$_remote")
    git -C "$_repo_dir" fetch "$_remote" "$_branch" --quiet 2>/dev/null || return 2
    _local_sha=$(git -C "$_repo_dir" rev-parse HEAD 2>/dev/null) || return 2
    _remote_sha=$(git -C "$_repo_dir" rev-parse "${_remote}/${_branch}" 2>/dev/null) || return 2
    [[ "$_local_sha" != "$_remote_sha" ]] && return 0
    return 1
}

# ---------------------------------------------------------------------------
# Submodule path helpers
# ---------------------------------------------------------------------------

# _update_core_list_submodule_paths <repo_dir>
# Sets the zsh array `reply` to the list of submodule paths registered in
# <repo_dir>/.gitmodules.  Returns 0 if at least one path was found, 1 if
# .gitmodules is absent or empty.
_update_core_list_submodule_paths() {
    local _repo_dir=$1
    local _line
    reply=()
    while IFS= read -r _line; do
        reply+=( "${_line##* }" )
    done < <(git -C "$_repo_dir" config --file=.gitmodules \
        --get-regexp '^submodule\..*\.path$' 2>/dev/null)
    [[ ${#reply} -gt 0 ]]
}

# ---------------------------------------------------------------------------
# Parent root helper
# ---------------------------------------------------------------------------

# _update_core_get_parent_root <repo_dir>
# Resolves the effective parent repo root for <repo_dir>.
# Always returns 0.  Sets reply[] array:
#   reply[1] — absolute path of the parent root (empty string if not in any git repo)
#   reply[2] — one of:
#                superproject  — <repo_dir> is a registered git submodule
#                toplevel      — no superproject; reply[1] is git --show-toplevel root
#                none          — not inside any git repo
#
# Always prefer --show-superproject-working-tree over --show-toplevel for
# submodule detection: inside a submodule, --show-toplevel returns the
# submodule's own root, making it indistinguishable from a standalone repo.
_update_core_get_parent_root() {
    local _repo_dir=$1
    local _root
    reply=()

    _root=$(git -C "$_repo_dir" rev-parse --show-superproject-working-tree 2>/dev/null)
    if [[ -n "$_root" ]]; then
        reply=( ${_root:A} superproject ); return 0
    fi

    _root=$(git -C "$_repo_dir" rev-parse --show-toplevel 2>/dev/null) || {
        reply=( "" none ); return 0
    }
    reply=( ${_root:A} toplevel ); return 0
}


# Sets REPLY to: standalone | submodule | subtree | subdir | none
# <subtree_remote_val> is the resolved value of the caller's subtree-remote
# zstyle (empty string if unset); the function never calls zstyle itself.
_update_core_detect_deployment() {
    local _repo_dir=$1 _subtree_remote_val=${2:-}
    local _repo_real _parent_real _rel

    _repo_real=${_repo_dir:A}

    _update_core_get_parent_root "$_repo_dir"
    local _kind=${reply[2]} _parent_real=${reply[1]}

    if [[ "$_kind" == none ]]; then
        REPLY=none; return 0
    fi

    if [[ "$_kind" == superproject ]]; then
        # superproject found — repo_dir is a submodule; verify via .gitmodules
        _rel=${_repo_real#${_parent_real}/}
        _update_core_list_submodule_paths "$_parent_real"
        local _gm_path
        for _gm_path in "${reply[@]}"; do
            [[ "$_gm_path" == "$_rel" ]] && { REPLY=submodule; return 0; }
        done
        # Superproject exists but path not in .gitmodules — treat as subdir
        REPLY=subdir; return 0
    fi

    # toplevel: no superproject; _parent_real is the --show-toplevel root
    if [[ "$_repo_real" == "$_parent_real" ]]; then
        REPLY=standalone; return 0
    fi

    # repo_dir is inside a parent repo (subtree or plain subdir)
    _rel=${_repo_real#${_parent_real}/}
    [[ -n "$_subtree_remote_val" ]] && { REPLY=subtree; return 0; }
    REPLY=subdir; return 0
}

# ---------------------------------------------------------------------------
# SHA marker helpers  –  persistent last-updated SHA for subtree deployments
# ---------------------------------------------------------------------------
# When a project is deployed as a git-subtree, the parent repo's HEAD has no
# relationship to the subtree source repo's commit history.  We maintain a
# small marker file *adjacent to* the subtree directory (not inside it) that
# records the last-known remote SHA we successfully pulled.
#
# The marker file name is derived from the subtree directory's basename so
# that multiple subtrees under the same parent do not collide:
#
# Example layout:
#   dotfiles/                        ← parent repo root
#   ├── .nounpack/
#   │   ├── .dotfiler-subtree-sha    ← marker for dotfiler subtree
#   │   └── dotfiler/                ← dotfiler subtree prefix
#   │       └── ...
#   ├── .config/
#   │   ├── .zdot-subtree-sha        ← marker for zdot subtree
#   │   └── zdot/                    ← zdot subtree prefix
#   │       └── ...
#
# When zstyle ':<project>:update' in-tree-commit is active, the marker is
# included in the parent-repo commit so the state is tracked in version
# control.

# _update_core_sha_marker_path <subtree_dir>
# Sets REPLY to the absolute path of the marker file for the given subtree.
# The marker is placed in the subtree's parent directory with a name derived
# from the subtree directory's basename: .<basename>-subtree-sha
_update_core_sha_marker_path() {
    local _subtree_dir=${1:?subtree directory required}
    local _basename=${_subtree_dir:A:t}
    REPLY="${_subtree_dir:A:h}/.${_basename}-subtree-sha"
}

# _update_core_read_sha_marker <subtree_dir>
# Reads the stored SHA marker into REPLY.  Returns 0 on success, 1 if no
# marker exists or is empty.
_update_core_read_sha_marker() {
    local _subtree_dir=${1:?subtree directory required}
    _update_core_sha_marker_path "$_subtree_dir"
    local _path=$REPLY
    if [[ -r "$_path" ]]; then
        REPLY="$(<"$_path")"
        REPLY="${REPLY%%$'\n'}"          # strip trailing newline
        [[ -n "$REPLY" ]] && return 0
    fi
    REPLY=""
    return 1
}

# _update_core_write_sha_marker <subtree_dir> <sha>
# Persists <sha> as the last-updated marker for the subtree.
# Returns 0 on success, 1 on write failure.
_update_core_write_sha_marker() {
    local _subtree_dir=${1:?subtree directory required}
    local _sha=${2:?sha required}
    _update_core_sha_marker_path "$_subtree_dir"
    local _path=$REPLY
    if printf '%s\n' "$_sha" > "$_path" 2>/dev/null; then
        return 0
    fi
    return 1
}

# _update_core_resolve_remote_sha <remote_url> <branch>
# Fetches the HEAD SHA for <branch> from <remote_url>.
# Prints the SHA to stdout.  Returns 0 on success, 1 on failure.
# Tries the GitHub API first (lightweight), then falls back to git ls-remote.
_update_core_resolve_remote_sha() {
    local _remote_url=$1 _branch=${2:-main}
    local _sha="" _repo=""

    # --- GitHub API path ---
    case "$_remote_url" in
        https://github.com/*) _repo=${${_remote_url#https://github.com/}%.git} ;;
        git@github.com:*)     _repo=${${_remote_url#git@github.com:}%.git} ;;
    esac

    if [[ -n "$_repo" ]]; then
        local _api_url="https://api.github.com/repos/${_repo}/commits/${_branch}"
        local _curl_auth=() _wget_auth=()
        if [[ -n "$GH_TOKEN" ]]; then
            _curl_auth=(-H "Authorization: Bearer ${GH_TOKEN}")
            _wget_auth=(--header="Authorization: Bearer ${GH_TOKEN}")
        fi

        _sha=$(
            if (( ${+commands[curl]} )); then
                curl --connect-timeout 10 --max-time 30 -fsSL \
                    -H 'Accept: application/vnd.github.v3.sha' \
                    "${_curl_auth[@]}" "$_api_url" 2>/dev/null
            elif (( ${+commands[wget]} )); then
                wget --timeout=30 -O- \
                    --header='Accept: application/vnd.github.v3.sha' \
                    "${_wget_auth[@]}" "$_api_url" 2>/dev/null
            fi
        )
        if [[ -n "$_sha" ]]; then
            printf '%s' "$_sha"
            return 0
        fi
    fi

    # --- Fallback: git ls-remote ---
    _sha=$(git ls-remote "$_remote_url" "$_branch" 2>/dev/null | awk '{print $1}')
    if [[ -n "$_sha" ]]; then
        printf '%s' "$_sha"
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# Foreign staged content check
# ---------------------------------------------------------------------------

# _update_core_check_foreign_staged <parent_dir> <rel>
# Returns 0 if safe (no staged changes outside <rel>), 1 if foreign staged
# changes exist that would be swept into an auto-commit.
_update_core_check_foreign_staged() {
    local _parent=$1 _rel=$2
    local -a _staged
    _staged=( ${(f)"$(git -C "$_parent" diff --cached --name-only 2>/dev/null)"} )
    [[ ${#_staged} -eq 0 ]] && return 0
    # Also allow the SHA marker file that update_core itself stages alongside the subtree.
    local _marker="${_rel:h}/.${_rel:t}-subtree-sha"
    local _f
    for _f in "${_staged[@]}"; do
        [[ "$_f" != "${_rel}/"* && "$_f" != "$_rel" && "$_f" != "$_marker" ]] && return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# Parent-repo commit handling
# ---------------------------------------------------------------------------

# _update_core_commit_parent <parent_dir> <rel> <label> <commit_msg> <mode>
# <mode> is one of: auto | prompt | none
# Handles staged-content guard and user prompting.  On blocked auto-commit,
# warns and proceeds without committing (user is told to commit manually).
_update_core_commit_parent() {
    local _parent=$1 _rel=$2 _label=$3 _commit_msg=$4 _mode=${5:-none}
    case $_mode in
        auto)
            if ! _update_core_check_foreign_staged "$_parent" "$_rel"; then
                warn "update_core: foreign staged changes in parent repo — skipping auto-commit (${_label})"
                warn "update_core: commit manually: git -C ${_parent} add ${_rel} && git -C ${_parent} commit"
                return 0
            fi
            git -C "$_parent" add "$_rel" \
                && git -C "$_parent" commit -m "$_commit_msg"
            ;;
        prompt)
            _update_core_has_typed_input && return 0
            if ! _update_core_check_foreign_staged "$_parent" "$_rel"; then
                warn "update_core: foreign staged changes in parent repo — skipping commit (${_label})"
                return 0
            fi
            print -n "update_core: ${_label} — commit in parent repo? [y/N] "
            local _ans
            read -r -k1 _ans; print ""
            if [[ "$_ans" == (y|Y) ]]; then
                git -C "$_parent" add "$_rel" \
                    && git -C "$_parent" commit -m "$_commit_msg"
            fi
            ;;
        none|*)
            info "update_core: ${_label} — parent repo is dirty (commit manually)"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Timestamp-gated update decision
# ---------------------------------------------------------------------------

# _update_core_should_update <stamp_file> <frequency_seconds> <force>
# Returns 0 if the caller should proceed with an update attempt, 1 to skip.
#
# Logic:
#   - <force> == "true"  → always return 0
#   - stamp file missing or LAST_EPOCH empty → write initial stamp, return 1
#     (first-run: record the time but don't update immediately)
#   - (now - LAST_EPOCH) >= frequency_seconds → return 0
#   - otherwise → return 1
_update_core_should_update() {
    local _stamp=$1 _freq=${2:-3600} _force=${3:-}
    [[ "$_force" == "true" ]] && return 0

    local LAST_EPOCH
    if ! source "$_stamp" 2>/dev/null || [[ -z "$LAST_EPOCH" ]]; then
        _update_core_write_timestamp "$_stamp"
        return 1
    fi

    zmodload zsh/datetime 2>/dev/null
    (( ( EPOCHSECONDS - LAST_EPOCH ) >= _freq )) && return 0
    return 1
}

# ---------------------------------------------------------------------------
# Update availability — API-first (ohmyzsh pattern)
# ---------------------------------------------------------------------------

# _update_core_is_available <repo_dir> [<remote_url_override>]
# Returns:
#   0 — update is available
#   1 — up to date or indeterminate (skip — conservative)
#
# For GitHub remotes: calls the GitHub API only (no git fetch).
# On API failure returns 1 (conservative skip — do not assume update available).
# For non-GitHub remotes: falls back to _update_core_is_available_fetch (git fetch).
# <remote_url_override>: if non-empty, used instead of reading git config.
_update_core_is_available() {
    local _repo_dir=$1 _remote_url_override=${2:-}
    local _remote _branch _remote_url

    _remote=$(_update_core_get_default_remote "$_repo_dir")
    _branch=$(_update_core_get_default_branch "$_repo_dir" "$_remote")

    if [[ -n "$_remote_url_override" ]]; then
        _remote_url=$_remote_url_override
    else
        _remote_url=$(git -C "$_repo_dir" config "remote.${_remote}.url" 2>/dev/null) || {
            _update_core_is_available_fetch "$_repo_dir"
            return $?
        }
    fi

    # --- GitHub API path (API-first, no git fetch) ---
    local _repo
    case "$_remote_url" in
        https://github.com/*) _repo=${${_remote_url#https://github.com/}%.git} ;;
        git@github.com:*)     _repo=${${_remote_url#git@github.com:}%.git} ;;
        *)                    _repo="" ;;
    esac

    if [[ -n "$_repo" ]]; then
        local _api_url="https://api.github.com/repos/${_repo}/commits/${_branch}"
        local _local_head _remote_head

        # Get local HEAD for the tracked branch
        _local_head=$(git -C "$_repo_dir" rev-parse "$_branch" 2>/dev/null) || return 0

        # Call GitHub API — on failure, skip update (conservative, per ohmyzsh pattern)
        local _curl_auth=() _wget_auth=()
        if [[ -n "$GH_TOKEN" ]]; then
            _curl_auth=(-H "Authorization: Bearer ${GH_TOKEN}")
            _wget_auth=(--header="Authorization: Bearer ${GH_TOKEN}")
        fi

        _remote_head=$(
            if (( ${+commands[curl]} )); then
                curl --connect-timeout 10 --max-time 30 -fsSL \
                    -H 'Accept: application/vnd.github.v3.sha' \
                    "${_curl_auth[@]}" "$_api_url" 2>/dev/null
            elif (( ${+commands[wget]} )); then
                wget --timeout=30 -O- \
                    --header='Accept: application/vnd.github.v3.sha' \
                    "${_wget_auth[@]}" "$_api_url" 2>/dev/null
            else
                exit 1
            fi
        ) || return 1   # API failure → skip (conservative)

        [[ -z "$_remote_head" ]] && return 1   # empty response → skip

        verbose "update_core: local=${_local_head:0:8} remote(API)=${_remote_head:0:8}"

        # If SHAs match → up to date
        [[ "$_local_head" == "$_remote_head" ]] && return 1

        # Use merge-base to confirm local is behind (not just diverged)
        local _base
        _base=$(git -C "$_repo_dir" merge-base "$_local_head" "$_remote_head" 2>/dev/null) \
            || return 0   # merge-base failed → assume update available
        [[ "$_base" != "$_remote_head" ]]   # 0 if local is behind, 1 if ahead/diverged
        return $?
    fi

    # --- Non-GitHub remote: fall back to git fetch ---
    _update_core_is_available_fetch "$_repo_dir"
    return $?
}

# ---------------------------------------------------------------------------
# Subtree-aware update availability check
# ---------------------------------------------------------------------------

# _update_core_is_available_subtree <subtree_dir> <remote_url> <branch>
# Returns:
#   0 — update is available
#   1 — up to date or indeterminate (skip — conservative)
#
# For subtree deployments, the parent repo's HEAD/branch SHAs have no
# relationship to the subtree source repo's commit history.  Instead of
# rev-parse on a local branch, we compare the remote SHA against a cached
# marker file that records the last-known SHA after a successful subtree pull.
#
# If no marker exists (first run or migration), we assume an update is
# available to bootstrap the marker.
_update_core_is_available_subtree() {
    local _subtree_dir=$1 _remote_url=$2 _branch=${3:-main}
    local _local_head _remote_head

    # Read the cached SHA from the marker file adjacent to the subtree
    if _update_core_read_sha_marker "$_subtree_dir"; then
        _local_head=$REPLY
    else
        # No marker → first run; assume update available to bootstrap
        verbose "update_core: no subtree SHA marker found — assuming update available"
        return 0
    fi

    # --- GitHub API path (API-first, no git fetch) ---
    local _repo
    case "$_remote_url" in
        https://github.com/*) _repo=${${_remote_url#https://github.com/}%.git} ;;
        git@github.com:*)     _repo=${${_remote_url#git@github.com:}%.git} ;;
        *)                    _repo="" ;;
    esac

    if [[ -n "$_repo" ]]; then
        local _api_url="https://api.github.com/repos/${_repo}/commits/${_branch}"

        local _curl_auth=() _wget_auth=()
        if [[ -n "$GH_TOKEN" ]]; then
            _curl_auth=(-H "Authorization: Bearer ${GH_TOKEN}")
            _wget_auth=(--header="Authorization: Bearer ${GH_TOKEN}")
        fi

        _remote_head=$(
            if (( ${+commands[curl]} )); then
                curl --connect-timeout 10 --max-time 30 -fsSL \
                    -H 'Accept: application/vnd.github.v3.sha' \
                    "${_curl_auth[@]}" "$_api_url" 2>/dev/null
            elif (( ${+commands[wget]} )); then
                wget --timeout=30 -O- \
                    --header='Accept: application/vnd.github.v3.sha' \
                    "${_wget_auth[@]}" "$_api_url" 2>/dev/null
            else
                exit 1
            fi
        ) || return 1   # API failure → skip (conservative)

        [[ -z "$_remote_head" ]] && return 1   # empty response → skip

        verbose "update_core: subtree marker=${_local_head:0:8} remote(API)=${_remote_head:0:8}"

        # Simple equality check — no merge-base (parent repo has no
        # knowledge of the subtree source history)
        [[ "$_local_head" == "$_remote_head" ]] && return 1
        return 0
    fi

    # --- Non-GitHub remote: fall back to git ls-remote ---
    _remote_head=$(git ls-remote "$_remote_url" "$_branch" 2>/dev/null | awk '{print $1}')
    [[ -z "$_remote_head" ]] && return 1   # ls-remote failed → skip

    verbose "update_core: subtree marker=${_local_head:0:8} remote(ls-remote)=${_remote_head:0:8}"

    [[ "$_local_head" == "$_remote_head" ]] && return 1
    return 0
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

# _update_core_cleanup
# Unsets all private _update_core_* helper functions defined in this file.
# Callers (update.sh, update.zsh) invoke this after sourcing and using the
# helpers so the functions do not leak into the caller's namespace.
# Self-unsets last.
_update_core_cleanup() {
    unset -f \
        _update_core_current_epoch \
        _update_core_get_default_remote \
        _update_core_get_default_branch \
        _update_core_has_typed_input \
        _update_core_acquire_lock \
        _update_core_release_lock \
        _update_core_write_timestamp \
        _update_core_is_available \
        _update_core_is_available_fetch \
        _update_core_is_available_subtree \
        _update_core_get_parent_root \
        _update_core_list_submodule_paths \
        _update_core_resolve_remote_sha \
        _update_core_should_update \
        _update_core_detect_deployment \
        _update_core_check_foreign_staged \
        _update_core_commit_parent \
        _update_core_sha_marker_path \
        _update_core_read_sha_marker \
        _update_core_write_sha_marker \
        2>/dev/null
    unset -f _update_core_cleanup 2>/dev/null
}
