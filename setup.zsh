#!/usr/bin/env zsh
# setup.zsh — multi-component-aware setup orchestrator.
#
# This is the CLI entry point for `dotfiler setup`.  It sources:
#   setup_core.zsh  — single-repo operations (gitignore, find, link, unpack)
#   update_core.zsh — shared primitives (topology, hook registry)
#
# Without --all or --component, behaviour is identical to the old setup.zsh:
#   dotfiler setup -u                  # unpack main dotfiles only
#   dotfiler setup -i ~/.bashrc        # ingest a file
#
# With --all, unpacks main dotfiles then every registered hook component:
#   dotfiler setup -u --all            # unpack everything
#   dotfiler setup -U --all            # force-unpack everything (bootstrap)
#
# With --component, unpacks only the named component(s):
#   dotfiler setup -u --component zdot         # just zdot
#   dotfiler setup -u --component main         # just main dotfiles
#   dotfiler setup -u --component main --component zdot  # both
#
# Hook components participate by registering a setup_fn via the 10th
# parameter of _update_register_hook.  The setup_fn receives:
#   $1        — "unpack" or "force-unpack"
#   $2 .. $N  — passthrough flags (--dry-run, --quiet, --debug, --yes, --no)

# ---------------------------------------------------------------------------
# Bootstrap: locate ourselves, source helpers if not already loaded
# ---------------------------------------------------------------------------
_setup_script_dir="${0:A:h}"

if ! (( $+functions[info] )); then
    source "${_setup_script_dir}/helpers.zsh"
fi

# ---------------------------------------------------------------------------
# Source core libraries
# ---------------------------------------------------------------------------
source "${_setup_script_dir}/setup_core.zsh"
source "${_setup_script_dir}/update_core.zsh"

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
    local hook_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiler/hooks"
    [[ -d "$hook_dir" ]] || return 0

    _update_core_init_registry

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
    local -a opt_all opt_components opt_list_components
    local -a remaining_args
    local -a passthrough_flags
    local has_unpack=0 has_force_unpack=0

    # -----------------------------------------------------------------------
    # Pre-parse: extract our new flags before passing to setup_core_main
    # -----------------------------------------------------------------------
    # We manually scan argv because zparseopts in setup_core_main doesn't
    # know about --all / --component.  We strip them and pass the rest
    # through.
    remaining_args=()
    while (( $# > 0 )); do
        case "$1" in
            --all|-A)
                opt_all=(--all)
                shift
                ;;
            --component|-C)
                if (( $# < 2 )); then
                    error "--component requires a component name"
                    return 1
                fi
                opt_components+=("$2")
                shift 2
                ;;
            --list-components)
                opt_list_components=(--list-components)
                shift
                ;;
            -D|--dry-run|-q|--quiet|-g|--debug|-y|--yes|-n|--no)
                passthrough_flags+=("$1")
                remaining_args+=("$1")
                shift
                ;;
            -U|--force-unpack)
                has_force_unpack=1
                remaining_args+=("$1")
                shift
                ;;
            -u|--unpack)
                has_unpack=1
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
    # --list-components: discover and print, then exit
    # -----------------------------------------------------------------------
    if (( ${#opt_list_components} > 0 )); then
        _setup_discover_hooks
        _setup_list_components
        return 0
    fi

    # -----------------------------------------------------------------------
    # Validate: --all / --component only make sense with -u or -U
    # -----------------------------------------------------------------------
    if (( ${#opt_all} > 0 || ${#opt_components} > 0 )); then
        if (( ! has_unpack && ! has_force_unpack )); then
            error "--all and --component require -u/--unpack or -U/--force-unpack"
            return 1
        fi
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
        _setup_discover_hooks

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
    # Unload core first
    setup_core_unload 2>/dev/null

    # Our own functions
    unset -f \
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
