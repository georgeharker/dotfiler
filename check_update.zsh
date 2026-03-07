#!/bin/zsh

# Capture script name early before functions change context
script_name="${${(%):-%x}:A}"
helper_script_dir="${script_name:h}"

source "${helper_script_dir}/helpers.zsh"
source "${helper_script_dir}/logging.zsh"
source "${helper_script_dir}/update_core.zsh"

force_update=false

# Check if script is being executed directly (not sourced)
if ! is_script_sourced; then
    # Script is being executed directly, parse arguments
    zmodload zsh/zutil
    local -a force verbose_flag debug
    zparseopts -D -E - f=force -force=force v=verbose_flag -verbose=verbose_flag \
        d=debug -debug=debug || {
        error "Usage: ${script_name} [-f|--force] [-v|--verbose] [-d|--debug]"
        error "  -f, --force    Force update check even if timestamp is recent"
        error "  -v, --verbose  Enable verbose progress output"
        error "  -d, --debug    Enable debug tracing (implies --verbose)"
        exit 1
    }

    if [[ ${#force[@]} -gt 0 ]]; then
        force_update=true
    fi

    if [[ ${#verbose_flag[@]} -gt 0 ]]; then
        export DOTFILER_VERBOSE=1
    fi

    if [[ ${#debug[@]} -gt 0 ]]; then
        export DOTFILER_DEBUG=1
    fi
fi

log_debug "check_update: sourced from ${script_name}"
log_debug "check_update: force_update=${force_update} DOTFILER_DEBUG=${DOTFILER_DEBUG:-} DOTFILER_VERBOSE=${DOTFILER_VERBOSE:-}"

# Get dotfiles_dir directory using robust detection
script_dir=$(find_dotfiles_script_directory)
dotfiles_dir=$(find_dotfiles_directory)

log_debug "check_update: script_dir=${script_dir}"
log_debug "check_update: dotfiles_dir=${dotfiles_dir}"

dotfiles_cache_dir="${XDG_CACHE_DIR:-$HOME/.cache}/dotfiles"
dotfiles_timestamp="${dotfiles_cache_dir}/dotfiles_update"
dotfiler_cache_dir="${XDG_CACHE_DIR:-$HOME/.cache}/dotfiler"

log_debug "check_update: dotfiles_cache_dir=${dotfiles_cache_dir}"
log_debug "check_update: dotfiler_cache_dir=${dotfiler_cache_dir}"

for _d in "$dotfiles_cache_dir" "$dotfiler_cache_dir"; do
    [[ -d "$_d" ]] || mkdir -p "$_d"
done
unset _d

zstyle -s ':dotfiler:update' mode update_mode || {
    zstyle -s ':omz:update' mode update_mode || {
      update_mode=prompt

      # If the mode zstyle setting is not set, support old-style settings
      [[ "$DISABLE_UPDATE_PROMPT" != true ]] || update_mode=auto
      [[ "$DISABLE_AUTO_UPDATE" != true ]] || update_mode=disabled
    }
}

log_debug "check_update: update_mode=${update_mode}"

# Cancel update if:
# - the automatic update is disabled
# - the current user doesn't have write permissions nor owns the $dotfiles_dir directory
# - git is unavailable on the system
# - $dotfiles_dir is not a git repository
if [[ "$update_mode" = disabled ]]; then
    log_debug "check_update: update disabled by update_mode=disabled — exiting"
    unset update_mode
    return
fi

if [[ ! -w "$dotfiles_dir" || ! -O "$dotfiles_dir" ]]; then
    log_debug "check_update: no write permission or not owner of ${dotfiles_dir} — exiting"
    unset update_mode
    return
fi

if ! command git --version 2>&1 >/dev/null; then
    log_debug "check_update: git not found — exiting"
    unset update_mode
    return
fi

if ! command git -C "$dotfiles_dir" rev-parse --is-inside-work-tree &>/dev/null; then
    log_debug "check_update: ${dotfiles_dir} is not a git repo — exiting"
    unset update_mode
    return
fi

function is_update_available() {
    verbose "check_update: checking main repo ${dotfiles_dir}"
    if _update_core_is_available "$dotfiles_dir"; then
        verbose "check_update: update available in main repo"
        return 0
    fi
    verbose "check_update: checking component hooks"
    if _check_update_invoke_hooks; then
        verbose "check_update: update available via hook"
        return 0
    fi
    verbose "check_update: no updates found"
    return 1
}

# _check_update_invoke_hooks
# Sources each *.zsh hook directly. Each hook calls _update_register_hook
# (shim defined below) to register its phase functions into the local registry.
# After all hooks are sourced, we iterate _dotfiler_registered_hooks and call
# each check_fn. Registered cleanup_fns are called to unset hook impl functions.
# Registry and all hook functions are torn down before returning.
function _check_update_invoke_hooks() {
    local _hooks_dir
    zstyle -s ':dotfiler:hooks' dir _hooks_dir \
        || _hooks_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiler/hooks"
    log_debug "check_update: hooks dir=${_hooks_dir}"
    [[ -d "$_hooks_dir" ]] || return 1

    # Local registry — same shape as update.zsh's global registry but
    # scoped to this function so teardown is trivial.
    local -a _dotfiler_registered_hooks
    local -A _dotfiler_hook_check_fn
    local -A _dotfiler_hook_plan_fn
    local -A _dotfiler_hook_pull_fn
    local -A _dotfiler_hook_unpack_fn
    local -A _dotfiler_hook_post_fn
    local -A _dotfiler_hook_cleanup_fn
    local -A _dotfiler_hook_component_dir
    local -A _dotfiler_hook_topology

    # Shim: hooks call this to register. In check mode dotfiler-hook.zsh
    # sources update-impl.zsh which calls _update_register_hook.
    _update_register_hook() {
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

    local _hook
    for _hook in "$_hooks_dir"/*.zsh(N); do
        [[ -f "$_hook" ]] || continue
        log_debug "check_update: sourcing hook ${_hook:t} (check mode)"
        source "$_hook"
        log_debug "check_update: hook ${_hook:t} sourced; registered=(${_dotfiler_registered_hooks[*]})"
    done

    # Call each registered check_fn, then clean up all hook functions
    local _name _fn _rc
    local _any_available=1
    for _name in "${_dotfiler_registered_hooks[@]}"; do
        _fn="${_dotfiler_hook_check_fn[$_name]:-}"
        [[ -z "$_fn" ]] && continue
        log_debug "check_update: calling check_fn for ${_name}: ${_fn}"
        "$_fn"
        _rc=$?
        log_debug "check_update: ${_name} check rc=${_rc}"
        (( _rc == 0 )) && _any_available=0
    done

    # Cleanup: call each hook's registered cleanup_fn to unset impl functions,
    # then clean up shims/vars left by the sourced hooks.
    for _name in "${_dotfiler_registered_hooks[@]}"; do
        _fn="${_dotfiler_hook_cleanup_fn[$_name]:-}"
        [[ -n "$_fn" ]] && "$_fn"
    done
    unset _zdot_dotfiler_scripts_dir ZDOT_DIR 2>/dev/null
    unset -f _update_register_hook

    return $_any_available
}

function update_dotfiles() {
    local verbose_mode_setting
    zstyle -s ':dotfiler:update' verbose verbose_mode_setting || verbose_mode_setting=default

    local quiet
    if [[ "$verbose_mode_setting" = "silent" ]]; then
        quiet="-q"
    fi

    # Non-background mode: run update.zsh interactively; only write timestamp on success.
    if [[ "$update_mode" != background ]]; then
        local -a _update_args=()
        [[ -n "$quiet" ]]              && _update_args+=( "$quiet" )
        [[ -n "$DOTFILER_VERBOSE" ]]   && _update_args+=( "--verbose" )
        [[ -n "$DOTFILER_DEBUG" ]]     && _update_args+=( "--debug" )
        verbose "check_update: running ${script_dir}/update.zsh interactively ${_update_args[*]}"
        if LANG= "${script_dir}/update.zsh" "${_update_args[@]}"; then
            verbose "check_update: success — writing timestamp"
            _update_core_write_timestamp "$dotfiles_timestamp"
            return 0
        else
            local _rc=$?
            error "check_update: update.zsh failed (exit ${_rc}) — re-run with --debug for details"
            return $_rc
        fi
    fi

    # Background mode: capture stderr so it can be stored in the timestamp file.
    verbose "check_update: running ${script_dir}/update.zsh in background mode"
    local exit_status error_out
    if error_out=$(LANG= "${script_dir}/update.zsh" -q 2>&1); then
        verbose "check_update: background success — writing timestamp"
        _update_core_write_timestamp "$dotfiles_timestamp" 0 "Update successful"
        return 0
    else
        exit_status=$?
        verbose "check_update: background failed (exit ${exit_status})"
        _update_core_write_timestamp "$dotfiles_timestamp" $exit_status "$error_out"
        return $exit_status
    fi
}

function handle_self_update() {
    emulate -L zsh

    log_debug "check_update: handle_self_update: acquiring lock ${dotfiler_cache_dir}/self_update.lock"
    if ! _update_core_acquire_lock "$dotfiler_cache_dir/self_update.lock"; then
        log_debug "check_update: handle_self_update: lock held — skipping"
        return 0
    fi

    # Release the lock when the function exits normally.
    # NOTE: do NOT use `return` in this EXIT trap — when the function is called
    # at script top-level, the trap body executes in that scope and `return`
    # becomes `exit`, which would terminate the script before handle_update runs.
    trap "
        _update_core_release_lock '$dotfiler_cache_dir/self_update.lock'
        unset -f handle_self_update 2>/dev/null
    " EXIT
    trap "
        ret=\$?
        _update_core_release_lock '$dotfiler_cache_dir/self_update.lock'
        unset -f handle_self_update 2>/dev/null
        return \$ret
    " INT QUIT

    local _self_stamp="${dotfiler_cache_dir}/dotfiler_scripts_update"
    local _self_freq
    _update_core_get_update_frequency ':dotfiler:update'; local _self_freq=$REPLY

    log_debug "check_update: handle_self_update: stamp=${_self_stamp} freq=${_self_freq} force=${force_update}"
    if ! _update_core_should_update "$_self_stamp" "$_self_freq" "$force_update"; then
        log_debug "check_update: handle_self_update: not yet due — skipping"
        return 0
    fi

    local _subtree_spec _subtree_url
    _update_core_get_dotfiler_subtree_config
    _subtree_spec=$reply[1]
    _subtree_url=$reply[2]
    log_debug "check_update: handle_self_update: detecting deployment topology (subtree_spec='${_subtree_spec}')"
    _update_core_detect_deployment "$script_dir" "$_subtree_spec"
    local _topology=$REPLY

    log_debug "check_update: handle_self_update: topology=${_topology}"
    local _avail
    case $_topology in
        standalone|submodule)
            log_debug "check_update: handle_self_update: checking availability (${_topology})"
            _update_core_is_available "$script_dir"
            _avail=$? ;;
        subtree)
            log_debug "check_update: handle_self_update: subtree spec='${_subtree_spec}' url='${_subtree_url}'"
            _update_core_is_available_subtree "$script_dir" "$_subtree_spec" "$_subtree_url"
            _avail=$? ;;
        subdir|none|*)
            log_debug "check_update: handle_self_update: topology=${_topology} — nothing to do"
            return 0 ;;
    esac

    log_debug "check_update: handle_self_update: _avail=${_avail} (0=update available, 1=up to date)"

    # _avail==1 means up to date or indeterminate — write stamp and return cleanly.
    if (( _avail == 1 )); then
        log_debug "check_update: handle_self_update: up to date — writing timestamp"
        _update_core_write_timestamp "$_self_stamp"
        return 0
    fi

    # _avail==0 means an update is available — run update.zsh dotfiler phase.
    log_debug "check_update: handle_self_update: update available — running update.zsh --update-phases=dotfiler"
    if "${script_dir}/update.zsh" --update-phases=dotfiler; then
        log_debug "check_update: handle_self_update: self-update succeeded"
        _update_core_write_timestamp "$_self_stamp"
        return 0
    else
        local _rc=$?
        error "Self-update failed (exit ${_rc})."
        return $_rc
    fi
}

function handle_update() {
    emulate -L zsh

    local option

    log_debug "check_update: handle_update: acquiring lock ${dotfiles_cache_dir}/update.lock"
    if ! _update_core_acquire_lock "$dotfiles_cache_dir/update.lock"; then
        log_debug "check_update: handle_update: lock held — skipping"
        return 0
    fi

    # Capture sourced state before trap — cleanup_helpers unsets is_script_sourced.
    # When sourced into a live shell we must NOT unset logging/helper functions
    # that belong to the shell's own environment.
    local _handle_update_sourced=false
    is_script_sourced && _handle_update_sourced=true

    # Clean up on any exit.  Signal traps propagate the signal's status so that
    # an INT/QUIT is not swallowed.  Normal EXIT does only cleanup — no `return`
    # here because this function is called at script top-level and `return`
    # inside a trap body executes in the calling scope (= exit for top-level).
    trap "
        unset update_mode 2>/dev/null
        unset dotfiles_dir dotfiles_cache_dir dotfiles_timestamp 2>/dev/null
        unset -f is_update_available update_dotfiles handle_update _check_update_invoke_hooks 2>/dev/null
        if [[ \$_handle_update_sourced != true ]]; then
            cleanup_helpers 2>/dev/null
            cleanup_logging 2>/dev/null
        fi
        _update_core_release_lock '$dotfiles_cache_dir/update.lock'
    " EXIT
    trap "
        ret=\$?
        unset update_mode 2>/dev/null
        unset dotfiles_dir dotfiles_cache_dir dotfiles_timestamp 2>/dev/null
        unset -f is_update_available update_dotfiles handle_update _check_update_invoke_hooks 2>/dev/null
        if [[ \$_handle_update_sourced != true ]]; then
            cleanup_helpers 2>/dev/null
            cleanup_logging 2>/dev/null
        fi
        _update_core_release_lock '$dotfiles_cache_dir/update.lock'
        return \$ret
    " INT QUIT

    local _dotfiles_freq
    _update_core_get_update_frequency ':dotfiler:update'; local _dotfiles_freq=$REPLY

    log_debug "check_update: handle_update: stamp=${dotfiles_timestamp} freq=${_dotfiles_freq} force=${force_update}"
    if ! _update_core_should_update "$dotfiles_timestamp" "$_dotfiles_freq" "$force_update"; then
        log_debug "check_update: handle_update: not yet due — skipping"
        return 0
    fi

    # Verify the dotfiles directory is still a git repository.
    log_debug "check_update: handle_update: verifying ${dotfiles_dir} is a git repo"
    if ! (builtin cd -q "$dotfiles_dir" && LANG= git rev-parse &>/dev/null); then
        error "Can't update: '${dotfiles_dir}' is not a git repository."
        return 1
    fi

    # Check if there are updates available before proceeding.
    log_debug "check_update: handle_update: checking for available updates"
    if ! is_update_available; then
        log_debug "check_update: handle_update: no updates available — writing timestamp"
        _update_core_write_timestamp "$dotfiles_timestamp"
        return 0
    fi

    log_debug "check_update: handle_update: updates available — update_mode=${update_mode}"

    # Reminder mode, or user has already typed input: show a nudge and exit.
    if [[ "$update_mode" = reminder ]]; then
        log_debug "check_update: handle_update: reminder mode — printing nudge"
        printf '\r\e[0K'
        info "It's time to update! You can do that by running \`${script_dir}/dotfiler update\`"
        return 0
    fi

    if [[ "$update_mode" != background ]] && _update_core_has_typed_input; then
        log_debug "check_update: handle_update: typed input detected — printing nudge and deferring"
        printf '\r\e[0K'
        info "It's time to update! You can do that by running \`${script_dir}/dotfiler update\`"
        return 0
    fi

    # Auto / background mode: update without prompting.
    if [[ "$update_mode" = (auto|background) ]]; then
        log_debug "check_update: handle_update: ${update_mode} mode — updating without prompt"
        update_dotfiles
        return $?
    fi

    # Prompt mode: ask the user.
    log_debug "check_update: handle_update: prompt mode — asking user"
    info_nonl "Would you like to update? [Y/n] "
    read -r -k 1 option
    [[ "$option" = $'\n' ]] || echo
    case "$option" in
        [yY$'\n'])
            log_debug "check_update: handle_update: user accepted update"
            update_dotfiles
            return $?
            ;;
        [nN])
            log_debug "check_update: handle_update: user declined — writing timestamp"
            _update_core_write_timestamp "$dotfiles_timestamp"
            info "You can update manually by running \`${dotfiles_dir}/dotfiler update\`"
            return 0
            ;;
        *)
            log_debug "check_update: handle_update: unrecognised input — deferring"
            info "You can update manually by running \`${dotfiles_dir}/dotfiler update\`"
            return 0
            ;;
    esac
}

case "$update_mode" in
    background)
        autoload -Uz add-zsh-hook
        verbose "check_update: scheduling background update check via precmd hook"

        _dotfiles_bg_update() {
            verbose "check_update: _dotfiles_bg_update: launching subshells"
            # Run both updates in subshells so they don't block the shell
            (handle_self_update) &|
            (handle_update) &|

            # Register status check hook for next prompt
            add-zsh-hook precmd _dotfiles_bg_update_status

            # Deregister this hook — runs only once per session
            add-zsh-hook -d precmd _dotfiles_bg_update
            unset -f _dotfiles_bg_update
        }

        _dotfiles_bg_update_status() {
            {
                local LAST_EPOCH EXIT_STATUS ERROR
                if [[ ! -f "$dotfiles_timestamp" ]]; then
                    verbose "check_update: _dotfiles_bg_update_status: timestamp file not yet present — waiting"
                    return 1
                fi

                # Source the timestamp file to read status variables
                . "$dotfiles_timestamp"

                # Wait until the background job has written a result.
                # A successful update writes EXIT_STATUS=0 and ERROR="Update successful".
                # A failed update writes EXIT_STATUS=<n> and ERROR=<stderr>.
                # A plain timestamp write (no status) leaves EXIT_STATUS and ERROR unset.
                if [[ -z "$EXIT_STATUS" ]]; then
                    verbose "check_update: _dotfiles_bg_update_status: no EXIT_STATUS yet — waiting"
                    return 1
                fi

                if [[ "$EXIT_STATUS" -eq 0 ]]; then
                    success "Dotfiles updated successfully."
                    return 0
                else
                    error "There was an error updating dotfiles (exit ${EXIT_STATUS}):"
                    warn "${ERROR}"
                    return 0
                fi
            } always {
                if (( TRY_BLOCK_ERROR == 0 )); then
                    verbose "check_update: _dotfiles_bg_update_status: result handled — clearing status and deregistering hook"
                    # Clear the status payload from the timestamp file, preserving LAST_EPOCH
                    _update_core_write_timestamp "$dotfiles_timestamp"

                    # Deregister this hook
                    add-zsh-hook -d precmd _dotfiles_bg_update_status
                    unset -f _dotfiles_bg_update_status
                fi
            }
        }

        add-zsh-hook precmd _dotfiles_bg_update
        ;;
    *)
        verbose "check_update: foreground mode (${update_mode}) — running handle_self_update then handle_update"
        handle_self_update
        handle_update ;;
esac
