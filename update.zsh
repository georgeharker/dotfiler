#!/bin/zsh

# update.zsh — topology-aware self-update for dotfiler scripts, then apply
# dotfiles updates from git history.
#
# Intended to be EXEC'D, not sourced.  Runs in its own subshell.
#
# Phase-separated execution model:
#   dotfiler phase (from update_self.zsh):
#     INIT    — detect topology of dotfiler scripts directory
#     PLAN    — check availability of dotfiler scripts update
#     PULL    — git pull/submodule/subtree for dotfiler scripts
#     UNPACK  — no-op for now (scripts not symlinked into $HOME)
#
#   dotfiles + hooks phases (from update.zsh):
#     PLAN    — fetch, compute ranges, build file lists; source component hooks
#               so they register into _dotfiler_registered_hooks / _dotfiler_hook_*_fn
#               then call each hook's plan_fn in-process (no git writes, no subprocesses)
#     PULL    — all git operations (main repo + all components) in registration order
#     UNPACK  — all setup.zsh calls after every repo is at new HEAD
#     POST    — commit parent pointers, warn about install scripts, cleanup
#
# Flags: -D/--dry-run, -q/--quiet, -v/--verbose, -f/--force,
#        -c/--commit-hash, -r/--range,
#        --update-phases=<phase> (dotfiler|dotfiles|hooks; repeatable; default=all)
#
# Range/commit-hash targets the main dotfiles repo; component hooks derive their
# own ranges from the dotfiles history via marker files (see _update_phase_plan).
# Future work: --component=<name> to target a single hook with an explicit range.
#
# Release-channel zstyle:
#   zstyle ':dotfiler:update' release-channel  release   # release (default) | any
#
#   release (default) — self-directed (Phase 2) updates only advance to semver tags
#                    matching v<N>.<N>.<N>[...].  Applies to both the dotfiler
#                    scripts repo and to zdot (via ':zdot:update' release-channel).
#                    Phase 1 (dotfiles-directed) is unaffected.
#   any            — advance to the branch tip (previous behaviour).

emulate -L zsh
# PIPE_FAIL and NO_UNSET are useful hardening; ERR_EXIT is intentionally
# omitted — this script does deliberate error recovery (subtree pull can fail
# and we continue) so ERR_EXIT would abort those paths prematurely.
setopt PIPE_FAIL NO_UNSET

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

script_name="${${(%):-%x}:a}"
helper_script_dir="${script_name:h}"

source "${helper_script_dir}/helpers.zsh"  # also sources logging.zsh
source "${helper_script_dir}/update_core.zsh"
    # Source setup_core early so unpack phases use the pre-pull version of the
    # code.  The source just defines functions; all mutable state is set up
    # inside setup_core_main → _setup_init on each call and discarded on return.
source "${helper_script_dir}/setup_core.zsh"

dotfiles_dir=$(find_dotfiles_directory)
script_dir=$(find_dotfiles_script_directory)

# ---------------------------------------------------------------------------
# _update_parse_args "$@"
#
# Parse flags into module-level globals consumed by phase functions.
# Sets: quiet[], verbose[], force[], dry_run[], commit_hash[], range[],
#       _update_phases[], _update_range_mode
#       _dry_run (int), _force (int) — for update_self topology functions
# ---------------------------------------------------------------------------

function _update_parse_args() {
    commit_hash=()
    range=()
    _update_phases=()

    function _update_usage(){
        echo "Usage: ${script_name} [-D|--dry-run] [-q|--quiet] [-v|--verbose] [-d|--debug] [-f|--force]"
        echo "                      [-c|--commit-hash <hash>] [-r|--range <range>]"
        echo "                      [--update-phases=<dotfiler|dotfiles|hooks> ...]"
        echo "  --update-phases  Restrict to named phases (repeatable). Default: all."
        echo "  -c/--commit-hash and -r/--range target the main dotfiles repo."
        echo "  Component hook ranges are derived from the dotfiles history."
    }

    zmodload zsh/zutil
    zparseopts -D -E - \
        q=quiet -quiet=quiet \
        v=verbose -verbose=verbose \
        d=debug_flag -debug=debug_flag \
        f=force -force=force \
        c+:=commit_hash -commit-hash+:=commit_hash \
        r+:=range -range+:=range \
        D=dry_run -dry-run=dry_run \
        -update-phases+:=_update_phases_raw || { _update_usage; unfunction _update_usage; return 1; }

    unfunction _update_usage

    commit_hash=("${(@)commit_hash:#-c}")
    commit_hash=("${(@)commit_hash:#--commit-hash}")
    range=("${(@)range:#-r}")
    range=("${(@)range:#--range}")

    # Strip --update-phases tokens, leaving only the values
    _update_phases=("${(@)_update_phases_raw:#--update-phases}")

    [[ ${#quiet[@]} -gt 0 ]]      && quiet_mode=true
    [[ ${#verbose[@]} -gt 0 ]]    && export DOTFILER_VERBOSE=1
    [[ ${#debug_flag[@]} -gt 0 ]] && export DOTFILER_DEBUG=1

    # True when a specific commit or range was given — skips the git pull
    # (repo is already at the target) and drives component range resolution.
    # Future: --component=<name> will extend this to target a single hook.
    _update_range_mode=false
    [[ ${#range[@]} -gt 0 || ${#commit_hash[@]} -gt 0 ]] \
        && _update_range_mode=true

    # Integer forms used by _update_dotfiler_pull topology functions.
    _dry_run=0; [[ ${#dry_run[@]} -gt 0 ]] && _dry_run=1
    _force=0;   [[ ${#force[@]} -gt 0 ]]   && _force=1
    return 0
}

# ---------------------------------------------------------------------------
# _update_should_run_phase <phase>
#
# Returns 0 if the named phase should run.
# If _update_phases is empty (no --update-phases flags), all phases run.
# ---------------------------------------------------------------------------

function _update_should_run_phase() {
    [[ ${#_update_phases[@]} -eq 0 ]] && return 0
    [[ ${_update_phases[(i)$1]} -le ${#_update_phases[@]} ]] && return 0
    return 1
}

# ===========================================================================
# DOTFILER PHASE FUNCTIONS (from update_self.zsh)
# ===========================================================================

# ---------------------------------------------------------------------------
# Detect deployment topology
# ---------------------------------------------------------------------------

function _update_dotfiler_init() {
    verbose "update_self: init begin (script_dir=${script_dir})"

    _update_core_get_dotfiler_subtree_config
    _dotfiler_subtree_spec=$reply[1]
    _dotfiler_subtree_url=$reply[2]

    log_debug "update_self: subtree-spec=${_dotfiler_subtree_spec} subtree-url=${_dotfiler_subtree_url}"

    _update_core_detect_deployment "$script_dir" "$_dotfiler_subtree_spec"
    _dotfiler_topology=$REPLY

    # Stamp written after a successful pull in each topology branch.
    _dotfiler_self_stamp="${XDG_CACHE_DIR:-$HOME/.cache}/dotfiler/dotfiler_scripts_update"

    verbose "update_self: topology=${_dotfiler_topology}"
    log_debug "update_self: stamp=${_dotfiler_self_stamp}"

    verbose "update_self: init done (topology=${_dotfiler_topology})"

    # Register dotfiler immediately after main (main registered at call site
    # before _update_dotfiler_init is called), preserving main → dotfiler →
    # hook-file hooks dispatch order.
    # check_fn is empty — availability checking lives in check_update.zsh.
    _update_register_hook dotfiler \
        '' \
        _update_dotfiler_plan \
        _update_dotfiler_pull \
        _update_dotfiler_unpack \
        _update_dotfiler_post \
        _update_dotfiler_cleanup \
        "$script_dir" \
        "$_dotfiler_topology"
}


# ---------------------------------------------------------------------------
# _update_dotfiler_plan [--phase=dotfiles|components]
#
# Phase-aware plan function for the dotfiler scripts.  Called by the hook
# dispatch loop in _update_phase_plan — receives --phase= the same way
# hook plan_fn's do.
#
# --phase=dotfiles  (Phase 1, parent-directed)
#   Uses _dotfiler_hint_range_dotfiler resolved from dotfiles history.
#   If no hint: no-ops cleanly; Phase 2 will self-direct if upstream is ahead.
#
# --phase=components  (Phase 2, self-directed)
#   Checks own upstream, computes tip range, builds file lists.
#
# No --phase arg: treated as components (dotfiler-only run).
# ---------------------------------------------------------------------------

function _update_dotfiler_plan() {
    local _phase=components
    [[ "${1:-}" == --phase=* ]] && _phase="${1#--phase=}"

    verbose "update_self: plan begin (topology=${_dotfiler_topology} phase=${_phase})"
    typeset -ga _dotfiler_plan_dotfiler_to_unpack _dotfiler_plan_dotfiler_to_remove

    # Sentinel: empty range = nothing to do (mirrors zdot convention).
    # pull/post/unpack all guard on [[ -z "$_dotfiler_plan_dotfiler_range" ]].
    _dotfiler_plan_dotfiler_range=""
    _dotfiler_plan_dotfiler_topology="$_dotfiler_topology"
    _dotfiler_plan_dotfiler_pull_outcome=skip

    # ── Determine old/new SHAs and remote/branch ──────────────────────────
    local _old="" _new="" _remote="" _branch=""

    if [[ "$_phase" == dotfiles ]]; then
        # Phase 1: use hint range resolved from dotfiles history, if available.
        local _hint="${_dotfiler_hint_range_dotfiler:-}"
        if [[ -z "$_hint" ]]; then
            verbose "update_self: plan: phase=dotfiles — no hint (dotfiles unchanged or no marker yet)"
            return 0
        fi
        # subdir/none: parent pull already advanced scripts — nothing to do.
        case $_dotfiler_topology in
            subdir|none|*)
                verbose "update_self: plan: phase=dotfiles topology=${_dotfiler_topology} — parent manages scripts"
                return 0
                ;;
            standalone|submodule|subtree)
                ;;
        esac
        _old="${_hint%%..*}"
        _new="${_hint##*..}"
        # Fetch to materialise the component SHAs locally before diffing.
        if [[ "$_dotfiler_topology" == subtree ]]; then
            _remote="$_dotfiler_subtree_url"
            _branch="${_dotfiler_subtree_spec#* }"
        else
            _remote=$(_update_core_get_default_remote "$script_dir")
            _branch=$(_update_core_get_default_branch "$script_dir" "$_remote")
        fi
        log_debug "update_self: plan: phase=dotfiles fetching ${_remote}/${_branch} to materialise ${_new}"
        local _fetch_err
        _fetch_err=$(git -C "$script_dir" fetch -q "$_remote" "$_branch" 2>&1 >/dev/null) || \
            log_debug "update_self: plan: fetch ${_remote}/${_branch} failed: ${_fetch_err}"
        verbose "update_self: plan: phase=dotfiles — using hint range ${_hint}"

    else
        # Phase 2 / standalone run: self-directed, check own upstream.
        local _available=1
        _update_core_is_dotfiler_available \
            "$script_dir" "$_dotfiler_subtree_spec" "$_dotfiler_subtree_url" \
            && _available=0

        if (( _available != 0 && ! _force )); then
            verbose "update_self: plan done — dotfiler up to date"; info "dotfiler: up to date"; return 0
        fi

        # Compute tip range for file-list building.
        # When force is active and nothing is available, we still need
        # remote/branch for pull to use — resolve them unconditionally.
        case $_dotfiler_topology in
            subtree)
                _update_core_resolve_subtree_spec "$script_dir" \
                    "$_dotfiler_subtree_spec" "$_dotfiler_subtree_url" || {
                    error "update_self: plan: could not resolve subtree spec"; return 1
                }
                _remote="$reply[1]" _branch="$reply[2]"
                _update_core_component_tip_range "$script_dir" subtree \
                    "$_dotfiler_subtree_url" "$_branch" --scope ':dotfiler:update'
                ;;
            *)
                _remote=$(_update_core_get_default_remote "$script_dir")
                _branch=$(_update_core_get_default_branch "$script_dir" "$_remote")
                _update_core_component_tip_range "$script_dir" "$_dotfiler_topology" \
                    "" "" --scope ':dotfiler:update'
                ;;
        esac
        local _tip_range="$REPLY"
        if [[ -z "$_tip_range" ]]; then
            if (( ! _force )); then
                verbose "update_self: plan done — dotfiler up to date"; info "dotfiler: up to date"; return 0
            fi
            verbose "update_self: plan: up to date but force active — populating plan vars"
            _old=$(git -C "$script_dir" rev-parse HEAD 2>/dev/null) || _old=""
            _new="$_old"
        else
            _old="${_tip_range%%..*}"
            _new="${_tip_range##*..}"
        fi
    fi

    # ── Store context for pull/post to consume ────────────────────────────
    # Avoids re-deriving remote/branch/parent in each subsequent phase fn.
    # Stored unconditionally so force mode has valid context even when old==new.
    _dotfiler_plan_dotfiler_remote="$_remote"
    _dotfiler_plan_dotfiler_branch="$_branch"
    _dotfiler_plan_dotfiler_subtree_spec="$_dotfiler_subtree_spec"
    _dotfiler_plan_dotfiler_subtree_url="$_dotfiler_subtree_url"

    # ── _old == _new guard ────────────────────────────────────────────────
    # Can occur when hint resolution gives identical SHAs (e.g. marker already
    # matches remote). Treat as nothing to do, not as an error.
    if [[ "$_old" == "$_new" ]]; then
        if (( ! _force )); then
            log_debug "update_self: plan: old==new (${_old[1,12]}) — nothing to do"
            return 0
        fi
        log_debug "update_self: plan: old==new (${_old[1,12]}) but force active"
    fi

    # ── Build file lists and set range sentinel ───────────────────────────
    local _range="${_old}..${_new}"
    _update_core_build_file_lists "$script_dir" "$_range" || \
        warn "update: file list unavailable for dotfiler — unpack may be incomplete"
    _dotfiler_plan_dotfiler_to_unpack=("${_update_core_files_to_unpack[@]}")
    _dotfiler_plan_dotfiler_to_remove=("${_update_core_files_to_remove[@]}")
    log_debug "update_self: plan: ${#_dotfiler_plan_dotfiler_to_unpack} to unpack," \
        "${#_dotfiler_plan_dotfiler_to_remove} to remove"

    # Set sentinel last — non-empty range signals "update available" to all
    # downstream phase functions and to the _update_phase_pull skip gate.
    _dotfiler_plan_dotfiler_range="$_range"
    verbose "update_self: plan done (range=${_range})"
}

# ---------------------------------------------------------------------------
# _update_dotfiler_pull [--phase=dotfiles|components]
#
# Perform the actual git operations to update the scripts dir.
# Phase 1 (dotfiles): pin to the exact SHA resolved from dotfiles history.
# Phase 2 (components): advance to remote tip.
#
# Reads all context from _dotfiler_plan_dotfiler_* — no re-derivation.
# Writes failure stamps inline (pull is the only phase that runs on error).
# Success stamps are written by post after marker/pointer work completes.
# ---------------------------------------------------------------------------

function _update_dotfiler_pull() {
    local _phase=components
    [[ "${1:-}" == --phase=* ]] && _phase="${1#--phase=}"

    local _topology="${_dotfiler_plan_dotfiler_topology:-$_dotfiler_topology}"
    local _range="${_dotfiler_plan_dotfiler_range:-}"
    local _remote="${_dotfiler_plan_dotfiler_remote:-}"
    local _branch="${_dotfiler_plan_dotfiler_branch:-}"

    # Reset outcome from any prior run.
    _dotfiler_plan_dotfiler_pull_outcome=skip

    # Empty range = plan found nothing to do.
    if [[ -z "$_range" ]]; then
        log_debug "update_self: pull: nothing planned — skipping"
        return 0
    fi

    # Resolve pull target: Phase 1 pins to exact SHA; Phase 2 uses remote tip.
    local _target_ref="${_remote}/${_branch}"
    if [[ "$_phase" == dotfiles ]]; then
        _target_ref="${_range#*..}"
    fi

    verbose "update_self: pull begin (topology=${_topology} phase=${_phase} target=${_target_ref[1,12]})"

    if (( _dry_run )); then
        case $_topology in
            standalone)
                if [[ "$_phase" == dotfiles ]]; then
                    info "update_self: [dry-run] would: git merge --ff-only ${_target_ref[1,12]} (rebase if needed)"
                else
                    info "update_self: [dry-run] would: git pull --ff-only --autostash ${_remote} ${_branch}"
                fi
                ;;
            submodule)
                _update_core_get_parent_root "$script_dir"
                local _parent="${reply[1]}"
                local _submod_root
                _submod_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)
                local _rel=${_submod_root#${_parent}/}
                if [[ "$_phase" == dotfiles ]]; then
                    info "update_self: [dry-run] would: git submodule update -- ${_rel} (ancestry-checked)"
                else
                    info "update_self: [dry-run] would: git submodule update --remote -- ${_rel}"
                fi
                ;;
            subtree)
                if [[ "$_phase" == dotfiles ]]; then
                    info "update_self: [dry-run] subtree phase=dotfiles — no-op (parent already current)"
                else
                    _update_core_get_parent_root "$script_dir"
                    local _parent="${reply[1]}"
                    local _rel=${${script_dir:A}#${_parent:A}/}
                    info "update_self: [dry-run] would: git subtree pull --prefix=${_rel} ${_remote} ${_branch} --squash"
                fi
                ;;
        esac
        verbose "update_self: pull done (dry-run)"
        return 0
    fi

    case $_topology in

        # -------------------------------------------------------------------
        standalone)
        # -------------------------------------------------------------------
            _update_core_component_pull_standalone \
                "$script_dir" "$_target_ref" "$_remote" "$_branch" "$_phase" || {
                error "update_self: standalone pull failed."
                _update_core_write_timestamp "$_dotfiler_self_stamp" 1 "standalone pull failed"
                return 1
            }
            _dotfiler_plan_dotfiler_pull_outcome=$REPLY
            ;;

        # -------------------------------------------------------------------
        submodule)
        # -------------------------------------------------------------------
            _update_core_get_parent_root "$script_dir"
            if [[ "${reply[2]}" != superproject ]]; then
                error "update_self: cannot find parent repo for submodule."
                return 1
            fi
            local _parent="${reply[1]}"
            local _submod_root
            _submod_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)
            local _rel=${_submod_root#${_parent}/}
            log_debug "update_self: submodule parent=${_parent} rel=${_rel}"
            _update_core_component_pull_submodule \
                "$_parent" "$_rel" "$_target_ref" "$_phase" || {
                error "update_self: submodule pull failed."
                _update_core_write_timestamp "$_dotfiler_self_stamp" 1 "submodule pull failed"
                return 1
            }
            _dotfiler_plan_dotfiler_pull_outcome=$REPLY
            ;;

        # -------------------------------------------------------------------
        subtree)
        # -------------------------------------------------------------------
            _update_core_get_parent_root "$script_dir"
            if [[ "${reply[2]}" == none ]]; then
                error "update_self: cannot find parent repo for subtree."
                return 1
            fi
            local _parent="${reply[1]}"
            local _rel=${${script_dir:A}#${_parent:A}/}
            log_debug "update_self: subtree parent=${_parent} rel=${_rel}"
            _update_core_component_pull_subtree \
                "$_parent" "$_rel" "$_remote" "$_branch" "$_phase" || {
                error "update_self: subtree pull failed."
                _update_core_write_timestamp "$_dotfiler_self_stamp" 1 "subtree pull failed"
                return 1
            }
            _dotfiler_plan_dotfiler_pull_outcome=$REPLY
            ;;

        # -------------------------------------------------------------------
        subdir|none|*)
        # -------------------------------------------------------------------
            verbose "update_self: pull: topology=${_topology} — nothing to do"
            ;;
    esac
    verbose "update_self: pull done"
}

# ---------------------------------------------------------------------------
# _update_dotfiler_post [--phase=dotfiles|components]
#
# Post-pull step: write SHA markers and/or commit parent repo pointers,
# then write the success stamp.
#
# Phase 1 (dotfiles): dotfiles history is already authoritative — do NOT
#   write markers or commit parent pointers (mirrors zdot behaviour).
#   Stamp is also skipped; Phase 2 post will write it after completing.
# Phase 2 (components): write markers, commit parent, write success stamp.
#
# Reads context from _dotfiler_plan_dotfiler_* vars set by plan.
# ---------------------------------------------------------------------------

function _update_dotfiler_post() {
    local _phase=components
    [[ "${1:-}" == --phase=* ]] && _phase="${1#--phase=}"

    local _range="${_dotfiler_plan_dotfiler_range:-}"
    local _topology="${_dotfiler_plan_dotfiler_topology:-$_dotfiler_topology}"
    local _outcome="${_dotfiler_plan_dotfiler_pull_outcome:-skip}"

    verbose "update_self: post begin (topology=${_topology} phase=${_phase} outcome=${_outcome})"

    # Empty range = plan found nothing to do — no pointer to commit.
    if [[ -z "$_range" ]]; then
        log_debug "update_self: post: no changes planned — skipping"
        return 0
    fi

    local _new="${_range#*..}"

    local _mode
    _update_core_get_in_tree_commit_mode ':dotfiler:update'; _mode=$REPLY

    case $_topology in
        standalone|submodule|subtree)
            _update_core_get_parent_root "$script_dir"
            local _parent="${reply[1]}"
            local _rel
            if [[ "$_topology" == submodule ]]; then
                local _submod_root
                _submod_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)
                _rel=${_submod_root#${_parent}/}
            else
                _rel=${${script_dir:A}#${_parent:A}/}
            fi
            log_debug "update_self: post: parent=${_parent} rel=${_rel} new=${_new[1,12]}"
            if (( _dry_run )); then
                _update_core_component_post_marker \
                    "$script_dir" "$_parent" "$_rel" "$_new" \
                    "$_topology" "$_mode" "$_phase" "$_outcome"
                info "dotfiler: [dry-run] post skipped"
            else
                _update_core_component_post_marker \
                    "$script_dir" "$_parent" "$_rel" "$_new" \
                    "$_topology" "$_mode" "$_phase" "$_outcome" || {
                    error "update_self: post marker/commit failed."
                    return 1
                }
                _update_core_write_timestamp "$_dotfiler_self_stamp" 0 ""
                info "dotfiler: updated"
            fi
            ;;
        subdir|none|*)
            verbose "update_self: post: topology=${_topology} — nothing to do"
            ;;
    esac
    verbose "update_self: post done"
}

# ---------------------------------------------------------------------------
# _update_dotfiler_unpack
#
# No-op for now — dotfiler scripts are not symlinked into $HOME.
# Framework is in place for future component install support.
# ---------------------------------------------------------------------------

function _update_dotfiler_unpack() {
    # Disabled: dotfiler scripts are not symlinked into $HOME.
    # TODO: re-enable once dotfiler_exclude is verified and find/link
    #       behaviour against the scripts dir is confirmed safe.
    #
    # local -a _setup_args=(
    #     -u
    #     ${dry_run:+"-D"}
    #     ${quiet:+"-q"}
    #     --repo-dir "${script_dir}"
    #     --link-dest "${HOME}"
    #     --excludes "${script_dir}/dotfiler_exclude"
    # )
    # (
    #     setup_core_main "${_setup_args[@]}"
    # )
    return 0
}

# ---------------------------------------------------------------------------
# _update_dotfiler_cleanup — called by _update_cleanup for dotfiler's slot
# ---------------------------------------------------------------------------
# Unsets any remaining dotfiler-specific state that falls outside the
# _dotfiler_plan_* / _dotfiler_hint_range_* globs cleared by _update_plan_reset.
_update_dotfiler_cleanup() {
    unset _dotfiler_topology _dotfiler_subtree_spec _dotfiler_subtree_url \
          _dotfiler_self_stamp
}

# ===========================================================================
# DOTFILES + HOOKS PHASE FUNCTIONS (from update.zsh)
# ===========================================================================

# ---------------------------------------------------------------------------
# Hook registry
# ---------------------------------------------------------------------------
# Hooks source into this process and call _update_register_hook to declare
# their phase functions.  dotfiler owns the registry; hooks never iterate it.
#
# Hook registry lives in update_core.zsh — shared with setup.zsh.
# See _update_core_init_registry and _update_register_hook there.

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

function _update_phase_plan(){
    verbose "update: phase plan: begin"
    # --phase=dotfiles : Phase 1 — parent-directed. Source hooks, resolve
    #                    component ranges from dotfiles git history.
    # --phase=components : Phase 2 — self-directed. Hooks already sourced;
    #                    each component fetches own remote and advances to tip.
    local _phase=dotfiles
    [[ "${1:-}" == --phase=* ]] && { _phase="${1#--phase=}"; shift; }

    # ── Main repo range computation ──────────────────────────────────────
    # Phase dotfiles only. In Phase 2, main is already registered and its
    # range already computed; components self-direct independently.
    if [[ "$_phase" == dotfiles ]]; then
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
            verbose "update: Using ${_update_default_remote}/${_update_default_branch} mode: ${_update_diff_range}"
        fi

        # ── Main repo file lists ──────────────────────────────────────────
        typeset -gaU _update_core_files_to_unpack _update_core_files_to_remove
        _update_core_build_file_lists "$dotfiles_dir" "$_update_diff_range" || \
            warn "update: file list unavailable for dotfiles — unpack may be incomplete"
        _dotfiler_plan_main_to_unpack=("${_update_core_files_to_unpack[@]}")
        _dotfiler_plan_main_to_remove=("${_update_core_files_to_remove[@]}")

        _dotfiler_plan_main_repo_dir="$dotfiles_dir"
        _dotfiler_plan_main_link_dest="$HOME"

        verbose "update: phase plan: main repo" \
            "${#_dotfiler_plan_main_to_unpack[@]} to unpack" \
            "${#_dotfiler_plan_main_to_remove[@]} to remove"
        if (( ${#_dotfiler_plan_main_to_unpack[@]} > 0 \
            || ${#_dotfiler_plan_main_to_remove[@]} > 0 )); then
            info "dotfiles: ${#_dotfiler_plan_main_to_unpack[@]} to update," \
                "${#_dotfiler_plan_main_to_remove[@]} to remove"
        else
            info "dotfiles: up to date"
        fi
    fi

    # ── Component hooks ───────────────────────────────────────────────────
    # Phase dotfiles: resolve each hook's component range from the dotfiles
    # git history at old_sha..new_sha via marker files / submodule pointers,
    # set _dotfiler_hint_range_<name>, then call plan_fn --phase=dotfiles.
    # Hook uses the hint to pin the target SHA to exactly what dotfiles records.
    # If dotfiles did not move (old==new), there is no Phase 1 hint to resolve —
    # plan_fn still runs but will find an empty range and no-op cleanly.
    # If resolution fails (no marker yet / first run / SHA unchanged), plan_fn
    # runs with no hint and no-ops cleanly; Phase 2 will self-direct.
    # Phase components: hooks already sourced and registered; each plan_fn
    # fetches its own remote and computes its own tip range.

    local _hooks_dir
    zstyle -s ':dotfiler:hooks' dir _hooks_dir \
        || _hooks_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiler/hooks"
    [[ -d "$_hooks_dir" ]] || return 0

    # ── Source each hook — each calls _update_register_hook ──────────────
    # Skipped in Phase 2 — hooks are already registered and fns defined.
    # _old_sha/_new_sha only meaningful in Phase 1 — scoped here accordingly.
    local _old_sha="" _new_sha=""
    if [[ "$_phase" == dotfiles ]]; then
        _old_sha="${_update_diff_range%%..*}"
        _new_sha="${_update_diff_range#*..}"
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
    fi

    # ── Pre-fetch component remotes (Phase 1 only) ───────────────────────
    # Mirrors the main dotfiles fetch above. Ensures both old and new SHAs
    # are present in each component's local object store before plan_fn calls
    # _update_core_build_file_lists. Subtree: Phase 1 no-op (parent pull
    # already brought content). Subdir: no separate remote.
    local _name _fn
    if [[ "$_phase" == dotfiles ]]; then
        for _name in "${_dotfiler_registered_hooks[@]}"; do
            [[ "$_name" == main ]] && continue
            local _comp_dir="${_dotfiler_hook_component_dir[$_name]:-}"
            local _topology="${_dotfiler_hook_topology[$_name]:-}"
            [[ -n "$_comp_dir" ]] || continue
            [[ "$_topology" == submodule || "$_topology" == standalone ]] || continue
            local _remote _branch
            _remote=$(_update_core_get_default_remote "$_comp_dir")
            _branch=$(_update_core_get_default_branch "$_comp_dir" "$_remote")
            [[ -n "$_remote" && -n "$_branch" ]] || continue
            verbose "update: phase 1 plan: pre-fetching ${_name} remote ${_remote}/${_branch}"
            local _fetch_err
            _fetch_err=$(git -C "$_comp_dir" fetch -q "$_remote" "$_branch" 2>&1 >/dev/null) || {
                error "update: phase 1 plan: pre-fetch for ${_name} failed — cannot proceed"
                log_debug "update: phase 1 plan: pre-fetch error: ${_fetch_err}"
                return 1
            }
        done
    fi

    # ── Call each hook's plan_fn in-process ──────────────────────────────
    for _name in "${_dotfiler_registered_hooks[@]}"; do
        [[ "$_name" == main ]] && continue
        _fn="${_dotfiler_hook_plan_fn[$_name]:-}"
        [[ -z "$_fn" ]] && continue

        local _comp_dir="${_dotfiler_hook_component_dir[$_name]:-}"
        local _topology="${_dotfiler_hook_topology[$_name]:-}"

        # Pre-declare plan arrays (belt and braces — hook plan_fn also declares
        # them, but guard here so report block is safe if plan_fn exits early).
        typeset -gaU "_dotfiler_plan_${_name}_to_unpack" \
                     "_dotfiler_plan_${_name}_to_remove"

        if [[ "$_phase" == components ]]; then
            # Phase components: self-directed. No hint, no dotfiles reference.
            # Each hook's plan_fn uses _update_core_component_tip_range internally.
            verbose "update: phase 2 plan: calling plan_fn for ${_name} (self-directed)"
            "$_fn" --phase=components
        else
            # Phase dotfiles: attempt to resolve the component's range from
            # dotfiles git history at old_sha..new_sha via marker files /
            # submodule pointers. Always call plan_fn — it is null-range aware
            # and will no-op cleanly if there is nothing to do.
            #
            # Resolution outcomes:
            #   hint set   — dotfiles moved and recorded a new component SHA;
            #                plan_fn pins to exactly what dotfiles records
            #   no hint    — dotfiles didn't move, marker missing, or SHA
            #                unchanged; plan_fn runs with --phase=dotfiles and
            #                no hint, setting an empty range (nothing to do in
            #                Phase 1; Phase 2 will self-direct to tip)
            if [[ -z "$_comp_dir" || -z "$_topology" ]]; then
                warn "update: hook '${_name}' did not register component_dir/topology — cannot resolve range hint"
            elif [[ "$_old_sha" != "$_new_sha" ]]; then
                # Attempt to resolve the component range from dotfiles history.
                # No merge-base guard here — resolve_component_range handles the
                # case where old==new component SHA (returns 1) and the backwards
                # case (diverged/ahead) degrades to an empty hint safely.
                _update_core_resolve_component_range \
                    "$dotfiles_dir" "$_old_sha" "$_new_sha" \
                    "$_comp_dir" "$_topology"
                if [[ -n "$REPLY" ]]; then
                    verbose "update: resolved ${_name} range from dotfiles: ${REPLY}"
                    typeset -g "_dotfiler_hint_range_${_name}=${REPLY}"
                else
                    verbose "update: ${_name}: dotfiles moved but component SHA unchanged"
                fi
            else
                verbose "update: ${_name}: dotfiles did not move — no Phase 1 hint"
            fi

            verbose "update: phase 1 plan: calling plan_fn for ${_name} (--phase=dotfiles)"
            "$_fn" --phase=dotfiles
        fi

        # Report per-component result. In Phase 2 (components), hooks own their
        # own messaging (they emit "Checking ...", "up to date", "pulling...", etc.)
        # so the framework stays silent for non-main hooks.
        local _display="${_name:#main}"; _display="${_display:-dotfiles}"
        local _plan_u="_dotfiler_plan_${_name}_to_unpack"
        local _plan_r="_dotfiler_plan_${_name}_to_remove"
        local _nu=${#${(P)_plan_u}[@]}
        local _nr=${#${(P)_plan_r}[@]}
        if [[ "$_phase" == dotfiles ]]; then
            if (( _nu > 0 || _nr > 0 )); then
                info "${_display}: ${_nu} files to update, ${_nr} files to remove"
            else
                info "${_display}: up to date"
            fi
        fi
    done

    verbose "update: phase plan: done"
    return 0
}

# ---------------------------------------------------------------------------
# Main repo phase functions
# ---------------------------------------------------------------------------

function _update_main_pull(){
    # Accept --phase=dotfiles|components for interface consistency with component
    # hook pull functions.
    local _phase=dotfiles
    [[ "${1:-}" == --phase=* ]] && { _phase="${1#--phase=}"; shift; }
    [[ ${#dry_run[@]} -gt 0 ]] && { verbose "update: main pull: skipping (dry-run)"; return 0; }
    [[ ${#commit_hash[@]} -gt 0 || ${#range[@]} -gt 0 ]] && { verbose "update: main pull: skipping (range mode)"; return 0; }

    # Phase 2 (components): only pull if at least one component actually updated.
    # Without this gate, phase 2 fetches from component remotes advance origin/main,
    # causing the dotfiles repo to pull arbitrary untagged commits that are unrelated
    # to any component change (e.g. doc-only commits between release tags).
    if [[ "$_phase" == components ]] && (( ! _force )); then
        local _any_updated=0
        local _n
        for _n in "${_dotfiler_registered_hooks[@]}"; do
            [[ "$_n" == main ]] && continue
            local _outcome_var="_dotfiler_plan_${_n}_pull_outcome"
            if [[ "${(P)_outcome_var:-skip}" != skip ]]; then
                _any_updated=1
                break
            fi
        done
        if (( ! _any_updated )); then
            verbose "update: main pull: skipping phase 2 (no component updates)"
            return 0
        fi
    fi
    # Always pull when there are commits in the range, even if no top-level
    # dotfiles changed.  The diff range may contain subtree/submodule pointer
    # updates, exclude-file changes, or other non-dotfile content that needs
    # HEAD to advance.  The unpack phase independently guards on its own lists.
    if (( ! _force )); then
        local _local_sha _remote_sha
        _local_sha=$(git -C "$dotfiles_dir" rev-parse HEAD 2>/dev/null)
        _remote_sha=$(git -C "$dotfiles_dir" rev-parse \
            "${_update_default_remote}/${_update_default_branch}" 2>/dev/null)
        if [[ -n "$_local_sha" && "$_local_sha" == "$_remote_sha" ]]; then
            verbose "update: main pull: skipping (nothing to update)"
            return 0
        fi
    fi
    _update_core_prompt_dirty "$dotfiles_dir" "main pull" || return 1
    info "dotfiles: pulling..."
    verbose "update: main pull: git pull --autostash ${_update_default_remote} ${_update_default_branch}"
    git -C "$dotfiles_dir" pull -q --autostash \
        "$_update_default_remote" "$_update_default_branch" || {
        warn "dotfiles: pull failed"
        return 1
    }
    info "dotfiles: updated"
    verbose "update: main pull: done"
    return 0
}

function _update_main_unpack(){
    local -a _to_remove=("${_dotfiler_plan_main_to_remove[@]}")
    local -a _to_unpack=("${_dotfiler_plan_main_to_unpack[@]}")

    # Nothing planned — guard against missing scalar plan vars.
    if [[ ${#_to_remove[@]} -eq 0 && ${#_to_unpack[@]} -eq 0 ]]; then
        return 0
    fi

    local _link_dest="${_dotfiler_plan_main_link_dest:-}"
    if [[ -z "$_link_dest" ]]; then
        warn "_update_main_unpack: link_dest not set, skipping"
        return 0
    fi

    if [[ ${#_to_remove[@]} -gt 0 ]]; then
        action "Removing files"
        verbose "files to remove: ${_to_remove[*]}"
        local _file _dest
        for _file in "${_to_remove[@]}"; do
            _dest="${_link_dest}/${_file}"
            if [[ -L "$_dest" ]]; then
                action "cleaning up $_dest"
                _update_core_safe_rm "$_dest"
            else
                warn "$_dest is not a symlink, not removing"
            fi
        done
    fi

    if [[ ${#_to_unpack[@]} -gt 0 ]]; then
        action "Unpacking files"
        verbose "files to unpack: ${_to_unpack[*]}"

        # -U = force-unpack (overwrite existing, ignore exclusions)
        # -u = normal unpack
        local _unpack_flag="-u"
        [[ ${#force[@]} -gt 0 ]] && _unpack_flag="-U"

        local -a _setup_args=(
            "$_unpack_flag"
            ${dry_run:+"-D"}
            ${quiet:+"-q"}
            ${debug_flag:+"-g"}
            --repo-dir "${_dotfiler_plan_main_repo_dir}"
            --link-dest "${_link_dest}"
            --excludes "${_dotfiler_plan_main_repo_dir}/dotfiles_exclude"
            "${_to_unpack[@]}"
        )

        # Run in a ( subshell ) — pure fork, namespace discarded on exit.
        # setup_core.zsh is sourced unconditionally at the top of this file so
        # the subshell inherits the pre-pull version of setup_core functions.
        # Do NOT re-source here: a post-pull setup_core.zsh must not mix with
        # the running update state.
        (
            setup_core_main "${_setup_args[@]}"
        )
        return $?
    fi
    return 0
}

function _update_main_post(){
    # Accept --phase=dotfiles|components for interface consistency.
    [[ "${1:-}" == --phase=* ]] && shift
    local -a _to_unpack=("${_dotfiler_plan_main_to_unpack[@]}")
    [[ ${#_to_unpack[@]} -eq 0 ]] && return 0
    local -a _modified_install=()
    local _file
    for _file in "${_to_unpack[@]}"; do
        [[ "$_file" == .nounpack/install/*.zsh ]] && _modified_install+=("$_file")
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
    local _phase=components
    [[ "${1:-}" == --phase=* ]] && { _phase="${1#--phase=}"; shift; }
    local _name _fn
    for _name in "${_dotfiler_registered_hooks[@]}"; do
        _fn="${_dotfiler_hook_pull_fn[$_name]:-}"
        [[ -z "$_fn" ]] && continue
        if [[ "$_name" != main ]]; then
            local _plan_range="_dotfiler_plan_${_name}_range"
            # Skip if nothing planned — no range means the component SHA did not
            # change (or could not be resolved), so there is nothing to pull in
            # either phase.
            if (( ! _force )) && [[ -z "${(P)_plan_range:-}" ]]; then
                verbose "update: phase pull: skipping ${_name} (nothing planned)"
                continue
            fi
        fi
        local _display="${_name:#main}"; _display="${_display:-dotfiles}"
        verbose "update: phase pull: ${_name} -> ${_fn} (phase=${_phase})"
        "$_fn" "--phase=${_phase}" || { warn "${_display}: pull failed"; return 1; }
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
        # Skip if plan found nothing to do for this component
        local _plan_u="_dotfiler_plan_${_name}_to_unpack"
        local _plan_r="_dotfiler_plan_${_name}_to_remove"
        local _nu=${#${(P)_plan_u}[@]}
        local _nr=${#${(P)_plan_r}[@]}
        if (( ! _force && _nu == 0 && _nr == 0 )); then
            verbose "update: phase unpack: skipping ${_name} (nothing planned)"
            continue
        fi
        local _display="${_name:#main}"; _display="${_display:-dotfiles}"
        verbose "update: phase unpack: ${_name} -> ${_fn}"
        info "${_display}: unpacking..."
        "$_fn" || {
            warn "${_display}: unpack failed"
            return 1
        }
    done
    verbose "update: phase unpack: done"
    return 0
}

# ---------------------------------------------------------------------------
# PHASE 4 — POST
# ---------------------------------------------------------------------------

function _update_phase_post(){
    verbose "update: phase post: begin"
    local _phase=components
    [[ "${1:-}" == --phase=* ]] && { _phase="${1#--phase=}"; shift; }
    local _name _fn
    for _name in "${_dotfiler_registered_hooks[@]}"; do
        _fn="${_dotfiler_hook_post_fn[$_name]:-}"
        [[ -z "$_fn" ]] && continue
        verbose "update: phase post: ${_name} -> ${_fn} (phase=${_phase})"
        "$_fn" "--phase=${_phase}" || warn "update: post failed for '${_name}'"
    done
    verbose "update: phase post: done"
    return 0
}

# ---------------------------------------------------------------------------
# _update_cleanup
# ---------------------------------------------------------------------------

function _update_cleanup() {
    unset -f \
        _update_register_hook \
        _update_dotfiler_init \
        _update_dotfiler_plan \
        _update_dotfiler_pull \
        _update_dotfiler_unpack \
        _update_dotfiler_post \
        _update_dotfiler_cleanup \
        _update_phase_plan \
        _update_main_pull \
        _update_main_unpack \
        _update_main_post \
        _update_phase_pull \
        _update_phase_unpack \
        _update_phase_post \
        _update_should_run_phase \
        _update_parse_args \
        _update_cleanup \
        2>/dev/null
    unset -A \
        _dotfiler_hook_check_fn \
        _dotfiler_hook_plan_fn \
        _dotfiler_hook_pull_fn \
        _dotfiler_hook_unpack_fn \
        _dotfiler_hook_post_fn \
        _dotfiler_hook_cleanup_fn \
        _dotfiler_hook_setup_fn \
        _dotfiler_hook_component_dir \
        _dotfiler_hook_topology \
        _dotfiler_stash_consent \
        2>/dev/null
    unset \
        _dotfiler_registered_hooks \
        _dotfiler_topology \
        _dotfiler_subtree_spec \
        _dotfiler_subtree_url \
        _dotfiler_self_stamp \
        2>/dev/null
    _update_core_cleanup
    setup_core_unload
}

# ---------------------------------------------------------------------------
# _update_plan_reset — clear all inter-phase plan and hint state.
# Must be called before Phase 1 and between Phase 1 and Phase 2 to ensure
# no stale vars from a prior run or prior phase influence hook behaviour.
# ---------------------------------------------------------------------------

function _update_plan_reset() {
    unset "${(@k)parameters[(I)_dotfiler_plan_*]}" 2>/dev/null
    unset "${(@k)parameters[(I)_dotfiler_hint_range_*]}" 2>/dev/null
    typeset -gaU _dotfiler_plan_main_to_unpack _dotfiler_plan_main_to_remove
}

# ---------------------------------------------------------------------------
# _update_main
# ---------------------------------------------------------------------------

function _update_main() {
    _update_parse_args "$@" || exit $?
    _update_core_init_registry
    _update_plan_reset

    verbose "update: starting (dotfiles_dir=${dotfiles_dir} script_dir=${script_dir})"
    [[ "$_update_range_mode" == true ]] && \
        verbose "update: range mode active (repo=${dotfiles_dir})"

    # Register hooks early so the dispatch order is fixed:
    # main → dotfiler → hook-file hooks.
    # Registration is independent of file lists — lists are built in
    # _update_phase_plan and stored in _dotfiler_plan_main_* variables.
    if _update_should_run_phase dotfiles || _update_should_run_phase hooks \
        || _update_should_run_phase dotfiler; then
        _update_register_hook main \
            '' \
            '' \
            '_update_main_pull' \
            '_update_main_unpack' \
            '_update_main_post'
    fi

    # Init dotfiler — detects topology, then registers dotfiler into the
    # dispatch system immediately after main.
    if _update_should_run_phase dotfiler; then
        _update_dotfiler_init
    fi

    if _update_should_run_phase dotfiles || _update_should_run_phase hooks \
        || _update_should_run_phase dotfiler; then
        # ── Phase 1: parent-directed ──────────────────────────────────────
        # Dotfiles drives component updates. Ranges are resolved from dotfiles
        # marker files / submodule pointers and all components (including
        # dotfiler) are pinned to exactly the SHA dotfiles records.
        verbose "update: phase 1 (parent-directed) begin"
        info "Checking for updates..."
        _update_phase_plan || exit $?
        _update_phase_pull --phase=dotfiles || exit $?
        _update_phase_unpack
        _update_phase_post --phase=dotfiles

        # ── Phase 2: self-directed ────────────────────────────────────────
        # Component remotes may be ahead of what dotfiles records. Each
        # component (including dotfiler) fetches its own remote and advances
        # to tip. Produces per-component dotfiles commits recording new SHAs.
        # Skipped when --range / --commit-hash was given.
        if [[ "$_update_range_mode" != true ]]; then
            verbose "update: phase 2 (self-directed) begin"
            info "Checking for component updates beyond dotfiles..."
            _update_plan_reset
            _update_phase_plan --phase=components || exit $?
            _update_phase_pull || exit $?
            _update_phase_unpack
            _update_phase_post
        else
            verbose "update: phase 2 skipped (range mode)"
        fi
    fi

    verbose "update: done"
    _update_cleanup
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

[[ $ZSH_EVAL_CONTEXT == *:file* ]] || _update_main "$@"
