#!/bin/zsh

# Capture script name early before functions change context
script_name="${${(%):-%x}:A}"
helper_script_dir="${script_name:h}"

source "${helper_script_dir}/helpers.sh"
source "${helper_script_dir}/logging.sh"
source "${helper_script_dir}/update_core.sh"

force_update=false

# Check if script is being executed directly (not sourced)
if ! is_script_sourced; then
    # Script is being executed directly, parse arguments
    zmodload zsh/zutil
    local -a force debug
    zparseopts -D -E - f=force -force=force d=debug -debug=debug || {
        error "Usage: ${script_name} [-f|--force] [-d|--debug]"
        error "  -f, --force    Force update check even if timestamp is recent"
        error "  -d, --debug    Enable debug output for troubleshooting"
        exit 1
    }
    
    if [[ ${#force[@]} -gt 0 ]]; then
        force_update=true
    fi
    
    if [[ ${#debug[@]} -gt 0 ]]; then
        export DOTFILES_DEBUG=1
        verbose "Debug mode enabled"
    fi
fi

# Get dotfiles_dir directory using robust detection
script_dir=$(find_dotfiles_script_directory)
dotfiles_dir=$(find_dotfiles_directory)

dotfiles_cache_dir="${XDG_CACHE_DIR:-$HOME/.cache}/dotfiles"
dotfiles_timestamp="${dotfiles_cache_dir}/dotfiles_update"
dotfiler_cache_dir="${XDG_CACHE_DIR:-$HOME/.cache}/dotfiler"

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

# Cancel update if:
# - the automatic update is disabled
# - the current user doesn't have write permissions nor owns the $dotfiles_dir directory
# - is not run from a tty
# - git is unavailable on the system
# - $dotfiles_dir is not a git repository
if [[ "$update_mode" = disabled ]] \
   || [[ ! -w "$dotfiles_dir" || ! -O "$dotfiles_dir" ]] \
   || ! command git --version 2>&1 >/dev/null \
   || ! command git -C "$dotfiles_dir" rev-parse --is-inside-work-tree &>/dev/null; then
  unset update_mode
  return
fi

function is_update_available() {
    # Check the parent dotfiles repo itself
    _update_core_is_available "$dotfiles_dir" && return 0
    # Delegate to registered component hooks — each hook knows how to check
    # its own repo (e.g. zdot as a submodule) without dotfiler needing to
    # understand the topology of each managed component.
    _check_update_invoke_hooks check-update && return 0
    return 1
}

# _check_update_invoke_hooks <verb>
# Enumerates *.zsh executables in the dotfiler hooks directory and calls
# each with <verb>.  Returns 0 as soon as any hook returns 0.
# Hooks dir: zstyle ':dotfiler:hooks' dir  (default ~/.config/dotfiler/hooks)
function _check_update_invoke_hooks() {
    local _verb=$1
    local _hooks_dir
    zstyle -s ':dotfiler:hooks' dir _hooks_dir \
        || _hooks_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiler/hooks"
    [[ -d "$_hooks_dir" ]] || return 1
    local _hook
    for _hook in "$_hooks_dir"/*.zsh(N); do
        [[ -x "$_hook" ]] || continue
        "$_hook" "$_verb" && return 0
    done
    return 1
}

function update_dotfiles() {
  local verbose_mode
  zstyle -s ':dotfiler:update' verbose verbose_mode || verbose_mode=default

  local quiet
  if [[ "$verbose_mode" = "silent" ]]; then
    quiet="-q"
  fi

  # Non-background mode: run update.sh interactively; only write timestamp on success.
  if [[ "$update_mode" != background-alpha ]]; then
    if LANG= "${script_dir}/update.sh" "$quiet"; then
      _update_core_write_timestamp "$dotfiles_timestamp"
      return 0
    else
      local _rc=$?
      error "Update failed (exit ${_rc})."
      return $_rc
    fi
  fi

  # Background mode: capture stderr so it can be stored in the timestamp file.
  local exit_status error_out
  if error_out=$(LANG= "${script_dir}/update.sh" -q 2>&1); then
    _update_core_write_timestamp "$dotfiles_timestamp" 0 "Update successful"
    return 0
  else
    exit_status=$?
    _update_core_write_timestamp "$dotfiles_timestamp" $exit_status "$error_out"
    return $exit_status
  fi
}

function handle_self_update() {
  emulate -L zsh

  if ! _update_core_acquire_lock "$dotfiler_cache_dir/self_update.lock"; then
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
  zstyle -s ':dotfiler:update' frequency _self_freq || _self_freq=${UPDATE_DOTFILE_SECONDS:-3600}

  if ! _update_core_should_update "$_self_stamp" "$_self_freq" "$force_update"; then
    return 0
  fi

  local _subtree_spec
  zstyle -s ':dotfiler:update' subtree-remote _subtree_spec 2>/dev/null || _subtree_spec=""
  _update_core_detect_deployment "$script_dir" "$_subtree_spec"
  local _topology=$REPLY

  local _avail
  case $_topology in
    standalone|submodule)
      _update_core_is_available "$script_dir"
      _avail=$? ;;
    subtree)
      local _remote_url _remote _branch
      _remote="${_subtree_spec%% *}"
      _branch="${_subtree_spec#* }"
      [[ "$_branch" == "$_remote" ]] && _branch=""
      [[ -z "$_branch" ]] && \
        _branch=$(_update_core_get_default_branch "$script_dir" "$_remote")
      _remote_url=$(git -C "$script_dir" config "remote.${_remote}.url" 2>/dev/null)
      _update_core_is_available_subtree "$script_dir" "$_remote_url" "$_branch"
      _avail=$? ;;
    subdir|none|*)
      return 0 ;;
  esac

  # _avail==1 means up to date or indeterminate — write stamp and return cleanly.
  if (( _avail == 1 )); then
    _update_core_write_timestamp "$_self_stamp"
    return 0
  fi

  # _avail==0 means an update is available — run update_self.sh.
  if "${script_dir}/update_self.sh" --force; then
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

  if ! _update_core_acquire_lock "$dotfiles_cache_dir/update.lock"; then
    return 0
  fi

  # Clean up on any exit.  Signal traps propagate the signal's status so that
  # an INT/QUIT is not swallowed.  Normal EXIT does only cleanup — no `return`
  # here because this function is called at script top-level and `return`
  # inside a trap body executes in the calling scope (= exit for top-level).
  trap "
    unset update_mode 2>/dev/null
    unset dotfiles_dir dotfiles_cache_dir dotfiles_timestamp 2>/dev/null
    unset -f is_update_available update_dotfiles handle_update 2>/dev/null
    cleanup_helpers 2>/dev/null
    cleanup_logging 2>/dev/null
    _update_core_release_lock '$dotfiles_cache_dir/update.lock'
  " EXIT
  trap "
    ret=\$?
    unset update_mode 2>/dev/null
    unset dotfiles_dir dotfiles_cache_dir dotfiles_timestamp 2>/dev/null
    unset -f is_update_available update_dotfiles handle_update 2>/dev/null
    cleanup_helpers 2>/dev/null
    cleanup_logging 2>/dev/null
    _update_core_release_lock '$dotfiles_cache_dir/update.lock'
    return \$ret
  " INT QUIT

  local _dotfiles_freq
  zstyle -s ':dotfiler:update' frequency _dotfiles_freq || _dotfiles_freq=${UPDATE_DOTFILE_SECONDS:-3600}
  if ! _update_core_should_update "$dotfiles_timestamp" "$_dotfiles_freq" "$force_update"; then
    return 0
  fi

  # Verify the dotfiles directory is still a git repository.
  if ! (builtin cd -q "$dotfiles_dir" && LANG= git rev-parse &>/dev/null); then
    error "Can't update: '${dotfiles_dir}' is not a git repository."
    return 1
  fi

  # Check if there are updates available before proceeding.
  if ! is_update_available; then
    _update_core_write_timestamp "$dotfiles_timestamp"
    return 0
  fi

  # Reminder mode, or user has already typed input: show a nudge and exit.
  if [[ "$update_mode" = reminder ]] || { [[ "$update_mode" != background-alpha ]] && _update_core_has_typed_input }; then
    printf '\r\e[0K' # move cursor to first column and clear whole line
    info "It's time to update! You can do that by running \`${script_dir}/dotfiler update\`"
    return 0
  fi

  # Auto / background mode: update without prompting.
  if [[ "$update_mode" = (auto|background-alpha) ]]; then
    update_dotfiles
    return $?
  fi

  # Prompt mode: ask the user.
  info_nonl "Would you like to update? [Y/n] "
  read -r -k 1 option
  [[ "$option" = $'\n' ]] || echo
  case "$option" in
    [yY$'\n'])
      update_dotfiles
      return $?
      ;;
    [nN])
      _update_core_write_timestamp "$dotfiles_timestamp"
      info "You can update manually by running \`${dotfiles_dir}/dotfiler update\`"
      return 0
      ;;
    *)
      info "You can update manually by running \`${dotfiles_dir}/dotfiler update\`"
      return 0
      ;;
  esac
}

case "$update_mode" in
  background-alpha)
    autoload -Uz add-zsh-hook

    _dotfiles_bg_update() {
      # do the update in a subshell
      (handle_self_update) &|
      (handle_update) &|

      # register update results function
      add-zsh-hook precmd _dotfiles_bg_update_status

      # deregister background function
      add-zsh-hook -d precmd _dotfiles_bg_update
      unset -f _dotfiles_bg_update
    }

    _dotfiles_bg_update_status() {
      {
        local LAST_EPOCH EXIT_STATUS ERROR
        if [[ ! -f "$dotfiles_timestamp" ]]; then
          return 1
        fi

        # check update results until timeout is reached
        . "$dotfiles_timestamp"
        if [[ -z "$EXIT_STATUS" || -z "$ERROR" ]]; then
          return 1
        fi

        if [[ "$EXIT_STATUS" -eq 0 ]]; then
          success "Update successful."
          return 0
        elif [[ "$EXIT_STATUS" -ne 0 ]]; then
          error "There was an error updating:"
          warn "${ERROR}"
          return 0
        fi
      } always {
        if (( TRY_BLOCK_ERROR == 0 )); then
          # if last update results have been handled, remove them from the status file
          _update_core_write_timestamp "$dotfiles_timestamp"

          # deregister background function
          add-zsh-hook -d precmd _dotfiles_bg_update_status
          unset -f _dotfiles_bg_update_status
        fi
      }
    }

    add-zsh-hook precmd _dotfiles_bg_update
    ;;
  *)
    handle_self_update
    handle_update ;;
esac
