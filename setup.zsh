#!/usr/bin/env zsh
# setup.zsh — multi-component-aware setup orchestrator.
#
# Intended to be EXEC'D, not sourced.  Runs in its own subshell.
#
# This is the CLI entry point for `dotfiler setup`.  It sources:
#   helpers.zsh     — path/directory resolution utilities (also sources logging.zsh)
#   setup_core.zsh  — single-repo operations (gitignore, find, link, unpack)
#   update_core.zsh — shared primitives (topology, hook registry)
#
# Basic usage:
#   dotfiler setup -u                  # unpack main dotfiles + all hook components
#   dotfiler setup -i ~/.bashrc        # ingest a file (no hook components involved)
#
# Restrict to specific components with --component:
#   dotfiler setup -u --component zdot         # just zdot
#   dotfiler setup -u --component main         # just main dotfiles
#
# Bootstrap mode (fresh machine / first-time setup):
#   dotfiler setup --bootstrap-hook <path>     # install hook symlink into repo + commit
#   dotfiler setup --bootstrap                 # unpack everything (reads hooks from repo)
#   dotfiler setup --bootstrap-hook <path> --bootstrap  # combined one-liner
#
#   --bootstrap-hook implies --bootstrap (writes into dotfiles repo, not XDG dir).
#   --bootstrap implies -u (unpack) and runs all components.
#   --bootstrap reads hooks from the dotfiles repo's .config/dotfiler/hooks/ rather
#   than the XDG linktree path (which doesn't exist yet on a fresh machine).
#
# Hook components participate by registering a setup_fn via the 10th
# parameter of _update_register_hook.  The setup_fn receives:
#   $1        — "unpack" or "force-unpack"
#   $2 .. $N  — passthrough flags (--dry-run, --quiet, --debug, --yes, --no)

# ---------------------------------------------------------------------------
# Bootstrap: locate ourselves, source dependencies unconditionally.
# This file is exec'd (not sourced) so no ambient environment exists.
# ---------------------------------------------------------------------------
_setup_script_dir="${0:a:h}"

source "${_setup_script_dir}/helpers.zsh"  # also sources logging.zsh

# ---------------------------------------------------------------------------
# Source core libraries
# ---------------------------------------------------------------------------
source "${_setup_script_dir}/setup_core.zsh"
source "${_setup_script_dir}/update_core.zsh"

# ---------------------------------------------------------------------------
# Bootstrap hook symlink installation
# ---------------------------------------------------------------------------
# Install a hook file into ~/.config/dotfiler/hooks/ without needing the
# linktree or a configured shell.  This is the first step of a fresh install:
#
#   dotfiler setup --bootstrap-hook /path/to/zdot/core/dotfiler-hook.zsh
#
# Name derivation (in priority order):
#   1. Filename stem minus "-hook" suffix  e.g. "zdot-hook.zsh" → "zdot"
#   2. If stem is "dotfiler" (generic name), use the grandparent dir name
#      e.g. ".../zdot/core/dotfiler-hook.zsh" → grandparent = "zdot"
#
# Idempotent: if the symlink already points to the same target, succeeds
# quietly.  If it points elsewhere, warns and requires --yes/--force to
# overwrite.
_setup_bootstrap_hook() {
    local hook_path="${1:A}"  # resolve to absolute real path
    local force=${2:-0}
    local hooks_dir="${3:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiler/hooks}"
    local in_dotfiles=${4:-0}
    local dotfiles_dir="${5:-}"

    if [[ ! -f "$hook_path" ]]; then
        error "bootstrap-hook: file not found: $hook_path"
        return 1
    fi

    # Derive component name
    local filename="${hook_path:t}"          # e.g. dotfiler-hook.zsh
    local stem="${filename%-hook.zsh}"       # e.g. dotfiler  OR  zdot
    local name
    if [[ "$stem" == "dotfiler" || "$stem" == "$filename" ]]; then
        # Generic name or no -hook suffix: use grandparent dir
        name="${hook_path:h:h:t}"           # e.g. zdot/core/... → zdot
    else
        name="$stem"
    fi

    if [[ -z "$name" ]]; then
        error "bootstrap-hook: could not derive component name from: $hook_path"
        return 1
    fi

    local dest="${hooks_dir}/${name}.zsh"

    # Compute a relative symlink target from dest's directory to hook_path.
    # Relative links are portable — they survive the dotfiles tree being moved.
    local link_target
    _path_relative_to "$hook_path" "$hooks_dir"
    link_target="$REPLY"

    # Create hooks dir if missing
    if [[ ! -d "$hooks_dir" ]]; then
        log_debug "bootstrap-hook: creating hooks dir: $hooks_dir"
        mkdir -p "$hooks_dir" || {
            error "bootstrap-hook: failed to create hooks dir: $hooks_dir"
            return 1
        }
    fi

    # Check existing symlink / file — compare resolved targets
    if [[ -e "$dest" || -L "$dest" ]]; then
        local existing_target
        existing_target=$(readlink "$dest" 2>/dev/null || echo "(not a symlink)")
        # Normalise: resolve existing target (may be relative or absolute)
        # relative to hooks_dir, then compare real paths.
        local existing_real
        if [[ "$existing_target" == /* ]]; then
            existing_real="${existing_target:A}"
        else
            existing_real="${hooks_dir}/${existing_target}"
            existing_real="${existing_real:A}"
        fi
        if [[ "$existing_real" == "$hook_path" ]]; then
            info "bootstrap-hook: $name already linked to $hook_path"
            return 0
        fi
        if (( ! force )); then
            warn "bootstrap-hook: $dest already exists (→ $existing_target)"
            warn "  Use --yes or --force to overwrite."
            return 1
        fi
        rm -f "$dest"
    fi

    ln -s "$link_target" "$dest" || {
        error "bootstrap-hook: failed to create symlink $dest → $link_target"
        return 1
    }
    info "bootstrap-hook: installed $name → $link_target"

    # If writing into the dotfiles repo, offer to commit so it replicates
    # to other machines on pull.
    (( in_dotfiles )) || return 0

    local _repo_root="${dotfiles_dir}"
    local _rel_dest=${dest#${_repo_root}/}
    local _commit_msg="dotfiler: add ${name} bootstrap hook"

    # -----------------------------------------------------------------------
    # Detect topology and write initial SHA marker if needed.
    #
    # For subtree and standalone topologies the update machinery uses a marker
    # file adjacent to the component directory to track which SHA was last
    # successfully pulled.  On first bootstrap this file doesn't exist yet,
    # which means the first `dotfiler update` cannot resolve the component
    # range.  We write the initial marker here so the repo is in a consistent
    # state from the very first commit.
    #
    # Submodule: no marker needed — the gitlink in .gitmodules is the record.
    # Subdir:    no marker needed — parent repo manages everything.
    #
    # We source the newly-installed hook symlink to let it self-register via
    # _update_register_hook — exactly as update.zsh does.  This gives us the
    # authoritative component_dir and topology from the hook itself rather than
    # any heuristic.  _update_core_init_registry was called at setup_main entry.
    # -----------------------------------------------------------------------
    local -a _extra_add_paths=()
    local _before=${#_dotfiler_registered_hooks}
    source "$dest" 2>/dev/null
    if (( ${#_dotfiler_registered_hooks} > _before )); then
        local _comp_dir="${_dotfiler_hook_component_dir[$name]:-}"
        local _topology="${_dotfiler_hook_topology[$name]:-}"
        log_debug "bootstrap-hook: $name topology=$_topology comp_dir=$_comp_dir"

        local _comp_sha=""
        [[ -n "$_comp_dir" ]] && \
            _comp_sha=$(git -C "$_comp_dir" rev-parse HEAD 2>/dev/null) || _comp_sha=""

        case "$_topology" in
            subtree)
                if [[ -n "$_comp_sha" && -n "$_comp_dir" ]]; then
                    _update_core_write_sha_marker "$_comp_dir" "$_comp_sha" && {
                        _update_core_sha_marker_path "$_comp_dir"
                        local _marker_rel=${REPLY#${_repo_root}/}
                        _extra_add_paths+=("$_marker_rel")
                        info "bootstrap-hook: wrote subtree SHA marker for $name (${_comp_sha[1,12]})"
                    } || warn "bootstrap-hook: could not write subtree SHA marker for $name"
                fi
                ;;
            standalone)
                if [[ -n "$_comp_sha" && -n "$_comp_dir" ]]; then
                    _update_core_write_ext_marker "$_comp_dir" "$_comp_sha" && {
                        _update_core_ext_marker_path "$_comp_dir"
                        local _marker_rel=${REPLY#${_repo_root}/}
                        _extra_add_paths+=("$_marker_rel")
                        info "bootstrap-hook: wrote ext SHA marker for $name (${_comp_sha[1,12]})"
                    } || warn "bootstrap-hook: could not write ext SHA marker for $name"
                fi
                ;;
        esac
    else
        log_debug "bootstrap-hook: $name hook did not register after sourcing — skipping marker"
    fi

    local _do_commit=0
    if (( force )); then
        _do_commit=1
    else
        print -n "bootstrap-hook: commit '$_commit_msg' to $(basename $_repo_root)? [y/N] "
        local _reply
        read -rk1 _reply; print ""
        [[ "$_reply" == [yY] ]] && _do_commit=1
    fi

    if (( _do_commit )); then
        local _stashed=0
        if ! _update_core_maybe_stash "$_repo_root" "bootstrap-hook commit"; then
            warn "bootstrap-hook: skipped commit (could not stash) — run 'git add $_rel_dest && git commit' manually"
            return 1
        fi
        _stashed=$REPLY
        local _rc=0
        git -C "$_repo_root" add "$_rel_dest" "${_extra_add_paths[@]}" || _rc=$?
        if (( _rc == 0 )); then
            git -C "$_repo_root" commit -m "$_commit_msg" && \
                info "bootstrap-hook: committed '$_commit_msg'" || _rc=$?
        fi
        if (( _rc != 0 )); then
            warn "bootstrap-hook: commit failed — run 'git add $_rel_dest && git commit' manually"
        fi
        (( _stashed )) && _update_core_pop_stash "$_repo_root" "bootstrap-hook commit"
        (( _rc == 0 )) || return $_rc
    else
        info "bootstrap-hook: skipped commit — run 'git add $_rel_dest && git commit' manually"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Hook discovery for setup
# ---------------------------------------------------------------------------
# Source hook .zsh files from $XDG_CONFIG_HOME/dotfiler/hooks/.
# Each hook calls _update_register_hook (defined in update_core.zsh).
# Hooks that provide a setup_fn (10th param) participate in --all.
#
# We only define _update_core_init_registry + _update_register_hook
# (via update_core.zsh).  We do NOT define the update-specific plan/pull
# infrastructure, so hooks that guard on $+functions[...] for update-side
# functions (as they should) will skip update-only initialisation.
_setup_discover_hooks() {
    local hook_dir="${1:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiler/hooks}"
    [[ -d "$hook_dir" ]] || return 0

    local hook_file
    for hook_file in "$hook_dir"/*.zsh(N); do
        log_debug "setup: sourcing hook ${hook_file:t}"
        source "$hook_file"
    done
}

# ---------------------------------------------------------------------------
# Per-component unpack via setup_fn
# ---------------------------------------------------------------------------
# Calls the hook's registered setup_fn with "unpack" or "force-unpack"
# followed by any passthrough flags (--dry-run, --quiet, --debug, --yes, --no).
# The setup_fn is responsible for sourcing setup_core.zsh in a subshell
# and calling setup_core_main with the appropriate --repo-dir, --link-dest,
# --excludes, etc., appending any extra args it received.
_setup_run_component() {
    local name=$1 mode=$2
    shift 2
    local -a extra_flags=("$@")
    local setup_fn="${_dotfiler_hook_setup_fn[$name]:-}"

    if [[ -z "$setup_fn" ]]; then
        warn "Component '$name' has no setup_fn registered — skipping"
        return 1
    fi

    if ! (( $+functions[$setup_fn] )); then
        warn "Component '$name' setup_fn '$setup_fn' not defined — skipping"
        return 1
    fi

    info "Setting up component: $name"
    "$setup_fn" "$mode" "${extra_flags[@]}"
}

# ---------------------------------------------------------------------------
# List available components (for completions and --list)
# ---------------------------------------------------------------------------
_setup_list_components() {
    local name
    echo "main"
    for name in "${_dotfiler_registered_hooks[@]}"; do
        [[ -n "${_dotfiler_hook_setup_fn[$name]:-}" ]] && echo "$name"
    done
}

# ---------------------------------------------------------------------------
# setup_main — extended CLI parser and dispatcher
# ---------------------------------------------------------------------------
function setup_main() {
    local -a opt_all opt_components opt_list_components opt_bootstrap_hooks
    local -a remaining_args
    local -a passthrough_flags
    local has_unpack=0 has_force_unpack=0 has_yes=0 has_bootstrap=0
    local has_explicit_component=0  # --component given explicitly
    local has_explicit_unpack=0     # -u or -U given explicitly (not implied)

    _update_core_init_registry

    # -----------------------------------------------------------------------
    # Pre-parse: extract our new flags before passing to setup_core_main
    # -----------------------------------------------------------------------
    # We manually scan argv because zparseopts in setup_core_main doesn't
    # know about --all / --component / --bootstrap-hook.  We strip them and
    # pass the rest through.
    remaining_args=()
    while (( $# > 0 )); do
        case "$1" in
            --component|-C)
                if (( $# < 2 )); then
                    error "--component requires a component name"
                    return 1
                fi
                opt_components+=("$2")
                has_explicit_component=1
                shift 2
                ;;
            --bootstrap)
                has_bootstrap=1
                shift
                ;;
            --bootstrap-hook|-B)
                if (( $# < 2 )); then
                    error "--bootstrap-hook requires a path to the hook file"
                    return 1
                fi
                opt_bootstrap_hooks+=("$2")
                has_bootstrap=1
                shift 2
                ;;
            --list-components)
                opt_list_components=(--list-components)
                shift
                ;;
            -D|--dry-run|-q|--quiet|-g|--debug|-n|--no)
                passthrough_flags+=("$1")
                remaining_args+=("$1")
                shift
                ;;
            -y|--yes|--force)
                has_yes=1
                passthrough_flags+=("$1")
                remaining_args+=("$1")
                shift
                ;;
            -U|--force-unpack)
                has_force_unpack=1
                has_explicit_unpack=1
                remaining_args+=("$1")
                shift
                ;;
            -u|--unpack)
                has_unpack=1
                has_explicit_unpack=1
                remaining_args+=("$1")
                shift
                ;;
            *)
                remaining_args+=("$1")
                shift
                ;;
        esac
    done
    set -- "${remaining_args[@]}"

    # -----------------------------------------------------------------------
    # --bootstrap implies --all and -u: in bootstrap mode the intent is always
    # to unpack everything.  The user can still pass --component to restrict to
    # specific components, or -U to force-unpack instead of normal unpack.
    # -----------------------------------------------------------------------
    if (( has_bootstrap )); then
        (( ${#opt_all} == 0 && ${#opt_components} == 0 )) && opt_all=(--all)
        (( has_unpack || has_force_unpack )) || {
            has_unpack=1
            remaining_args+=(-u)
            set -- "${remaining_args[@]}"
        }
    fi

    # -----------------------------------------------------------------------
    # Resolve hooks directory: dotfiles-local in bootstrap mode, XDG otherwise
    # -----------------------------------------------------------------------
    # In bootstrap mode the linktree hasn't been set up yet, so we read hooks
    # directly from the dotfiles repo.  Derive the dotfiles dir from --repo-dir
    # if passed, otherwise fall back to the first non-flag positional arg, then
    # cwd — the same precedence setup_core_main uses.
    local _hooks_dir
    if (( has_bootstrap )); then
        local _dotfiles_dir=""
        local _a _next=""
        for _a in "${remaining_args[@]}"; do
            if [[ -n "$_next" ]]; then
                _dotfiles_dir="$_a"
                break
            elif [[ "$_a" == --repo-dir=* ]]; then
                _dotfiles_dir="${_a#--repo-dir=}"
                break
            elif [[ "$_a" == --repo-dir ]]; then
                _next=1
            elif [[ "$_a" != -* ]]; then
                _dotfiles_dir="$_a"
                break
            fi
        done
        if [[ -z "$_dotfiles_dir" ]]; then
            _dotfiles_dir=$(find_dotfiles_directory)
        fi
        if [[ -z "$_dotfiles_dir" || ! -d "$_dotfiles_dir" ]]; then
            error "bootstrap: cannot determine dotfiles directory; pass it as an argument"
            return 1
        fi
        _dotfiles_dir="${_dotfiles_dir:A}"
        _hooks_dir="${_dotfiles_dir}/.config/dotfiler/hooks"
        info "bootstrap: reading hooks from $_hooks_dir"
    else
        _hooks_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiler/hooks"
    fi

    # -----------------------------------------------------------------------
    # --bootstrap-hook: install symlink(s) then continue (or exit)
    # -----------------------------------------------------------------------
    if (( ${#opt_bootstrap_hooks} > 0 )); then
        local bh rc=0
        for bh in "${opt_bootstrap_hooks[@]}"; do
            _setup_bootstrap_hook "$bh" "$has_yes" "$_hooks_dir" "$has_bootstrap" "${_dotfiles_dir:-}" || rc=$?
        done
        # If no unpack explicitly requested, done here.
        # (--bootstrap implies -u, but --bootstrap-hook alone should not unpack.)
        if (( ! has_explicit_unpack && ! has_explicit_component )); then
            return $rc
        fi
        (( rc != 0 )) && return $rc
    fi

    # -----------------------------------------------------------------------
    # --list-components: discover and print, then exit
    # -----------------------------------------------------------------------
    if (( ${#opt_list_components} > 0 )); then
        _setup_discover_hooks "$_hooks_dir"
        _setup_list_components
        return 0
    fi

    # -----------------------------------------------------------------------
    # Default: -u/-U unpacks everything (main + all hook components).
    # --component restricts to specific components; it requires -u/-U.
    # -----------------------------------------------------------------------
    if (( has_unpack || has_force_unpack )); then
        if (( ${#opt_all} == 0 && ${#opt_components} == 0 )); then
            opt_all=(--all)
        fi
    elif (( has_explicit_component )); then
        error "--component requires -u/--unpack or -U/--force-unpack"
        return 1
    fi

    # -----------------------------------------------------------------------
    # Determine the unpack mode for component setup_fns
    # -----------------------------------------------------------------------
    local component_mode="unpack"
    (( has_force_unpack )) && component_mode="force-unpack"

    # -----------------------------------------------------------------------
    # Determine whether to run main repo setup
    # -----------------------------------------------------------------------
    local run_main=1
    if (( ${#opt_components} > 0 )); then
        # --component was given: only run main if explicitly listed
        run_main=0
        local c
        for c in "${opt_components[@]}"; do
            if [[ "$c" == "main" ]]; then
                run_main=1
                break
            fi
        done
    fi

    # -----------------------------------------------------------------------
    # Phase 1: main dotfiles repo (via setup_core_main)
    # -----------------------------------------------------------------------
    if (( run_main )); then
        setup_core_main "$@"
        local rc=$?
        if (( rc != 0 )); then
            error "Main dotfiles setup failed (rc=$rc)"
            return $rc
        fi
    fi

    # -----------------------------------------------------------------------
    # Phase 2: hook components (only when --all or --component)
    # -----------------------------------------------------------------------
    if (( ${#opt_all} > 0 || ${#opt_components} > 0 )); then
        _setup_discover_hooks "$_hooks_dir"

        if (( ${#opt_all} > 0 )); then
            # --all: iterate every hook that has a setup_fn
            local name
            for name in "${_dotfiler_registered_hooks[@]}"; do
                if [[ -n "${_dotfiler_hook_setup_fn[$name]:-}" ]]; then
                    _setup_run_component "$name" "$component_mode" "${passthrough_flags[@]}"
                fi
            done
        else
            # --component: only the named ones (skip "main", handled above)
            local comp
            for comp in "${opt_components[@]}"; do
                [[ "$comp" == "main" ]] && continue
                # Validate the component exists
                if (( ! ${_dotfiler_registered_hooks[(Ie)$comp]} )); then
                    error "Unknown component: $comp"
                    error "Available components:"
                    _setup_list_components | while read -r name; do
                        error "  $name"
                    done
                    return 1
                fi
                _setup_run_component "$comp" "$component_mode" "${passthrough_flags[@]}"
            done
        fi
    fi
}

# ---------------------------------------------------------------------------
# setup_unload — cleanup everything from both setup.zsh and setup_core.zsh
# ---------------------------------------------------------------------------
function setup_unload() {
    setup_core_unload 2>/dev/null
    _update_core_cleanup

    # Our own functions
    unset -f \
        _setup_bootstrap_hook \
        _setup_discover_hooks \
        _setup_run_component \
        _setup_list_components \
        setup_main \
        setup_unload \
        2>/dev/null

    # Our own globals
    unset _setup_script_dir 2>/dev/null
}

# ---------------------------------------------------------------------------
# Exec guard: run setup_main when executed directly, not when sourced
# ---------------------------------------------------------------------------
[[ $ZSH_EVAL_CONTEXT == *:file* ]] || setup_main "$@"
