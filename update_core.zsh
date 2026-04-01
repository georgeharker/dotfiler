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
# Release-channel helpers
# ---------------------------------------------------------------------------

# _update_core_get_release_channel <zstyle_scope>
# Reads the release-channel preference from a zstyle scope.
# Valid values: release | any
# Default: release  (updates are constrained to semver-tagged releases)
# Sets REPLY.
_update_core_get_release_channel() {
    local _ch
    zstyle -s "${1}" release-channel _ch 2>/dev/null || _ch=release
    case "${_ch:-release}" in
        any|all|tip) REPLY=any ;;
        *)           REPLY=release ;;
    esac
}

# _update_core_semver_tag_p <tag>
# Returns 0 if <tag> matches the semver pattern v<N>.<N>.<N>[...], 1 otherwise.
# Accepts any suffix after the three numeric components (e.g. -rc1, +build).
_update_core_semver_tag_p() {
    [[ "$1" == v[0-9]*.[0-9]*.[0-9]* ]]
}

# _update_core_resolve_latest_semver_tag_sha \
#     <remote_url> <branch> <comp_dir> [<remote_name>] [<tip_sha>]
#
# Phase 2 prepass: find the SHA of the latest semver tag (v<N>.<N>.<N>[...])
# that is reachable from the remote branch tip.
#
# <tip_sha>: if supplied, used directly as the branch tip for ancestry checks.
#   Callers that know the tip (e.g. just ran a fetch and captured FETCH_HEAD)
#   should pass it to avoid stale FETCH_HEAD races when multiple fetches run
#   in the same process (e.g. zdot pre-fetch overwriting FETCH_HEAD before the
#   dotfiler subtree check runs).
#
# Strategy:
#   GitHub remotes:
#     1. GET /repos/<owner>/<repo>/releases  (documented newest-first ordering)
#        Walk entries in order; skip drafts and pre-releases; take the first
#        whose tag_name matches semver and whose commit is an ancestor of (or
#        equal to) the remote branch tip.  Tag SHAs are resolved locally via
#        git rev-parse (the caller's fetch ensures objects are available).
#     2. Falls through to git ls-remote if the API fails or returns no
#        qualifying releases (handles tags without corresponding releases).
#   Non-GitHub remotes:
#     1. git ls-remote --tags <remote_url>
#        Filter by semver name, collect name→SHA pairs (preferring dereferenced
#        ^{} entries for annotated tags), sort by version descending, then
#        early-bail on the first reachable tag.
#
# Sets REPLY to the tag's commit SHA on success (returns 0).
# Sets REPLY="" and returns 1 when no qualifying tag is found.
_update_core_resolve_latest_semver_tag_sha() {
    local _remote_url=$1 _branch=$2 _comp_dir=$3 _remote_name=${4:-} _tip_sha_hint=${5:-}
    REPLY=""

    # Resolve the local ref for the remote branch tip (available after fetch).
    # Priority: explicit hint > remote-tracking ref > FETCH_HEAD.
    local _tip_sha
    if [[ -n "$_tip_sha_hint" ]]; then
        _tip_sha="$_tip_sha_hint"
    elif [[ -n "$_remote_name" ]]; then
        _tip_sha=$(git -C "$_comp_dir" rev-parse \
            "${_remote_name}/${_branch}" 2>/dev/null)
    fi
    # Fallback: FETCH_HEAD populated by the most recent fetch.
    [[ -z "$_tip_sha" ]] && \
        _tip_sha=$(git -C "$_comp_dir" rev-parse FETCH_HEAD 2>/dev/null)
    [[ -z "$_tip_sha" ]] && return 1

    # --- GitHub Releases API path (documented newest-first ordering) ---
    if _update_core_extract_github_repo "$_remote_url"; then
        local _gh_repo="$REPLY"
        local _api_url="https://api.github.com/repos/${_gh_repo}/releases?per_page=100"
        local _releases_json
        _releases_json=$(_update_core_github_api_get "$_api_url") || _releases_json=""

        if [[ -n "$_releases_json" ]]; then
            # Parse tag_name, draft, and prerelease from each release entry.
            # Releases are returned newest-first (sorted by created_at desc).
            # We iterate in order, resolving each non-draft non-prerelease
            # semver tag to a local SHA.  First reachable match wins.
            local -a _ordered_tags=()
            local _cur_tag="" _cur_draft=false _cur_prerelease=false
            local _line

            while IFS= read -r _line; do
                if [[ "$_line" =~ '"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)"' ]]; then
                    # New entry boundary — flush previous.
                    if [[ -n "$_cur_tag" && "$_cur_draft" != true \
                          && "$_cur_prerelease" != true ]] \
                       && _update_core_semver_tag_p "$_cur_tag"; then
                        _ordered_tags+=("$_cur_tag")
                    fi
                    _cur_tag="${match[1]}" _cur_draft=false _cur_prerelease=false
                elif [[ "$_line" =~ '"draft"[[:space:]]*:[[:space:]]*(true|false)' ]]; then
                    _cur_draft="${match[1]}"
                elif [[ "$_line" =~ '"prerelease"[[:space:]]*:[[:space:]]*(true|false)' ]]; then
                    _cur_prerelease="${match[1]}"
                fi
            done <<< "$_releases_json"
            # Flush last entry.
            if [[ -n "$_cur_tag" && "$_cur_draft" != true \
                  && "$_cur_prerelease" != true ]] \
               && _update_core_semver_tag_p "$_cur_tag"; then
                _ordered_tags+=("$_cur_tag")
            fi

            if [[ ${#_ordered_tags[@]} -gt 0 ]]; then
                # Tags are already newest-first from the API.  Resolve each
                # to a local SHA and check reachability; early-bail on first hit.
                local _tag _sha
                for _tag in "${_ordered_tags[@]}"; do
                    _sha=$(git -C "$_comp_dir" rev-parse "refs/tags/${_tag}^{}" 2>/dev/null \
                        || git -C "$_comp_dir" rev-parse "refs/tags/${_tag}" 2>/dev/null) \
                        || continue
                    if git -C "$_comp_dir" merge-base --is-ancestor \
                            "$_sha" "$_tip_sha" 2>/dev/null \
                       || [[ "$_sha" == "$_tip_sha" ]]; then
                        REPLY="$_sha"
                        return 0
                    fi
                done
                # Releases found but none reachable from branch tip.
                return 1
            fi
            # API returned data but no qualifying releases — fall through to
            # ls-remote in case there are tags without corresponding releases.
        fi
        # API failed or no releases — fall through to git ls-remote.
    fi

    # --- Non-GitHub / API fallback: git ls-remote + local ancestry ---
    # ls-remote --tags prints both lightweight and annotated (^{}) refs.
    # For annotated tags, the ^{} line dereferences to the commit SHA.
    local _ls_out
    _ls_out=$(git ls-remote --tags "$_remote_url" 2>/dev/null) || return 1
    [[ -z "$_ls_out" ]] && return 1

    # Collect name→SHA pairs for semver tags (dereference annotated tags).
    # When both refs/tags/v1.2.3 and refs/tags/v1.2.3^{} exist, the ^{}
    # (dereferenced) entry overwrites the lightweight entry in the map,
    # giving us the commit SHA rather than the tag object SHA.
    local -A _tag_map=()
    local _ref_sha _ref_name
    while IFS=$'\t' read -r _ref_sha _ref_name; do
        _ref_name="${_ref_name#refs/tags/}"
        local _bare_name="${_ref_name%'^{}'}"
        _update_core_semver_tag_p "$_bare_name" || continue
        _tag_map[$_bare_name]="$_ref_sha"
    done <<< "$_ls_out"

    [[ ${#_tag_map[@]} -eq 0 ]] && return 1

    # Sort tag names by version (newest first) and early-bail on the first
    # tag whose commit is reachable from the branch tip.
    local _sorted_name _sha
    for _sorted_name in ${(f)"$(printf '%s\n' "${(@k)_tag_map}" | sort -V -r)"}; do
        _sha="${_tag_map[$_sorted_name]}"
        git -C "$_comp_dir" cat-file -e "${_sha}" 2>/dev/null || continue
        if git -C "$_comp_dir" merge-base --is-ancestor \
                "$_sha" "$_tip_sha" 2>/dev/null \
           || [[ "$_sha" == "$_tip_sha" ]]; then
            REPLY="$_sha"
            return 0
        fi
    done

    return 1
}

# _update_core_component_tip_range <comp_dir> <topology> [<subtree_url> <branch>] \
#                                   [--scope <zstyle_scope>]
# Compute the Phase 2 (self-directed) range for a component: where it is now
# to the current remote tip.  Fetches to materialise remote objects locally.
#
# Current-position semantics differ by topology:
#   standalone|submodule : HEAD of the component git repo
#   subtree              : SHA marker file (HEAD belongs to the parent repo)
#
# When --scope is given and the resolved release-channel is 'release', a prepass
# resolves _new to the latest semver tag reachable from the branch tip rather
# than the tip commit itself.  If no qualifying tag is found, returns empty
# (nothing to update).  Phase 1 callers omit --scope so tag constraint never
# applies there.
#
# Sets REPLY="old_sha..new_sha" (empty string on failure / nothing to do).
# Returns 0 on success, 1 on failure.
_update_core_component_tip_range() {
    local _comp_dir=$1 _topology=$2 _subtree_url=${3:-} _branch=${4:-}
    local _old _new _remote _scope=""
    REPLY=""

    # Consume optional --scope <value> pair from the argument list.
    local _i=1
    while (( _i <= $# )); do
        if [[ "${@[_i]}" == --scope ]]; then
            (( _i++ ))
            _scope="${@[_i]:-}"
        fi
        (( _i++ ))
    done

    case "$_topology" in
        subtree)
            # Current position is the SHA marker, not HEAD.
            # Fetch from the subtree's own remote URL — not the parent repo's
            # default remote, which points to a different repository entirely.
            _update_core_read_sha_marker "$_comp_dir" || return 1
            _old="$REPLY"
            [[ -n "$_subtree_url" && -n "$_branch" ]] || return 1
            local _fetch_err _fetched_tip
            _fetch_err=$(git -C "$_comp_dir" fetch -q "$_subtree_url" "$_branch" --tags 2>&1 >/dev/null) || {
                error "update_core: component_tip_range: subtree fetch failed: ${_fetch_err}"
                return 1
            }
            _fetched_tip=$(git -C "$_comp_dir" rev-parse FETCH_HEAD 2>/dev/null)
            if [[ -n "$_scope" ]]; then
                _update_core_get_release_channel "$_scope"
                if [[ "$REPLY" == release ]]; then
                    _update_core_resolve_latest_semver_tag_sha \
                        "$_subtree_url" "$_branch" "$_comp_dir" "" "$_fetched_tip" || { REPLY=""; return 0; }
                    _new="$REPLY"
                else
                    _new=$(_update_core_resolve_remote_sha "$_subtree_url" "$_branch") \
                        || return 1
                fi
            else
                _new=$(_update_core_resolve_remote_sha "$_subtree_url" "$_branch") \
                    || return 1
            fi
            ;;
        submodule|standalone|*)
            # Current position is the component repo HEAD.
            _remote=$(_update_core_get_default_remote "$_comp_dir")
            _branch=$(_update_core_get_default_branch "$_comp_dir" "$_remote")
            _old=$(git -C "$_comp_dir" rev-parse HEAD 2>/dev/null) || return 1
            local _fetch_err
            _fetch_err=$(git -C "$_comp_dir" fetch -q "$_remote" "$_branch" --tags 2>&1 >/dev/null) || {
                error "update_core: component_tip_range: fetch failed: ${_fetch_err}"
                return 1
            }
            if [[ -n "$_scope" ]]; then
                local _remote_url
                _remote_url=$(git -C "$_comp_dir" config \
                    "remote.${_remote}.url" 2>/dev/null) || _remote_url=""
                _update_core_get_release_channel "$_scope"
                if [[ "$REPLY" == release ]]; then
                    _update_core_resolve_latest_semver_tag_sha \
                        "$_remote_url" "$_branch" "$_comp_dir" "$_remote" \
                        || { REPLY=""; return 0; }
                    _new="$REPLY"
                else
                    _new=$(git -C "$_comp_dir" rev-parse \
                        "${_remote}/${_branch}" 2>/dev/null) || return 1
                fi
            else
                _new=$(git -C "$_comp_dir" rev-parse \
                    "${_remote}/${_branch}" 2>/dev/null) || return 1
            fi
            ;;
    esac

    [[ "$_old" == "$_new" ]] && { REPLY=""; return 0; }
    REPLY="${_old}..${_new}"
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

# _update_core_safe_rm <path>
# Dry-run-aware rm -f.  Checks the caller's dry_run[] array.
# Shared by update.zsh and zdot update-impl.zsh.
_update_core_safe_rm() {
    if [[ ${#dry_run[@]} -gt 0 ]]; then
        action "[DRY RUN] Would remove: $1"
    else
        rm -f "$1"
    fi
    return 0
}

# _update_core_is_available_fetch <repo_dir> [allow_diverged] [scope]
# Returns 0 if an update is available (local is behind, or diverged and
# allow_diverged=1), 1 to skip (up to date or local is ahead), 2 on error.
# When diverged and allow_diverged is unset/0, warns and returns 1.
# When <scope> is given and its release-channel=release, _remote_sha is resolved
# to the latest semver tag reachable from the remote branch tip rather than
# the tip commit itself.  If no semver tag exists returns 1 (skip).
_update_core_is_available_fetch() {
    local _repo_dir=$1 _allow_diverged=${2:-0} _scope=${3:-}
    local _remote _branch _local_sha _remote_sha _base
    _remote=$(_update_core_get_default_remote "$_repo_dir")
    _branch=$(_update_core_get_default_branch "$_repo_dir" "$_remote")
    git -C "$_repo_dir" fetch "$_remote" "$_branch" --quiet --tags 2>/dev/null || return 2
    _local_sha=$(git -C "$_repo_dir" rev-parse HEAD 2>/dev/null) || return 2

    # Tag-constraint prepass (Phase 2 only): resolve target to latest semver tag.
    if [[ -n "$_scope" ]]; then
        _update_core_get_release_channel "$_scope"
        if [[ "$REPLY" == release ]]; then
            local _remote_url
            _remote_url=$(git -C "$_repo_dir" config \
                "remote.${_remote}.url" 2>/dev/null) || _remote_url=""
            _update_core_resolve_latest_semver_tag_sha \
                "$_remote_url" "$_branch" "$_repo_dir" "$_remote" || return 1
            _remote_sha="$REPLY"
        fi
    fi
    if [[ -z "${_remote_sha:-}" ]]; then
        _remote_sha=$(git -C "$_repo_dir" rev-parse \
            "${_remote}/${_branch}" 2>/dev/null) || return 2
    fi

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
# SHA marker helpers  –  persistent last-known SHA for subtree deployments
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
# Skips the write (and the debug log) if the marker already contains <sha>.
# Returns 0 on success or already-current, 1 on write failure.
_update_core_write_sha_marker() {
    local _subtree_dir=${1:?subtree directory required}
    local _sha=${2:?sha required}
    _update_core_sha_marker_path "$_subtree_dir"
    local _path=$REPLY
    # Read existing value — skip write if already current.
    if _update_core_read_sha_marker "$_subtree_dir" && [[ "$REPLY" == "$_sha" ]]; then
        return 0
    fi
    if printf '%s\n' "$_sha" > "$_path" 2>/dev/null; then
        log_debug "update_core: wrote sha marker: $_path (sha=${_sha})"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# GitHub API helper — single implementation for all API-first checks
# ---------------------------------------------------------------------------

# _update_core_github_api_get <api_url>
# Performs an authenticated GET against the GitHub API.
# Prints the response body to stdout.  Returns 0 on success, 1 on failure.
# Uses GH_TOKEN (or GITHUB_TOKEN) for authentication when available.
_update_core_github_api_get() {
    local _api_url=$1
    local _curl_auth=() _wget_auth=()
    # GH_TOKEN (gh cli convention) with GITHUB_TOKEN fallback (CI / actions)
    local _token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    if [[ -n "$_token" ]]; then
        _curl_auth=(-H "Authorization: Bearer ${_token}")
        _wget_auth=(--header="Authorization: Bearer ${_token}")
    fi

    if (( ${+commands[curl]} )); then
        curl --connect-timeout 10 --max-time 30 -fsSL \
            -H 'Accept: application/vnd.github.v3.sha' \
            "${_curl_auth[@]}" "$_api_url" 2>/dev/null
    elif (( ${+commands[wget]} )); then
        wget --timeout=30 -O- \
            --header='Accept: application/vnd.github.v3.sha' \
            "${_wget_auth[@]}" "$_api_url" 2>/dev/null
    else
        return 1
    fi
}

# _update_core_extract_github_repo <url>
# If <url> is a GitHub URL, sets REPLY to "owner/repo" and returns 0.
# Otherwise sets REPLY="" and returns 1.
_update_core_extract_github_repo() {
    local _url=$1
    case "$_url" in
        https://github.com/*) REPLY=${${_url#https://github.com/}%.git}; return 0 ;;
        git@github.com:*)     REPLY=${${_url#git@github.com:}%.git}; return 0 ;;
        *)                    REPLY=""; return 1 ;;
    esac
}

# _update_core_resolve_remote_sha <remote_url> <branch>
# Fetches the HEAD SHA for <branch> from <remote_url>.
# Prints the SHA to stdout.  Returns 0 on success, 1 on failure.
# Tries the GitHub API first (lightweight), then falls back to git ls-remote.
_update_core_resolve_remote_sha() {
    local _remote_url=$1 _branch=${2:-main}
    local _sha=""

    # --- GitHub API path ---
    if _update_core_extract_github_repo "$_remote_url"; then
        local _api_url="https://api.github.com/repos/${REPLY}/commits/${_branch}"
        _sha=$(_update_core_github_api_get "$_api_url")
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

# _update_core_check_dirty <repo_dir> [--exclude <path>]
# Returns 0 if clean, 1 if dirty.
# Uses git status --porcelain rather than git diff --quiet so that submodule
# working tree mismatches (stale submodule HEAD vs gitlink) are detected —
# git diff --quiet ignores submodule state by default.
# With --exclude <path>, lines matching that path are ignored (e.g. an
# expected submodule gitlink mismatch that will be staged later).
_update_core_check_dirty() {
    local _dir=$1; shift
    local _exclude=""
    if [[ "${1:-}" == --exclude ]]; then
        _exclude=$2
    fi
    if [[ -z "$_exclude" ]]; then
        [[ -z "$(git -C "$_dir" status --porcelain 2>/dev/null)" ]]
    else
        # Filter out lines whose path matches the exclude prefix.
        local _line
        while IFS= read -r _line; do
            # porcelain format: XY <path> or XY <path> -> <path>
            # The path starts at column 4 (after the two status chars + space).
            local _path="${_line[4,-1]}"
            [[ "$_path" == "$_exclude" || "$_path" == "$_exclude "* || "$_path" == "$_exclude/"* ]] && continue
            # If any non-excluded dirty line remains, repo is dirty.
            return 1
        done < <(git -C "$_dir" status --porcelain 2>/dev/null)
        return 0
    fi
}

# _update_core_prompt_dirty <repo_dir> <label>
# If repo is dirty, warns the user that the merge won't work.
# Prompts whether to stash (using per-repo consent cache).
# Returns 0 if clean or user consented to stash, 1 to abort.
# Does NOT stash — caller decides how.
_update_core_prompt_dirty() {
    local _dir=$1 _label=${2:-update}

    _update_core_check_dirty "$_dir" && return 0

    verbose "update_core: ${_label}: repo ${_dir} is dirty"

    # Check / populate per-repo consent cache.
    local _canon="${_dir:A}"
    if [[ -n "${_dotfiler_stash_consent[$_canon]:-}" ]]; then
        if [[ "${_dotfiler_stash_consent[$_canon]}" == y ]]; then
            verbose "${_label}: reusing earlier stash consent for ${_canon}"
            return 0
        else
            verbose "${_label}: reusing earlier stash refusal for ${_canon}"
            warn "${_label}: skipping (dirty repo — declined earlier)"
            return 1
        fi
    fi

    if _update_core_has_typed_input; then
        warn "${_label}: repo is dirty — merge will fail"
        warn "stash or commit changes manually before updating"
        _dotfiler_stash_consent[$_canon]=n
        return 1
    fi

    print -n "${_label}: repo has uncommitted changes — merge will fail. Stash and continue? [y/N] "
    local _ans
    read -r -k1 _ans; print ""
    if [[ "$_ans" != [yY] ]]; then
        _dotfiler_stash_consent[$_canon]=n
        warn "${_label}: skipping (dirty repo)"
        return 1
    fi
    _dotfiler_stash_consent[$_canon]=y
    warn "${_label}: stashing — note: if merge fails your changes will remain stashed"
    warn "${_label}: recover with: git -C ${_dir} stash pop"
    return 0
}

# _update_core_maybe_stash / _update_core_pop_stash — see below.

# _update_core_maybe_stash <repo_dir> <label> [--exclude <path>]
# If dirty, prompts the user (using per-repo consent cache). On consent, stashes.
# Sets REPLY=1 if a stash was created, REPLY=0 if not.
# Returns 0 to proceed, 1 to abort.
# With --exclude <path>, that path is ignored when checking dirt (e.g. an
# expected submodule gitlink mismatch that post_marker will stage later).
_update_core_maybe_stash() {
    local _dir=$1 _label=${2:-update}; shift 2
    local -a _exclude_args=()
    if [[ "${1:-}" == --exclude ]]; then
        _exclude_args=(--exclude "$2")
    fi
    REPLY=0

    # In dry-run mode, never prompt or stash — report clean to caller.
    (( ${_dry_run:-0} )) && return 0

    _update_core_check_dirty "$_dir" "${_exclude_args[@]}" && return 0

    verbose "update_core: ${_label}: repo ${_dir} is dirty"

    # Check / populate per-repo consent cache.
    local _canon="${_dir:A}"
    local _cached="${_dotfiler_stash_consent[$_canon]:-}"
    if [[ -z "$_cached" ]]; then
        # No cached answer — prompt the user.
        if _update_core_has_typed_input; then
            warn "${_label}: repo is dirty — cannot prompt, skipping update"
            warn "stash or commit changes manually before updating"
            _dotfiler_stash_consent[$_canon]=n
            return 1
        fi

        print -n "${_label}: repo has uncommitted changes. Stash and continue? [y/N] "
        local _ans
        read -r -k1 _ans; print ""
        if [[ "$_ans" != [yY] ]]; then
            _dotfiler_stash_consent[$_canon]=n
            warn "${_label}: skipping (dirty repo)"
            return 1
        fi
        _dotfiler_stash_consent[$_canon]=y
    elif [[ "$_cached" == n ]]; then
        verbose "${_label}: reusing earlier stash refusal for ${_canon}"
        warn "${_label}: skipping (dirty repo — declined earlier)"
        return 1
    else
        verbose "${_label}: reusing earlier stash consent for ${_canon}"
    fi

    log_debug "update_core: ${_label}: stashing in ${_dir}"
    git -C "$_dir" stash push -q -m "dotfiler: stash before ${_label}" || {
        warn "${_label}: git stash failed — skipping"
        return 1
    }
    # Verify the stash actually cleaned the tree — submodule pointers and
    # some working tree states can survive a stash.  The exclude path is
    # passed through so expected survivors (e.g. submodule gitlink mismatch)
    # are tolerated.
    if ! _update_core_check_dirty "$_dir" "${_exclude_args[@]}"; then
        warn "${_label}: repo still dirty after stash (submodule pointer or untracked files?)"
        warn "${_label}: commit or clean changes manually before updating"
        git -C "$_dir" stash pop -q 2>/dev/null
        return 1
    fi
    REPLY=1
    return 0
}

# _update_core_pop_stash <repo_dir> <label>
# Pops the stash in <repo_dir>. Only call if _update_core_maybe_stash set REPLY=1.
_update_core_pop_stash() {
    local _dir=$1 _label=${2:-update}
    log_debug "update_core: ${_label}: popping stash in ${_dir}"
    git -C "$_dir" stash pop -q || {
        warn "${_label}: stash pop had conflicts — resolve manually"
        warn "run: git -C ${_dir} stash pop"
        return 1
    }
}

# ---------------------------------------------------------------------------
# _update_core_maybe_rebase <repo_dir> <label> <target_ref>
#
# Prompts the user to rebase <repo_dir> onto <target_ref>.
# On consent runs `git rebase <target_ref>`.
# REPLY=1 if rebased, 0 if skipped.
# Returns 0 on success or skip, 1 on rebase failure or conflict.
# ---------------------------------------------------------------------------
_update_core_maybe_rebase() {
    local _dir=$1 _label=$2 _target=$3
    REPLY=0
    warn "${_label}: local commits diverge from ${_target[1,12]} — cannot fast-forward."
    if _update_core_has_typed_input; then
        warn "${_label}: stdin has buffered input — skipping rebase prompt."
        return 1
    fi
    read -rq "?${_label}: rebase local commits onto ${_target[1,12]}? [y/N] " || {
        warn "${_label}: rebase skipped."
        return 1
    }
    print ""
    git -C "$_dir" rebase "$_target" || {
        warn "${_label}: rebase failed — resolve conflicts and retry."
        return 1
    }
    REPLY=1
    return 0
}

# ---------------------------------------------------------------------------
# _update_core_component_pull_standalone <repo_dir> <target_ref> <remote> <branch> <phase>
#
# Pull a standalone component repository.
#   Phase dotfiles : stash if dirty, merge --ff-only to <target_ref>;
#                    on failure prompt rebase.  Pop stash afterwards.
#                    If rebased, writes ext marker with the new HEAD SHA.
#   Phase components: git pull --ff-only --autostash <remote> <branch>.
#
# REPLY = ff | rebase | pull | skip
# Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
_update_core_component_pull_standalone() {
    local _repo_dir=$1 _target_ref=$2 _remote=$3 _branch=$4 _phase=$5
    REPLY=skip

    if [[ "$_phase" == dotfiles ]]; then
        if (( ${_dry_run:-0} )); then
            verbose "component pull: [dry-run] would: standalone: git merge --ff-only ${_target_ref[1,12]}"
            REPLY=ff
            return 0
        fi
        # Stash any dirty state before merge (matches submodule Phase 1 pattern).
        local _stashed=0
        _update_core_maybe_stash "$_repo_dir" "standalone component" || return 1
        _stashed=$REPLY
        verbose "component pull: standalone: git merge --ff-only ${_target_ref[1,12]}"
        if git -C "$_repo_dir" merge -q --ff-only "$_target_ref" 2>/dev/null; then
            (( _stashed )) && _update_core_pop_stash "$_repo_dir" "standalone component"
            REPLY=ff
            return 0
        fi
        # Fast-forward failed.  First check whether we are already ahead of
        # the target (the component was advanced beyond what dotfiles records,
        # e.g. from a prior Phase-2 pull with itc_mode=none).  If so, the
        # merge failure is not a real divergence — just treat it as ff.
        if git -C "$_repo_dir" merge-base --is-ancestor "$_target_ref" HEAD 2>/dev/null; then
            verbose "component pull: standalone: HEAD already ahead of ${_target_ref[1,12]} — no-op"
            (( _stashed )) && _update_core_pop_stash "$_repo_dir" "standalone component"
            REPLY=ff
            return 0
        fi
        # Genuinely diverged — offer rebase (stash already active).
        _update_core_maybe_rebase "$_repo_dir" "standalone component" "$_target_ref" || {
            (( _stashed )) && _update_core_pop_stash "$_repo_dir" "standalone component"
            return 1
        }
        (( _stashed )) && _update_core_pop_stash "$_repo_dir" "standalone component"
        if (( REPLY )); then
            # Rebased: new HEAD differs from target_ref — rewrite ext marker.
            local _rebased_sha
            _rebased_sha=$(git -C "$_repo_dir" rev-parse HEAD 2>/dev/null) || {
                warn "component pull: standalone: could not resolve HEAD after rebase."
                return 1
            }
            _update_core_write_ext_marker "$_repo_dir" "$_rebased_sha" || return 1
            REPLY=rebase
        else
            return 1
        fi
    else
        if (( ${_dry_run:-0} )); then
            verbose "component pull: [dry-run] would: standalone: git pull --ff-only --autostash ${_remote} ${_branch}"
            REPLY=pull
            return 0
        fi
        verbose "component pull: standalone: git pull --ff-only --autostash ${_remote} ${_branch}"
        git -C "$_repo_dir" pull -q --ff-only --autostash "$_remote" "$_branch" || {
            warn "component pull: standalone: git pull failed."
            return 1
        }
        REPLY=pull
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _update_core_component_pull_submodule <parent> <rel> <target_ref> <phase>
#
# Pull a submodule component.
#   Phase dotfiles : check ancestry; if ff-able run submodule update (pins to
#                    dotfiles-recorded pointer).  If diverged, prompt rebase in
#                    the submodule dir then stage the updated gitlink in parent.
#   Phase components: check ancestry against remote tip; if ff-able run
#                     submodule update --remote (advance to upstream tip).
#                     If diverged, prompt rebase then stage updated gitlink.
#
# REPLY = ff | rebase | pull | skip
# Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
_update_core_component_pull_submodule() {
    local _parent=$1 _rel=$2 _target_ref=$3 _phase=$4
    REPLY=skip

    local _sub_dir="${_parent}/${_rel}"

    if [[ "$_phase" == dotfiles ]]; then
        # Determine current submodule HEAD.
        local _current_sha
        _current_sha=$(git -C "$_sub_dir" rev-parse HEAD 2>/dev/null) || {
            warn "component pull: submodule: cannot resolve submodule HEAD in ${_sub_dir}."
            return 1
        }

        # Check whether the current HEAD is an ancestor of target (ff-able).
        if git -C "$_sub_dir" merge-base --is-ancestor "$_current_sha" "$_target_ref" 2>/dev/null; then
            if (( ${_dry_run:-0} )); then
                verbose "component pull: [dry-run] would: submodule: git submodule update -- ${_rel} (ff to ${_target_ref[1,12]})"
                REPLY=ff
                return 0
            fi
            verbose "component pull: submodule: git submodule update -- ${_rel} (ff to ${_target_ref[1,12]})"
            # Stash any dirty state inside the submodule itself (e.g. local edits
            # to component files). The parent's gitlink mismatch after git pull is
            # expected at this point — it is not real dirt, it is what submodule
            # update is about to resolve — so we stash the submodule dir, not the
            # parent.
            local _stashed=0
            _update_core_maybe_stash "$_sub_dir" "submodule component" || return 1
            _stashed=$REPLY
            git -C "$_parent" submodule update -- "$_rel" || {
                (( _stashed )) && _update_core_pop_stash "$_sub_dir" "submodule component"
                warn "component pull: submodule update failed."
                return 1
            }
            (( _stashed )) && _update_core_pop_stash "$_sub_dir" "submodule component"
            REPLY=ff
        elif git -C "$_sub_dir" merge-base --is-ancestor "$_target_ref" "$_current_sha" 2>/dev/null; then
            # Current HEAD is already ahead of the target SHA — the submodule
            # was advanced beyond what dotfiles currently records (e.g. from a
            # prior Phase-2 pull whose pointer was not yet persisted into
            # dotfiles, typically because itc_mode=none).  Nothing to do.
            verbose "component pull: submodule: HEAD already ahead of ${_target_ref[1,12]} — no-op"
            REPLY=ff
        else
            # Diverged — stash submodule dirty state, offer rebase, pop.
            # Parent stash is handled by post_marker when it commits the gitlink.
            local _stashed_diverge=0
            _update_core_maybe_stash "$_sub_dir" "submodule component" || return 1
            _stashed_diverge=$REPLY
            _update_core_maybe_rebase "$_sub_dir" "submodule component" "$_target_ref" || {
                (( _stashed_diverge )) && _update_core_pop_stash "$_sub_dir" "submodule component"
                return 1
            }
            (( _stashed_diverge )) && _update_core_pop_stash "$_sub_dir" "submodule component"
            if (( REPLY )); then
                REPLY=rebase
            else
                return 1
            fi
        fi
    else
        if (( ${_dry_run:-0} )); then
            verbose "component pull: [dry-run] would: submodule: git submodule update --remote -- ${_rel}"
            REPLY=pull
            return 0
        fi

        # Determine current submodule HEAD and remote tip for divergence check.
        local _current_sha_p2 _remote_sha_p2
        _current_sha_p2=$(git -C "$_sub_dir" rev-parse HEAD 2>/dev/null) || {
            warn "component pull: submodule: cannot resolve submodule HEAD in ${_sub_dir}."
            return 1
        }
        _remote_sha_p2=$(git -C "$_sub_dir" rev-parse "$_target_ref" 2>/dev/null) || {
            warn "component pull: submodule: cannot resolve remote ref ${_target_ref}."
            return 1
        }

        if git -C "$_sub_dir" merge-base --is-ancestor "$_current_sha_p2" "$_remote_sha_p2" 2>/dev/null; then
            verbose "component pull: submodule: git submodule update --remote -- ${_rel} (ff to ${_remote_sha_p2[1,12]})"
            # Stash dirty state inside the submodule first (local edits to component
            # files would block submodule update --remote), then stash any pre-existing
            # real dirty state in the parent (e.g. unrelated staged changes).
            local _stashed_sub=0 _stashed_parent=0
            _update_core_maybe_stash "$_sub_dir" "submodule component" || return 1
            _stashed_sub=$REPLY
            _update_core_maybe_stash "$_parent" "dotfiles repo (submodule)" || {
                (( _stashed_sub )) && _update_core_pop_stash "$_sub_dir" "submodule component"
                return 1
            }
            _stashed_parent=$REPLY
            git -C "$_parent" submodule update --remote -- "$_rel" || {
                (( _stashed_parent )) && _update_core_pop_stash "$_parent" "dotfiles repo (submodule)"
                (( _stashed_sub )) && _update_core_pop_stash "$_sub_dir" "submodule component"
                warn "component pull: submodule update --remote failed."
                return 1
            }
            (( _stashed_parent )) && _update_core_pop_stash "$_parent" "dotfiles repo (submodule)"
            (( _stashed_sub )) && _update_core_pop_stash "$_sub_dir" "submodule component"
            REPLY=pull
        else
            # Diverged — stash, offer rebase onto remote tip, pop afterwards.
            local _stashed_diverge_p2=0
            _update_core_maybe_stash "$_sub_dir" "submodule component" || return 1
            _stashed_diverge_p2=$REPLY
            _update_core_maybe_rebase "$_sub_dir" "submodule component" "$_remote_sha_p2" || {
                (( _stashed_diverge_p2 )) && _update_core_pop_stash "$_sub_dir" "submodule component"
                return 1
            }
            (( _stashed_diverge_p2 )) && _update_core_pop_stash "$_sub_dir" "submodule component"
            if (( REPLY )); then
                REPLY=rebase
            else
                return 1
            fi
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _update_core_component_pull_subtree <parent> <rel> <remote> <branch> <phase>
#
# Pull a subtree component.
#   Phase dotfiles : no-op — the parent pull already brought in tree content
#                    and the SHA marker together.
#   Phase components: git subtree pull --squash (advance to upstream tip).
#
# REPLY = ff | pull | skip
# Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
_update_core_component_pull_subtree() {
    local _parent=$1 _rel=$2 _remote=$3 _branch=$4 _phase=$5
    REPLY=skip

    if [[ "$_phase" == dotfiles ]]; then
        # Parent pull already merged content + marker — nothing to do here.
        verbose "component pull: subtree: phase=dotfiles — parent already current, no-op"
        REPLY=ff
        return 0
    fi

    if (( ${_dry_run:-0} )); then
        verbose "component pull: [dry-run] would: subtree: git subtree pull --prefix=${_rel} ${_remote} ${_branch} --squash"
        REPLY=pull
        return 0
    fi
    verbose "component pull: subtree: git subtree pull --prefix=${_rel} ${_remote} ${_branch} --squash"
    local _stashed=0
    _update_core_maybe_stash "$_parent" "dotfiles repo (subtree)" || return 1
    _stashed=$REPLY
    local _out _rc
    _out=$(git -C "$_parent" subtree pull \
        --prefix="$_rel" "$_remote" "$_branch" --squash 2>&1)
    _rc=$?
    log_debug "component pull: subtree output: ${_out}"
    (( _stashed )) && _update_core_pop_stash "$_parent" "dotfiles repo (subtree)"
    if (( _rc != 0 )); then
        warn "component pull: subtree pull failed."
        return 1
    fi
    REPLY=pull
    return 0
}

# ---------------------------------------------------------------------------
# _update_core_component_post_marker
#   <repo_dir> <parent> <rel> <new_sha> <topology> <itc_mode> <phase> <outcome>
#
# Writes marker files and/or commits the parent pointer after a pull.
# Stamp writes are NOT handled here — callers retain hook-specific stamp paths.
#
# Stashes any pre-existing dirty state in the parent before staging/committing,
# and pops afterwards, so that check_foreign_staged does not block the commit.
#
#   standalone:
#     Phase dotfiles + outcome==rebase : ext marker already written by pull
#                                        (pull wrote rebased HEAD, not new_sha).
#                                        Stage marker + commit parent.
#     Phase dotfiles + outcome==ff     : no-op (marker already correct).
#     Phase components                 : write ext marker (new_sha), stage, commit.
#   submodule:
#     Phase dotfiles + outcome==rebase : gitlink already staged by pull.
#                                        Commit parent.
#     Phase dotfiles + outcome==ff     : no-op (gitlink already correct).
#     Phase components                 : commit parent.
#   subtree:
#     Phase dotfiles                   : no-op.
#     Phase components                 : write SHA marker (new_sha), stage, commit.
#
# Returns 0/1.
# ---------------------------------------------------------------------------
_update_core_component_post_marker() {
    local _repo_dir=$1 _parent=$2 _rel=$3 _new_sha=$4
    local _topology=$5 _itc_mode=$6 _phase=$7 _outcome=$8

    # Nothing to record if pull was skipped (component already up to date).
    [[ "$_outcome" == skip ]] && return 0

    if (( ${_dry_run:-0} )); then
        case "$_topology" in
            standalone)
                if [[ "$_phase" == dotfiles && "$_outcome" == rebase ]]; then
                    verbose "component post: [dry-run] would: stage+commit ext marker (rebased standalone)"
                elif [[ "$_phase" != dotfiles ]]; then
                    verbose "component post: [dry-run] would: write ext marker ${_new_sha[1,12]} + commit parent"
                fi
                ;;
            submodule)
                if [[ "$_phase" == dotfiles ]]; then
                    verbose "component post: [dry-run] would: commit parent (submodule gitlink, outcome=${_outcome})"
                else
                    verbose "component post: [dry-run] would: commit parent (submodule ${_new_sha[1,12]})"
                fi
                ;;
            subtree)
                [[ "$_phase" == dotfiles ]] && return 0
                verbose "component post: [dry-run] would: write SHA marker ${_new_sha[1,12]} + commit parent"
                ;;
        esac
        return 0
    fi

    # Stash any pre-existing dirty state in the parent so that the marker
    # stage + commit_parent below runs against a clean index.  Without this,
    # check_foreign_staged would (correctly) block auto-commit if the user
    # has unrelated staged changes.
    #
    # The pull phase intentionally leaves expected dirt behind — a submodule
    # gitlink mismatch or a staged ext-marker — that post_marker will stage
    # and commit below.  The stash must not capture or choke on that payload:
    #
    #   submodule:  git stash cannot round-trip gitlink mismatches (the
    #               submodule working-tree HEAD survives the stash), so we
    #               pass --exclude to tolerate the expected mismatch.
    #   standalone: the ext-marker may already be staged; unstage it before
    #               stashing, then re-stage afterwards.
    #   subtree:    no payload at stash time; plain stash is fine.
    local _post_stashed=0
    local _payload_path=""
    if [[ -n "$_parent" && "$_itc_mode" != none ]]; then
        case "$_topology" in
            submodule)
                _update_core_maybe_stash "$_parent" "dotfiles repo (post marker)" \
                    --exclude "$_rel" || return 1
                _post_stashed=$REPLY
                ;;
            standalone)
                # Unstage the marker file before stashing so it is not
                # captured; re-stage afterwards.
                _update_core_ext_marker_path "$_repo_dir"
                _payload_path="${${REPLY:A}#${_parent:A}/}"
                if [[ -n "$_payload_path" ]]; then
                    git -C "$_parent" diff --cached --quiet -- "$_payload_path" 2>/dev/null || \
                        git -C "$_parent" reset -q HEAD -- "$_payload_path" 2>/dev/null
                fi

                _update_core_maybe_stash "$_parent" "dotfiles repo (post marker)" || {
                    [[ -n "$_payload_path" ]] && \
                        git -C "$_parent" add "$_payload_path" 2>/dev/null
                    return 1
                }
                _post_stashed=$REPLY

                if [[ -n "$_payload_path" ]]; then
                    git -C "$_parent" add "$_payload_path" 2>/dev/null
                fi
                ;;
            *)
                _update_core_maybe_stash "$_parent" "dotfiles repo (post marker)" || return 1
                _post_stashed=$REPLY
                ;;
        esac
    fi

    local _post_rc=0
    case "$_topology" in
        standalone)
            if [[ "$_phase" == dotfiles ]]; then
                if [[ "$_outcome" != rebase ]]; then
                    _post_rc=0  # no-op
                else
                    # Ext marker was written by pull with the rebased HEAD SHA.
                    # Stage it and commit the parent to record the new pointer.
                    _update_core_ext_marker_path "$_repo_dir"
                    local _marker_path=$REPLY
                    if [[ "$_itc_mode" != none && -f "$_marker_path" && -n "$_parent" ]]; then
                        git -C "$_parent" add "$_marker_path" 2>/dev/null
                        _update_core_commit_parent "$_parent" \
                            "${${_marker_path:A}#${_parent:A}/}" \
                            "ext sha marker updated (rebase)" \
                            "$(basename "$_repo_dir"): record rebased standalone SHA" \
                            "$_itc_mode"
                    fi
                fi
            else
                if [[ -z "$_new_sha" ]]; then
                    _post_rc=0  # no-op
                else
                    _update_core_write_ext_marker "$_repo_dir" "$_new_sha" || { _post_rc=1; }
                    if (( ! _post_rc )); then
                        _update_core_ext_marker_path "$_repo_dir"
                        local _marker_path=$REPLY
                        if [[ "$_itc_mode" != none && -f "$_marker_path" && -n "$_parent" ]]; then
                            git -C "$_parent" add "$_marker_path" 2>/dev/null
                            _update_core_commit_parent "$_parent" \
                                "${${_marker_path:A}#${_parent:A}/}" \
                                "ext sha marker updated" \
                                "$(basename "$_repo_dir"): record standalone SHA ${_new_sha[1,12]}" \
                                "$_itc_mode"
                        fi
                    fi
                fi
            fi
            ;;
        submodule)
            # Commit the updated gitlink into the parent repo.  Staging is
            # handled inside _update_core_commit_parent (for auto/prompt modes)
            # so we do NOT git-add here — an unconditional add would dirty the
            # index even when itc_mode=none, causing the subsequent subtree
            # stash/pop cycle to pick up staged-but-uncommitted changes and
            # conflict on pop.
            if [[ "$_phase" == dotfiles && "$_outcome" == ff ]]; then
                # ff: submodule update already moved HEAD to match the
                # gitlink recorded by the parent pull — nothing to commit.
                _post_rc=0
            elif [[ "$_phase" == dotfiles ]]; then
                # rebase: submodule HEAD diverged from the gitlink; commit
                # the new pointer.
                _update_core_commit_parent "$_parent" "$_rel" \
                    "submodule pointer updated (${_outcome})" \
                    "$(basename "$_repo_dir"): record submodule pointer" \
                    "$_itc_mode"
            else
                # Phase 2: submodule advanced beyond what dotfiles records.
                _update_core_commit_parent "$_parent" "$_rel" \
                    "submodule pointer updated" \
                    "$(basename "$_repo_dir"): update submodule to ${_new_sha[1,12]}" \
                    "$_itc_mode"
            fi
            ;;
        subtree)
            if [[ "$_phase" == dotfiles ]]; then
                _post_rc=0  # no-op
            elif [[ -z "$_new_sha" ]]; then
                _post_rc=0  # no-op
            else
                _update_core_write_sha_marker "$_repo_dir" "$_new_sha" || { _post_rc=1; }
                if (( ! _post_rc )); then
                    _update_core_sha_marker_path "$_repo_dir"
                    local _marker_path=$REPLY
                    if [[ "$_itc_mode" != none && -f "$_marker_path" ]]; then
                        git -C "$_parent" add "$_marker_path" 2>/dev/null
                    fi
                    _update_core_commit_parent "$_parent" "$_rel" \
                        "subtree updated" \
                        "$(basename "$_repo_dir"): update subtree ${_rel} to ${_new_sha[1,12]}" \
                        "$_itc_mode"
                fi
            fi
            ;;
        *)
            log_debug "component post marker: topology=${_topology} — nothing to do"
            ;;
    esac

    (( _post_stashed )) && _update_core_pop_stash "$_parent" "dotfiles repo (post marker)"
    return $_post_rc
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
                warn "${_label}: foreign staged changes in parent repo — skipping auto-commit"
                warn "commit manually: git -C ${_parent} add ${_rel} && git -C ${_parent} commit"
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
            if _update_core_has_typed_input; then
                warn "${_label}: stdin has buffered input — skipping parent commit"
                warn "commit manually: git -C ${_parent} add ${_rel} && git -C ${_parent} commit"
                return 1
            fi
            if ! _update_core_check_foreign_staged "$_parent" "$_rel"; then
                warn "${_label}: foreign staged changes in parent repo — skipping commit"
                return 0
            fi
            print -n "${_label} — commit in parent repo? [y/N] "
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
            info "${_label} — parent repo is dirty (commit manually)"
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

    local LAST_EPOCH EXIT_STATUS
    if ! source "$_stamp" 2>/dev/null || [[ -z "$LAST_EPOCH" ]]; then
        _update_core_write_timestamp "$_stamp"
        return 1
    fi

    # If the last run recorded a failure, always retry — do not throttle.
    if [[ -n "$EXIT_STATUS" ]] && (( EXIT_STATUS != 0 )); then
        return 0
    fi

    zmodload zsh/datetime 2>/dev/null
    (( ( EPOCHSECONDS - LAST_EPOCH ) >= _freq )) && return 0
    return 1
}

# ---------------------------------------------------------------------------
# Update availability — API-first (ohmyzsh pattern)
# ---------------------------------------------------------------------------

# _update_core_is_available <repo_dir> [remote_url_override] [allow_diverged] [scope]
# Returns:
#   0 — update is available (local is behind, or diverged with allow_diverged=1)
#   1 — up to date, local is ahead, or diverged with allow_diverged=0 (skip)
#
# For GitHub remotes: calls the GitHub API only (no git fetch).
# On API failure returns 1 (conservative skip — do not assume update available).
# For non-GitHub remotes: falls back to _update_core_is_available_fetch (git fetch).
# <remote_url_override>: if non-empty, used instead of reading git config.
# <allow_diverged>: 1 = warn and proceed on diverged; 0 = warn and skip (default).
# <scope>: when non-empty, reads release-channel from this zstyle scope.
#   release-channel=release (default): comparison target is the latest semver tag
#     reachable from the remote branch tip rather than the tip commit itself.
#     GitHub API path: uses /repos/<owner>/<repo>/releases.
#     Fetch path: delegates to _update_core_is_available_fetch with scope.
#     If no qualifying semver tag exists, returns 1 (nothing to update).
#   release-channel=any: current behaviour — compare against branch tip.
# Note: scope / release-channel constraint applies to Phase 2 (self-directed)
#   checks only.  Phase 1 (dotfiles-directed) callers omit scope.
_update_core_is_available() {
    local _repo_dir=$1 _remote_url_override=${2:-} _allow_diverged=${3:-0} \
          _scope=${4:-}
    local _remote _branch _remote_url

    _remote=$(_update_core_get_default_remote "$_repo_dir")
    _branch=$(_update_core_get_default_branch "$_repo_dir" "$_remote")

    if [[ -n "$_remote_url_override" ]]; then
        _remote_url=$_remote_url_override
    else
        _remote_url=$(git -C "$_repo_dir" config "remote.${_remote}.url" 2>/dev/null) || {
            _update_core_is_available_fetch "$_repo_dir" "$_allow_diverged" "$_scope"
            return $?
        }
    fi

    # --- Determine release-channel target ---
    local _channel=any
    if [[ -n "$_scope" ]]; then
        _update_core_get_release_channel "$_scope"; _channel="$REPLY"
    fi

    # --- GitHub API path (API-first, no git fetch) ---
    if _update_core_extract_github_repo "$_remote_url"; then
        local _gh_repo="$REPLY"
        local _local_head _remote_head

        # Use HEAD directly — rev-parse "$_branch" fails in detached-HEAD state
        # (e.g. freshly updated submodule), whereas HEAD always resolves.
        _local_head=$(git -C "$_repo_dir" rev-parse HEAD 2>/dev/null) || return 1

        if [[ "$_channel" == release ]]; then
            # Tag-constraint prepass via the releases/tags API.
            # We need objects locally for merge-base checks, so fetch first.
            git -C "$_repo_dir" fetch -q "$_remote" "$_branch" --tags 2>/dev/null
            _update_core_resolve_latest_semver_tag_sha \
                "$_remote_url" "$_branch" "$_repo_dir" "$_remote" || return 1
            _remote_head="$REPLY"
        else
            local _api_url="https://api.github.com/repos/${_gh_repo}/commits/${_branch}"
            # Call GitHub API — on failure, fall back to standard git fetch path.
            _remote_head=$(_update_core_github_api_get "$_api_url") || {
                log_debug "update_core: GitHub API unavailable, falling back to git fetch"
                _update_core_is_available_fetch "$_repo_dir" "$_allow_diverged" "$_scope"
                return $?
            }
            if [[ -z "$_remote_head" ]]; then
                log_debug "update_core: GitHub API returned empty response, falling back to git fetch"
                _update_core_is_available_fetch "$_repo_dir" "$_allow_diverged" "$_scope"
                return $?
            fi
        fi

        log_debug "update_core: local=${_local_head:0:8} remote(API)=${_remote_head:0:8} channel=${_channel}"

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
    _update_core_is_available_fetch "$_repo_dir" "$_allow_diverged" "$_scope"
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

# _update_core_is_available_subtree <subtree_dir> <subtree_spec> [<url_hint>] [<scope>]
# <subtree_spec> is "<remote_name> [branch]" (same format as zstyle subtree-remote).
# <scope> is a zstyle scope string (e.g. ':zdot:update').  When present and
# release-channel=release, the remote target is resolved to the latest semver tag
# reachable from the branch tip rather than the tip commit itself.
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
    local _subtree_dir=$1 _subtree_spec=$2 _url_hint=${3:-} _scope=${4:-}
    _update_core_resolve_subtree_spec "$_subtree_dir" "$_subtree_spec" "$_url_hint" || return 1
    local _remote="$reply[1]" _branch="$reply[2]" _remote_url="$reply[3]"
    local _local_head _remote_head

    # --- Determine release-channel target ---
    local _channel=any
    if [[ -n "$_scope" ]]; then
        _update_core_get_release_channel "$_scope"; _channel="$REPLY"
    fi

    # Read the cached SHA from the marker file adjacent to the subtree
    if _update_core_read_sha_marker "$_subtree_dir"; then
        _local_head=$REPLY
    else
        # No marker → first run; assume update available to bootstrap
        log_debug "update_core: no subtree SHA marker found — assuming update available"
        return 0
    fi

    if [[ "$_channel" == release ]]; then
        # Tag-constraint prepass: fetch to materialise objects locally and update
        # the remote-tracking ref (e.g. dotfiler/main) so ancestry checks use the
        # current tip.  Prefer fetching by remote name so the tracking ref is
        # updated; fall back to URL-based fetch (updates FETCH_HEAD only).
        if [[ -n "$_remote" ]]; then
            git -C "$_subtree_dir" fetch -q "$_remote" "$_branch" --tags 2>/dev/null
        else
            git -C "$_subtree_dir" fetch -q "$_remote_url" "$_branch" --tags 2>/dev/null
        fi
        _update_core_resolve_latest_semver_tag_sha \
            "$_remote_url" "$_branch" "$_subtree_dir" "$_remote" || return 1
        _remote_head="$REPLY"

        log_debug "update_core: subtree marker=${_local_head:0:8} remote(tag)=${_remote_head:0:8} channel=${_channel}"

        [[ "$_local_head" == "$_remote_head" ]] && return 1
        return 0
    fi

    # --- channel=any: compare marker against branch tip ---

    # --- GitHub API path (API-first, no git fetch) ---
    if _update_core_extract_github_repo "$_remote_url"; then
        local _api_url="https://api.github.com/repos/${REPLY}/commits/${_branch}"

        _remote_head=$(_update_core_github_api_get "$_api_url") \
            || return 1   # API failure → skip (conservative)

        [[ -z "$_remote_head" ]] && return 1   # empty response → skip

        log_debug "update_core: subtree marker=${_local_head:0:8} remote(API)=${_remote_head:0:8} channel=${_channel}"

        # Simple equality check — no merge-base (parent repo has no
        # knowledge of the subtree source history)
        [[ "$_local_head" == "$_remote_head" ]] && return 1
        return 0
    fi

    # --- Non-GitHub remote: fall back to git ls-remote ---
    _remote_head=$(git ls-remote "$_remote_url" "$_branch" 2>/dev/null | awk '{print $1}')
    [[ -z "$_remote_head" ]] && return 1   # ls-remote failed → skip

    log_debug "update_core: subtree marker=${_local_head:0:8} remote(ls-remote)=${_remote_head:0:8} channel=${_channel}"

    [[ "$_local_head" == "$_remote_head" ]] && return 1
    return 0
}

# _update_core_is_dotfiler_available <script_dir> <subtree_spec> <subtree_url>
#
# Single canonical availability check for the dotfiler scripts themselves,
# covering all deployment topologies.  Both check_update.zsh (pre-prompt check)
# and update.zsh (_update_dotfiler_plan) call this so they can never diverge.
#
# Topology semantics:
#   standalone  — scripts are their own top-level git repo; fetch + compare
#   submodule   — scripts are a submodule; fetch submodule remote + compare
#                 (surfaces upstream-ahead changes before parent bumps pointer)
#   subtree     — scripts merged via git-subtree; compare SHA marker vs remote
#   subdir      — plain subdirectory inside parent repo; parent repo check
#                 already covers it, nothing extra needed here
#   none|*      — not a git repo; nothing to check
#
# Release-channel constraint (Phase 2 only):
#   Reads ':dotfiler:update' release-channel (default: release).
#   When 'release', the availability check compares local position against the
#   latest semver tag reachable from the remote branch tip, not the tip itself.
#   This means dotfiler updates only when a new v<N>.<N>.<N> tag has been
#   published.
#
# Returns: 0 = update available, 1 = up to date / not applicable
_update_core_is_dotfiler_available() {
    local _script_dir=${1:?script_dir required}
    local _subtree_spec=${2:-}
    local _subtree_url=${3:-}

    _update_core_detect_deployment "$_script_dir" "$_subtree_spec"
    local _topology=$REPLY

    log_debug "update_core: is_dotfiler_available: topology=${_topology}"
    local _avail
    case $_topology in
        standalone|submodule)
            # Pass ':dotfiler:update' scope so tag constraint applies.
            _update_core_is_available "$_script_dir" "" 0 ':dotfiler:update' \
                && _avail=0 || _avail=$?
            ;;
        subtree)
            # Pass ':dotfiler:update' scope so tag constraint applies.
            _update_core_is_available_subtree \
                "$_script_dir" "$_subtree_spec" "$_subtree_url" \
                ':dotfiler:update' \
                && _avail=0 || _avail=$?
            ;;
        subdir|none|*)
            log_debug "update_core: is_dotfiler_available: topology=${_topology} — parent repo manages scripts"
            return 1
            ;;
    esac
    log_debug "update_core: is_dotfiler_available: avail=${_avail}"
    return $_avail
}

# ---------------------------------------------------------------------------
# File list builder (promoted from update.zsh for use by hooks)
# ---------------------------------------------------------------------------

# _update_core_build_file_lists [--excludes <file>] <repo_dir> <diff_range>
# Walks commits in <diff_range> commit-by-commit (-m for merge awareness) and
# populates two *caller-declared* unique arrays:
#   _update_core_files_to_unpack  — files to add/update via setup.zsh
#   _update_core_files_to_remove  — deleted/renamed-away symlinks to remove
# The arrays must be declared (typeset -aU) by the caller before this call.
# Callers should copy them out immediately; they are overwritten on each call.
#
# Options:
#   --excludes <file>
#       Path to a gitignore-style exclude file (e.g. dotfiles_exclude,
#       zdot_exclude).  Loaded as the user layer (layer 3).
#       Exclusion rules are built in three layers, mirroring _setup_init:
#         1. Enforce: .git/ and .nounpack/ always excluded.
#         2. Always:  always_exclude from <repo_dir>, falling back to the
#                     dotfiler script directory.
#         3. User:    the --excludes file, if provided.
#       Without --excludes only layers 1+2 apply.
_update_core_build_file_lists() {
    setopt local_options extended_glob no_unset
    local _excludes_file=''
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --excludes) _excludes_file=$2; shift 2 ;;
            --) shift; break ;;
            *) break ;;
        esac
    done
    local _repo_dir=$1 _diff_range=$2

    # Build a local exclusion rules array mirroring the three-layer model used
    # by _setup_init in setup_core.zsh:
    #   Layer 1 (enforce): .git/ and .nounpack/ are always excluded.
    #   Layer 2 (always):  always_exclude in the repo dir (or dotfiler fallback).
    #   Layer 3 (user):    the caller-supplied --excludes file.
    # Rules are stored as "FLAG:PATTERN" strings matching setup_core.zsh's
    # _gitignore_rules format.  _read_exclusion_patterns_into is the shared
    # parser; we use it here with a local array to avoid touching the global
    # _gitignore_rules used by the setup path.
    local -a _excl_rules=()
    _read_exclusion_patterns_into _excl_rules --enforce

    local _always_excl="${_repo_dir}/always_exclude"
    [[ -f "$_always_excl" ]] || \
        _always_excl="${${(%):-%x}:A:h}/always_exclude"
    [[ -f "$_always_excl" ]] && \
        _read_exclusion_patterns_into _excl_rules "$_always_excl"

    [[ -n "$_excludes_file" ]] && \
        _read_exclusion_patterns_into _excl_rules "$_excludes_file"

    # _build_should_exclude <rel_path>
    # Returns 0 (exclude) or 1 (keep), honoring negation (!) and enforce priority.
    # Mirrors the last-match-wins logic of should_exclude_file in setup_core.zsh,
    # including the verdict_enforced guard that prevents user negations from
    # overriding enforce-level exclusions.
    _build_should_exclude() {
        local _bse_path="$1"
        local _bse_verdict=1         # 1 = keep (default)
        local _bse_verdict_enforced=0  # 1 if current verdict came from an enforce rule
        local _bse_rule _bse_flag _bse_pat _bse_negated
        for _bse_rule in "${_excl_rules[@]}"; do
            _bse_flag="${_bse_rule%%:*}"
            _bse_pat="${_bse_rule#*:}"
            _bse_negated=0
            if [[ "$_bse_pat" == !* ]]; then
                _bse_negated=1
                _bse_pat="${_bse_pat#!}"
            fi
            if (( _bse_negated )); then
                # Negation: un-exclude if pattern matches — but user negation
                # cannot override an enforce exclusion.
                if [[ "$_bse_flag" == "enforce" ]]; then
                    # Enforce negation re-includes even enforced exclusions.
                    _gitignore_match_single "$_bse_pat" "$_bse_path" 0 && \
                        { _bse_verdict=1; _bse_verdict_enforced=0; }
                else
                    # User negation: only effective if not currently enforce-excluded.
                    if (( ! _bse_verdict_enforced )) || [[ "$_bse_verdict" == "1" ]]; then
                        _gitignore_match_single "$_bse_pat" "$_bse_path" 0 && \
                            { _bse_verdict=1; _bse_verdict_enforced=0; }
                    fi
                fi
            else
                _gitignore_match_single "$_bse_pat" "$_bse_path" 0 && {
                    _bse_verdict=0
                    [[ "$_bse_flag" == "enforce" ]] && _bse_verdict_enforced=1 || _bse_verdict_enforced=0
                }
            fi
        done
        return $_bse_verdict
    }

    local _line _hash _message _git_log
    local _update_type _file_refs

    _update_core_files_to_unpack=()
    _update_core_files_to_remove=()

    # Fetch hash, subject, and full body in one git call to avoid a separate
    # subprocess per commit just for subtree-squash detection.
    # Use NUL (%x00) as a record terminator after the body; split on NUL below.
    # Format per commit: <hash> TAB <subject> NL <body> NUL
    local _all_commits
    # --first-parent: for merge commits, only diff against parent 1 (the
    # local/mainline side).  Without this, -m diffs against every parent,
    # which for subtree merges means diffing against the subrepo root and
    # listing every non-subtree file as "added".  --first-parent gives us
    # "what the merge brought in from remote" which is correct for unpacking.
    _all_commits=$(git -C "$_repo_dir" log --reverse --first-parent \
        --diff-filter=ADMRC --no-decorate \
        --pretty=tformat:"%H%x09%s%n%B%x00" \
        "${_diff_range}" 2>/dev/null)
    if (( $? != 0 )); then
        warn "update_core: git log failed for range ${_diff_range} in ${_repo_dir}"
        warn "update_core: one or both SHAs may not be present locally — run with --debug for details"
        log_debug "update_core: git log --reverse --first-parent ${_diff_range} in ${_repo_dir} failed"
        return 1
    fi

    # Split on NUL to get one record per commit.
    # Each record is: "<hash>\t<subject>\n<body lines...>"
    local _record _body _first_line
    for _record in "${(@ps:\x00:)_all_commits}"; do
        # Strip leading newlines (artefact of the NUL split).
        _record=${_record##$'\n'#}
        [[ -n "$_record" ]] || continue

        _first_line=${_record%%$'\n'*}
        _hash=${_first_line%%$'\t'*}
        _message=${_first_line#*$'\t'}
        _body=${_record#*$'\n'}

        [[ -n "$_hash" ]] || continue
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
        if [[ "$_body" == *$'\n''git-subtree-dir: '* && \
              "$_body" == *$'\n''git-subtree-split: '* ]]; then
            log_debug "  skipping squashed subtree commit"
            continue
        fi

        _git_log=$(git -C "$_repo_dir" diff-tree -r --no-commit-id \
            --diff-filter=ADMRC --name-status \
            "${_hash}^" "${_hash}" 2>/dev/null)

        for _line in ${(f)_git_log}; do
            [[ "$_line" =~ "^[ADMRC][0-9]*"$'\t'".*$" ]] || continue
            _update_type=${_line%%$'\t'*}
            _file_refs=${_line#*$'\t'}

            if [[ "$_update_type" == M ]]; then
                local _file=$_file_refs
                [[ -n "$_file" ]] || continue
                _build_should_exclude "$_file" && continue
                log_debug "  $_file modified"
                _update_core_files_to_unpack+=("$_file")
                _update_core_files_to_remove=(${_update_core_files_to_remove:#"$_file"})

            elif [[ "$_update_type" == A ]]; then
                local _file=$_file_refs
                [[ -n "$_file" ]] || continue
                _build_should_exclude "$_file" && continue
                log_debug "  $_file added"
                _update_core_files_to_unpack+=("$_file")
                _update_core_files_to_remove=(${_update_core_files_to_remove:#"$_file"})

            elif [[ "$_update_type" == C<-> ]]; then
                local _dst_file=${_file_refs#*$'\t'}
                [[ -n "$_dst_file" ]] || continue
                _build_should_exclude "$_dst_file" && continue
                log_debug "  $_dst_file copied"
                _update_core_files_to_remove=(${_update_core_files_to_remove:#"$_dst_file"})
                _update_core_files_to_unpack+=("$_dst_file")

            elif [[ "$_update_type" == R<-> ]]; then
                local _src_file=${_file_refs%%$'\t'*}
                local _dst_file=${_file_refs#*$'\t'}
                [[ -n "$_dst_file" ]] || continue
                log_debug "  $_dst_file renamed (from $_src_file)"
                _update_core_files_to_unpack=(${_update_core_files_to_unpack:#"$_src_file"})
                _build_should_exclude "$_src_file" || \
                _update_core_files_to_remove+=("$_src_file")
                _build_should_exclude "$_dst_file" || \
                _update_core_files_to_unpack+=("$_dst_file")

            elif [[ "$_update_type" == D ]]; then
                local _file=$_file_refs
                [[ -n "$_file" ]] || continue
                _build_should_exclude "$_file" && continue
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

    # If the component is already at the new target (advanced independently,
    # e.g. via shell-hook or manual pull), there is nothing to pull.
    # Check the component's current position against _new_comp so the hint
    # is never set and hooks need no per-topology guard of their own.
    local _current_comp
    case "$_topology" in
        subtree)
            _update_core_read_sha_marker "$_comp_dir" 2>/dev/null
            _current_comp="$REPLY"
            ;;
        submodule|standalone|*)
            _current_comp=$(git -C "$_comp_dir" rev-parse HEAD 2>/dev/null)
            ;;
    esac
    [[ -n "$_current_comp" && "$_current_comp" == "$_new_comp" ]] && return 1

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
    # Per-repo stash consent cache.  Keyed by canonicalised repo path.
    # Values: "y" = user consented to stash, "n" = user declined.
    # Populated on first prompt per repo; reused for subsequent prompts
    # within the same update run so the user is only asked once per repo.
    typeset -gA  _dotfiler_stash_consent
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
        _update_core_get_release_channel \
        _update_core_semver_tag_p \
        _update_core_resolve_latest_semver_tag_sha \
        _update_core_component_tip_range \
        _update_core_has_typed_input \
        _update_core_acquire_lock \
        _update_core_release_lock \
        _update_core_write_timestamp \
        _update_core_safe_rm \
        _update_core_is_available_fetch \
        _update_core_list_submodule_paths \
        _update_core_get_parent_root \
        _update_core_detect_deployment \
        _update_core_sha_marker_path \
        _update_core_read_sha_marker \
        _update_core_write_sha_marker \
        _update_core_github_api_get \
        _update_core_extract_github_repo \
        _update_core_resolve_remote_sha \
        _update_core_check_dirty \
        _update_core_prompt_dirty \
        _update_core_maybe_stash \
        _update_core_pop_stash \
        _update_core_maybe_rebase \
        _update_core_component_pull_standalone \
        _update_core_component_pull_submodule \
        _update_core_component_pull_subtree \
        _update_core_component_post_marker \
        _update_core_check_foreign_staged \
        _update_core_commit_parent \
        _update_core_should_update \
        _update_core_is_available \
        _update_core_get_dotfiler_subtree_config \
        _update_core_get_in_tree_commit_mode \
        _update_core_get_update_frequency \
        _update_core_resolve_subtree_spec \
        _update_core_is_available_subtree \
        _update_core_is_dotfiler_available \
        _update_core_build_file_lists \
        _update_core_ext_marker_path \
        _update_core_read_ext_marker \
        _update_core_write_ext_marker \
        _update_core_resolve_component_range \
        _update_core_init_registry \
        _update_register_hook \
        2>/dev/null

    # Registry arrays — may not exist if _update_core_init_registry was never called
    unset _dotfiler_registered_hooks 2>/dev/null
    unset _dotfiler_hook_check_fn _dotfiler_hook_plan_fn \
          _dotfiler_hook_pull_fn _dotfiler_hook_unpack_fn \
          _dotfiler_hook_post_fn _dotfiler_hook_cleanup_fn \
          _dotfiler_hook_component_dir _dotfiler_hook_topology \
          _dotfiler_hook_setup_fn _dotfiler_stash_consent 2>/dev/null

    unset -f _update_core_cleanup 2>/dev/null
}
