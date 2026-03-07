#!/bin/zsh

# update_core.zsh — shared update primitives for dotfiler and zdot
#
# All functions take explicit _repo_dir arguments rather than relying on
# ambient globals.  Callers (check_update.zsh, update.zsh) read
# zstyle values and pass resolved strings/bools as arguments.
#
# Logging: uses dotfiler's logging.zsh macros (info, warn, error, action,
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
    # stty -g is POSIX; stty --save is GNU/Linux only and fails on macOS.
    _saved=$(stty -g 2>/dev/null) || return 1
    {
        stty -icanon
        zselect -t 0 -r 0
        return $?
    } always {
        stty "$_saved"
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
    # Stale lock recovery: remove if older than 10 minutes.
    # 24h was too conservative — a crashed/killed run would block checks for a
    # full day.  Dotfiler update runs are expected to finish in well under a
    # minute, so 600 s is a safe threshold.
    zmodload zsh/stat 2>/dev/null
    zmodload zsh/datetime 2>/dev/null
    local _mtime _age
    _mtime=$(zstat +mtime "$_lock" 2>/dev/null) || _mtime=0
    _age=$(( EPOCHSECONDS - _mtime ))
    log_debug "update_core: lock ${_lock} held (age ${_age}s)"
    if (( _age > 600 )); then
        log_debug "update_core: stale lock (>${_age}s) — removing and retaking"
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
        # Write EXIT_STATUS whenever it is explicitly provided (including 0 for
        # background success signalling — callers that only update the epoch omit arg 2).
        if [[ -n "$_exit_status" ]]; then
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
# Update availability check (no GitHub API fallback — stays in check_update.zsh)
# ---------------------------------------------------------------------------

# _update_core_is_available_fetch <repo_dir> [allow_diverged]
# Returns 0 if an update is available (local is behind, or diverged and
# allow_diverged=1), 1 to skip (up to date or local is ahead), 2 on error.
# When diverged and allow_diverged is unset/0, warns and returns 1.
_update_core_is_available_fetch() {
    local _repo_dir=$1 _allow_diverged=${2:-0}
    local _remote _branch _local_sha _remote_sha _base
    _remote=$(_update_core_get_default_remote "$_repo_dir")
    _branch=$(_update_core_get_default_branch "$_repo_dir" "$_remote")
    git -C "$_repo_dir" fetch "$_remote" "$_branch" --quiet 2>/dev/null || return 2
    _local_sha=$(git -C "$_repo_dir" rev-parse HEAD 2>/dev/null) || return 2
    _remote_sha=$(git -C "$_repo_dir" rev-parse "${_remote}/${_branch}" 2>/dev/null) || return 2
    [[ "$_local_sha" == "$_remote_sha" ]] && return 1   # up to date
    _base=$(git -C "$_repo_dir" merge-base "$_local_sha" "$_remote_sha" 2>/dev/null) \
        || return 2   # merge-base failed — can't determine relationship
    if [[ "$_base" == "$_remote_sha" ]]; then
        # Local is strictly ahead of remote — nothing new to pull.
        log_debug "update_core(fetch): local is ahead of remote — no update available"
        return 1
    elif [[ "$_base" == "$_local_sha" ]]; then
        return 0   # local is behind remote — update available
    else
        # Diverged: local and remote have independent commits.
        if (( _allow_diverged )); then
            warn "update_core: '${_repo_dir:t}' has diverged from ${_remote}/${_branch} — proceeding (merge may result)"
            return 0
        else
            warn "update_core: '${_repo_dir:t}' has diverged from ${_remote}/${_branch} — skipping (resolve manually or use prompt mode)"
            return 1
        fi
    fi
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
# Dirty repo check + stash helpers
# ---------------------------------------------------------------------------

# _update_core_check_dirty <repo_dir>
# Returns 0 if clean, 1 if dirty.
_update_core_check_dirty() {
    local _dir=$1
    git -C "$_dir" diff --quiet 2>/dev/null \
        && git -C "$_dir" diff --cached --quiet 2>/dev/null
}

# _update_core_prompt_dirty <repo_dir> <label>
# If repo is dirty, warns the user that the merge won't work.
# Prompts whether to stash. Returns 0 if clean or user consented
# to stash, 1 to abort. Does NOT stash — caller decides how.
_update_core_prompt_dirty() {
    local _dir=$1 _label=${2:-update}

    _update_core_check_dirty "$_dir" && return 0

    verbose "update_core: ${_label}: repo ${_dir} is dirty"

    if _update_core_has_typed_input; then
        warn "update_core: ${_label}: repo is dirty — merge will fail"
        warn "update_core: stash or commit changes manually before updating"
        return 1
    fi

    print -n "update_core: ${_label}: repo has uncommitted changes — merge will fail. Stash and continue? [y/N] "
    local _ans
    read -r -k1 _ans; print ""
    if [[ "$_ans" != [yY] ]]; then
        warn "update_core: ${_label}: skipping (dirty repo)"
        return 1
    fi
    warn "update_core: ${_label}: stashing — note: if merge fails your changes will remain stashed"
    warn "update_core: ${_label}: recover with: git -C ${_dir} stash pop"
    return 0
}

# _update_core_maybe_stash / _update_core_pop_stash — see below.

# _update_core_maybe_stash <repo_dir> <label>
# If dirty, prompts the user. On consent, stashes.
# Sets REPLY=1 if a stash was created, REPLY=0 if not.
# Returns 0 to proceed, 1 to abort.
_update_core_maybe_stash() {
    local _dir=$1 _label=${2:-update}
    REPLY=0

    _update_core_check_dirty "$_dir" && return 0

    verbose "update_core: ${_label}: repo ${_dir} is dirty"

    if _update_core_has_typed_input; then
        warn "update_core: ${_label}: repo is dirty — cannot prompt, skipping update"
        warn "update_core: stash or commit changes manually before updating"
        return 1
    fi

    print -n "update_core: ${_label}: repo has uncommitted changes. Stash and continue? [y/N] "
    local _ans
    read -r -k1 _ans; print ""
    [[ "$_ans" != [yY] ]] && { warn "update_core: ${_label}: skipping (dirty repo)"; return 1; }

    log_debug "update_core: ${_label}: stashing in ${_dir}"
    git -C "$_dir" stash push -q -m "dotfiler: stash before ${_label}" || {
        warn "update_core: ${_label}: git stash failed — skipping"
        return 1
    }
    REPLY=1
    return 0
}

# _update_core_pop_stash <repo_dir> <label>
# Pops the stash in <repo_dir>. Only call if _update_core_maybe_stash set REPLY=1.
_update_core_pop_stash() {
    local _dir=$1 _label=${2:-update}
    log_debug "update_core: ${_label}: popping stash in ${_dir}"
    git -C "$_dir" stash pop -q || {
        warn "update_core: ${_label}: stash pop had conflicts — resolve manually"
        warn "update_core: run: git -C ${_dir} stash pop"
    }
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
            git -C "$_parent" add "$_rel" 2>/dev/null
            if git -C "$_parent" diff --cached --quiet 2>/dev/null; then
                log_debug "update_core: nothing to commit in parent (${_label})"
            else
                git -C "$_parent" commit -q -m "$_commit_msg"
            fi
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
                git -C "$_parent" add "$_rel" 2>/dev/null
                if git -C "$_parent" diff --cached --quiet 2>/dev/null; then
                    log_debug "update_core: nothing to commit in parent (${_label})"
                else
                    git -C "$_parent" commit -q -m "$_commit_msg"
                fi
            fi
            ;;
        none|*)
            info "update_core: ${_label} — parent repo is dirty (commit manually)"
            return 0
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
# _update_core_is_available <repo_dir> [remote_url_override] [allow_diverged]
# Returns:
#   0 — update is available (local is behind, or diverged with allow_diverged=1)
#   1 — up to date, local is ahead, or diverged with allow_diverged=0 (skip)
#
# For GitHub remotes: calls the GitHub API only (no git fetch).
# On API failure returns 1 (conservative skip — do not assume update available).
# For non-GitHub remotes: falls back to _update_core_is_available_fetch (git fetch).
# <remote_url_override>: if non-empty, used instead of reading git config.
# <allow_diverged>: 1 = warn and proceed on diverged; 0 = warn and skip (default).
_update_core_is_available() {
    local _repo_dir=$1 _remote_url_override=${2:-} _allow_diverged=${3:-0}
    local _remote _branch _remote_url

    _remote=$(_update_core_get_default_remote "$_repo_dir")
    _branch=$(_update_core_get_default_branch "$_repo_dir" "$_remote")

    if [[ -n "$_remote_url_override" ]]; then
        _remote_url=$_remote_url_override
    else
        _remote_url=$(git -C "$_repo_dir" config "remote.${_remote}.url" 2>/dev/null) || {
            _update_core_is_available_fetch "$_repo_dir" "$_allow_diverged"
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

        # Use HEAD directly — rev-parse "$_branch" fails in detached-HEAD state
        # (e.g. freshly updated submodule), whereas HEAD always resolves.
        _local_head=$(git -C "$_repo_dir" rev-parse HEAD 2>/dev/null) || return 1

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

        log_debug "update_core: local=${_local_head:0:8} remote(API)=${_remote_head:0:8}"

        [[ "$_local_head" == "$_remote_head" ]] && return 1   # up to date

        # Three-way merge-base check: behind / ahead / diverged
        local _base
        _base=$(git -C "$_repo_dir" merge-base "$_local_head" "$_remote_head" 2>/dev/null) \
            || return 0   # merge-base failed — assume update available
        if [[ "$_base" == "$_remote_head" ]]; then
            # Local is strictly ahead of remote — nothing new to pull.
            log_debug "update_core: local is ahead of remote — no update available"
            return 1
        elif [[ "$_base" == "$_local_head" ]]; then
            return 0   # local is behind — update available
        else
            # Diverged
            if (( _allow_diverged )); then
                warn "update_core: '${_repo_dir:t}' has diverged from ${_remote}/${_branch} — proceeding (merge may result)"
                return 0
            else
                warn "update_core: '${_repo_dir:t}' has diverged from ${_remote}/${_branch} — skipping (resolve manually or use prompt mode)"
                return 1
            fi
        fi
    fi

    # --- Non-GitHub remote: fall back to git fetch ---
    _update_core_is_available_fetch "$_repo_dir" "$_allow_diverged"
    return $?
}

# ---------------------------------------------------------------------------
# Subtree-aware update availability check
# ---------------------------------------------------------------------------

# _update_core_get_dotfiler_subtree_config
# Single source of truth for the dotfiler subtree remote spec and URL.
# Reads zstyles ':dotfiler:update' subtree-remote and subtree-url,
# falling back to the canonical defaults.
# Sets reply=( subtree_spec subtree_url ).
_update_core_get_dotfiler_subtree_config() {
    local _spec _url
    zstyle -s ':dotfiler:update' subtree-remote _spec 2>/dev/null \
        || _spec="dotfiler main"
    zstyle -s ':dotfiler:update' subtree-url _url 2>/dev/null \
        || _url="https://github.com/georgeharker/dotfiler.git"
    reply=( "$_spec" "$_url" )
}

# _update_core_get_in_tree_commit_mode <scope>
# Reads the in-tree-commit mode from zstyle scope, defaults to "auto".
# Valid values: auto, prompt, none. Sets REPLY.
_update_core_get_in_tree_commit_mode() {
    local _mode
    zstyle -s "${1}" in-tree-commit _mode 2>/dev/null || _mode="auto"
    REPLY=$_mode
}

# _update_core_get_update_frequency <scope>
# Reads the update check frequency (seconds) from zstyle scope.
# Defaults to UPDATE_DOTFILE_SECONDS or 3600. Sets REPLY.
_update_core_get_update_frequency() {
    local _freq
    zstyle -s "${1}" frequency _freq 2>/dev/null \
        || _freq=${UPDATE_DOTFILE_SECONDS:-3600}
    REPLY=$_freq
}

# _update_core_resolve_subtree_spec <repo_dir> <subtree_spec> [<remote_url>]
# <subtree_spec> is "<remote_name> [branch]".
# If <remote_url> is supplied and the remote is not yet registered in the repo,
# the remote is added automatically (bootstrapping a fresh clone).
# Sets reply=( remote branch remote_url ) and returns 0, or returns 1 on error.
_update_core_resolve_subtree_spec() {
    local _dir=$1 _spec=$2 _url_hint=${3:-}
    local _remote _branch _remote_url
    _remote="${_spec%% *}"
    _branch="${_spec#* }"
    [[ "$_branch" == "$_remote" ]] && _branch=""
    _remote_url=$(git -C "$_dir" config "remote.${_remote}.url" 2>/dev/null)
    # If the remote is missing but a URL hint was provided, register it now.
    if [[ -z "$_remote_url" && -n "$_url_hint" ]]; then
        git -C "$_dir" remote add "$_remote" "$_url_hint" 2>/dev/null \
            && git -C "$_dir" fetch "$_remote" 2>/dev/null \
            && _remote_url="$_url_hint"
    fi
    [[ -z "$_remote_url" ]] && return 1
    [[ -z "$_branch" ]] && \
        _branch=$(_update_core_get_default_branch "$_dir" "$_remote")
    reply=( "$_remote" "$_branch" "$_remote_url" )
    return 0
}

# _update_core_is_available_subtree <subtree_dir> <subtree_spec>
# <subtree_spec> is "<remote_name> [branch]" (same format as zstyle subtree-remote).
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
    local _subtree_dir=$1 _subtree_spec=$2 _url_hint=${3:-}
    _update_core_resolve_subtree_spec "$_subtree_dir" "$_subtree_spec" "$_url_hint" || return 1
    local _remote="$reply[1]" _branch="$reply[2]" _remote_url="$reply[3]"
    local _local_head _remote_head

    # Read the cached SHA from the marker file adjacent to the subtree
    if _update_core_read_sha_marker "$_subtree_dir"; then
        _local_head=$REPLY
    else
        # No marker → first run; assume update available to bootstrap
        log_debug "update_core: no subtree SHA marker found — assuming update available"
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

        log_debug "update_core: subtree marker=${_local_head:0:8} remote(API)=${_remote_head:0:8}"

        # Simple equality check — no merge-base (parent repo has no
        # knowledge of the subtree source history)
        [[ "$_local_head" == "$_remote_head" ]] && return 1
        return 0
    fi

    # --- Non-GitHub remote: fall back to git ls-remote ---
    _remote_head=$(git ls-remote "$_remote_url" "$_branch" 2>/dev/null | awk '{print $1}')
    [[ -z "$_remote_head" ]] && return 1   # ls-remote failed → skip

    log_debug "update_core: subtree marker=${_local_head:0:8} remote(ls-remote)=${_remote_head:0:8}"

    [[ "$_local_head" == "$_remote_head" ]] && return 1
    return 0
}

# ---------------------------------------------------------------------------
# File list builder (promoted from update.zsh for use by hooks)
# ---------------------------------------------------------------------------

# _update_core_build_file_lists <repo_dir> <diff_range>
# Walks commits in <diff_range> commit-by-commit (-m for merge awareness) and
# populates two *caller-declared* unique arrays:
#   _update_core_files_to_unpack  — files to add/update via setup.zsh
#   _update_core_files_to_remove  — deleted/renamed-away symlinks to remove
# The arrays must be declared (typeset -aU) by the caller before this call.
# Callers should copy them out immediately; they are overwritten on each call.
_update_core_build_file_lists() {
    local _repo_dir=$1 _diff_range=$2
    local _git_commits _line _hash _message _git_log
    local _update_type _file_refs

    _update_core_files_to_unpack=()
    _update_core_files_to_remove=()

    _git_commits=$(git -C "$_repo_dir" log --reverse -m \
        --diff-filter=ADMRC --no-decorate \
        --pretty=format:"%H%x09%s" \
        "${_diff_range}" 2>/dev/null)

    for _line in ${(f)_git_commits}; do
        _hash=${_line%%$'\t'*}
        _message=${_line#*$'\t'}
        log_debug "update_core: commit ${_hash[1,12]}: ${_message}"

        # Skip squashed subtree commits. git-subtree pull/add grafts a squash
        # commit into the dotfiles repo whose paths are relative to the subrepo
        # root, not the dotfiles root. The merge commit that follows already
        # captures these changes with fully-qualified dotfiles-relative paths
        # (when diffed against the main-line parent), so processing the squash
        # commit would produce spurious removes/unpacks with bare paths.
        # Squash commits are identified by both git-subtree-dir: and
        # git-subtree-split: trailers in the commit body (always present
        # together when using git subtree pull --squash).
        local _commit_body
        _commit_body=$(git -C "$_repo_dir" log -1 --format="%B" "$_hash" 2>/dev/null)
        if [[ "$_commit_body" == *$'\n''git-subtree-dir: '* && \
              "$_commit_body" == *$'\n''git-subtree-split: '* ]]; then
            log_debug "  skipping squashed subtree commit"
            continue
        fi

        _git_log=$(git -C "$_repo_dir" log -m --name-status \
            --diff-filter=ADMRC --no-decorate --pretty=format: \
            "${_hash}...${_hash}^" 2>/dev/null)

        for _line in ${(f)_git_log}; do
            [[ "$_line" =~ "^[ADMRC][0-9]*"$'\t'".*$" ]] || continue
            _update_type=${_line%%$'\t'*}
            _file_refs=${_line#*$'\t'}

            if [[ "$_update_type" == M ]]; then
                local _file=$_file_refs
                [[ -n "$_file" && "$_file" == .* && "$_file" != .nounpack/* ]] || continue
                log_debug "  $_file modified"
                _update_core_files_to_unpack+=("$_file")
                _update_core_files_to_remove=(${_update_core_files_to_remove:#"$_file"})

            elif [[ "$_update_type" == A ]]; then
                local _file=$_file_refs
                [[ -n "$_file" && "$_file" == .* && "$_file" != .nounpack/* ]] || continue
                log_debug "  $_file added"
                _update_core_files_to_unpack+=("$_file")
                _update_core_files_to_remove=(${_update_core_files_to_remove:#"$_file"})

            elif [[ "$_update_type" == C<-> ]]; then
                local _dst_file=${_file_refs#*$'\t'}
                [[ -n "$_dst_file" && "$_dst_file" == .* && "$_dst_file" != .nounpack/* ]] || continue
                log_debug "  $_dst_file copied"
                _update_core_files_to_remove=(${_update_core_files_to_remove:#"$_dst_file"})
                _update_core_files_to_unpack+=("$_dst_file")

            elif [[ "$_update_type" == R<-> ]]; then
                local _src_file=${_file_refs%%$'\t'*}
                local _dst_file=${_file_refs#*$'\t'}
                [[ -n "$_dst_file" ]] || continue
                log_debug "  $_dst_file renamed (from $_src_file)"
                _update_core_files_to_unpack=(${_update_core_files_to_unpack:#"$_src_file"})
                [[ "$_src_file" == .* && "$_src_file" != .nounpack/* ]] && \
                _update_core_files_to_remove+=("$_src_file")
                [[ "$_dst_file" == .* && "$_dst_file" != .nounpack/* ]] && \
                _update_core_files_to_unpack+=("$_dst_file")

            elif [[ "$_update_type" == D ]]; then
                local _file=$_file_refs
                [[ -n "$_file" && "$_file" == .* && "$_file" != .nounpack/* ]] || continue
                log_debug "  $_file deleted"
                _update_core_files_to_unpack=(${_update_core_files_to_unpack:#"$_file"})
                _update_core_files_to_remove+=("$_file")
            fi
        done
    done
}

# ---------------------------------------------------------------------------
# External (standalone) SHA marker
# ---------------------------------------------------------------------------
# Mirrors the subtree SHA marker pattern.
# Marker file lives adjacent to where the component dir would be, named
# .<basename>-ext-sha — tracked in the dotfiles repo so that any dotfiles
# commit range can be used to determine what external component SHA was
# in use at each end of the range.

# _update_core_ext_marker_path <component_dir>
# Sets REPLY to the path of the ext SHA marker file.
_update_core_ext_marker_path() {
    local _dir=${1:A}
    REPLY="${_dir:h}/.${_dir:t}-ext-sha"
}

# _update_core_read_ext_marker <component_dir>
# Sets REPLY to the SHA recorded in the ext marker file.
# Returns 0 on success, 1 if file missing or empty.
_update_core_read_ext_marker() {
    _update_core_ext_marker_path "$1"
    local _path="$REPLY" _sha
    [[ -f "$_path" ]] || return 1
    _sha=$(<"$_path")
    _sha="${_sha//[[:space:]]}"
    [[ -n "$_sha" ]] || return 1
    REPLY="$_sha"
}

# _update_core_write_ext_marker <component_dir> <sha>
# Writes <sha> to the ext marker file adjacent to <component_dir>.
_update_core_write_ext_marker() {
    _update_core_ext_marker_path "$1"
    local _path="$REPLY" _sha="$2"
    print -r -- "$_sha" >| "$_path"
}

# ---------------------------------------------------------------------------
# Component range resolution
# ---------------------------------------------------------------------------

# _update_core_resolve_component_range \
#     <dotfiles_dir> <old_sha> <new_sha> <component_dir> <topology>
#
# "What would the component have been if the dotfiles parent moved from
#  <old_sha> to <new_sha>?"
#
# Sets REPLY to "old_comp_sha..new_comp_sha", or "" if unresolvable.
# Returns 0 if a range was determined, 1 if not (caller falls back to
# independent fetch-based detection).
#
# Topology is passed explicitly — determined at hook registration time via
# _update_core_detect_deployment so all flows agree on the same value.
#
# Dispatch:
#   submodule  — git ls-tree at old/new for the component path
#   subtree    — git show old/new:<basename>-subtree-sha marker
#   standalone — git show old/new:<basename>-ext-sha marker
#   subdir     — component is part of dotfiles tree; not meaningful at
#                component granularity — returns 1
_update_core_resolve_component_range() {
    local _dotfiles_dir="$1"
    local _old_sha="$2"
    local _new_sha="$3"
    local _comp_dir="${4:A}"
    local _topology="$5"
    REPLY=""

    local _dotfiles_root="${_dotfiles_dir:A}"
    local _rel_path="${_comp_dir#${_dotfiles_root}/}"
    local _old_comp _new_comp

    case "$_topology" in
        submodule)
            _old_comp=$(git -C "$_dotfiles_dir" ls-tree "$_old_sha" -- "$_rel_path" \
                2>/dev/null | awk '{print $3}')
            _new_comp=$(git -C "$_dotfiles_dir" ls-tree "$_new_sha" -- "$_rel_path" \
                2>/dev/null | awk '{print $3}')
            ;;
        subtree)
            _update_core_sha_marker_path "$_comp_dir"
            local _marker_rel="${REPLY#${_dotfiles_root}/}"
            _old_comp=$(git -C "$_dotfiles_dir" show "${_old_sha}:${_marker_rel}" \
                2>/dev/null | tr -d '[:space:]')
            _new_comp=$(git -C "$_dotfiles_dir" show "${_new_sha}:${_marker_rel}" \
                2>/dev/null | tr -d '[:space:]')
            ;;
        standalone)
            _update_core_ext_marker_path "$_comp_dir"
            local _ext_marker_rel="${REPLY#${_dotfiles_root}/}"
            _old_comp=$(git -C "$_dotfiles_dir" show "${_old_sha}:${_ext_marker_rel}" \
                2>/dev/null | tr -d '[:space:]')
            _new_comp=$(git -C "$_dotfiles_dir" show "${_new_sha}:${_ext_marker_rel}" \
                2>/dev/null | tr -d '[:space:]')
            ;;
        subdir|*)
            # subdir: component is the dotfiles range — caller uses that directly
            # unknown: cannot resolve
            return 1
            ;;
    esac

    [[ -z "$_old_comp" || -z "$_new_comp" ]] && return 1
    [[ "$_old_comp" == "$_new_comp" ]] && return 1
    REPLY="${_old_comp}..${_new_comp}"
    return 0
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

# _update_core_cleanup
# Unsets all private _update_core_* helper functions defined in this file.
# Called by update.zsh (subprocess) after it has finished its update work.
# NOT called by update.zsh — those functions must persist as runtime
# dependencies of _zdot_update_handle_update (via _zdot_update_hook_*).
# Self-unsets last.
# ---------------------------------------------------------------------------
# Hook registry — shared between update.zsh and setup.zsh
# ---------------------------------------------------------------------------
#
# Each hook (component) registers itself with a name and a set of phase
# functions.  update.zsh drives check → plan → pull → unpack → post.
# setup.zsh drives the optional setup_fn for full unpack without an update.
#
#   _dotfiler_registered_hooks          — ordered array of hook names
#   _dotfiler_hook_check_fn[name]       — fn: 0=available 1=up-to-date 2=error
#   _dotfiler_hook_plan_fn[name]        — fn: populates _dotfiler_plan_<name>_*
#   _dotfiler_hook_pull_fn[name]        — fn: git operations only
#   _dotfiler_hook_unpack_fn[name]      — fn: setup_core.zsh after all pulls
#   _dotfiler_hook_post_fn[name]        — fn: commit parents, markers etc.
#   _dotfiler_hook_cleanup_fn[name]     — fn: unset hook impl fns (check mode)
#   _dotfiler_hook_component_dir[name]  — component repo dir (absolute path)
#   _dotfiler_hook_topology[name]       — standalone|submodule|subtree|subdir
#   _dotfiler_hook_setup_fn[name]       — fn: full-unpack for setup --all

function _update_core_init_registry() {
    typeset -ga  _dotfiler_registered_hooks
    typeset -gA  _dotfiler_hook_check_fn
    typeset -gA  _dotfiler_hook_plan_fn
    typeset -gA  _dotfiler_hook_pull_fn
    typeset -gA  _dotfiler_hook_unpack_fn
    typeset -gA  _dotfiler_hook_post_fn
    typeset -gA  _dotfiler_hook_cleanup_fn
    typeset -gA  _dotfiler_hook_component_dir
    typeset -gA  _dotfiler_hook_topology
    typeset -gA  _dotfiler_hook_setup_fn
}

# _update_register_hook \
#     <name> <check_fn> <plan_fn> <pull_fn> <unpack_fn> <post_fn> \
#     [cleanup_fn] [component_dir] [topology] [setup_fn]
#
# Called by each hook .zsh file when sourced.
#   cleanup_fn:    called by check_update.zsh after check_fns run.
#   component_dir + topology: used by dotfiler to resolve component ranges
#     from a dotfiles range without calling plan_fn first.
#   setup_fn:      called by setup.zsh --all for full unpack without a pull.
#     Receives a single argument: "unpack" or "force-unpack".
#     Hooks that omit this do not participate in dotfiler setup --all.
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
    _dotfiler_hook_setup_fn[$_name]=${10:-}
}

# ---------------------------------------------------------------------------

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
        _update_core_resolve_subtree_spec \
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
        _update_core_ext_marker_path \
        _update_core_read_ext_marker \
        _update_core_write_ext_marker \
        _update_core_resolve_component_range \
        _update_core_build_file_lists \
        _update_core_init_registry \
        _update_register_hook \
        2>/dev/null

    # Registry arrays — may not exist if _update_core_init_registry was never called
    unset _dotfiler_registered_hooks 2>/dev/null
    unset _dotfiler_hook_check_fn _dotfiler_hook_plan_fn \
          _dotfiler_hook_pull_fn _dotfiler_hook_unpack_fn \
          _dotfiler_hook_post_fn _dotfiler_hook_cleanup_fn \
          _dotfiler_hook_component_dir _dotfiler_hook_topology \
          _dotfiler_hook_setup_fn 2>/dev/null

    unset -f _update_core_cleanup 2>/dev/null
}
