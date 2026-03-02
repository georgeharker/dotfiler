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
   || (builtin cd -q "$ZSH"; ! command git rev-parse --is-inside-work-tree &>/dev/null); then
  unset update_mode
  return
fi

function is_update_available() {
    _update_core_is_available "$dotfiles_dir"
}

function update_dotfiles() {
  local verbose_mode
  zstyle -s ':dotfiler:update' verbose verbose_mode || verbose_mode=default

  local quiet
  if [[ "$verbose_mode" = "silent" ]]; then
    quiet="-q"
  fi

  if [[ "$update_mode" != background-alpha ]] \
    && LANG= ZSH="$ZSH" "${script_dir}/update.sh" "$quiet"; then
    _update_core_write_timestamp "$dotfiles_timestamp"
    return $?
  fi

  local exit_status error
  if error=$(LANG= ZSH="$ZSH" "${script_dir}/update.sh" -q 2>&1); then
    _update_core_write_timestamp "$dotfiles_timestamp" 0 "Update successful"
  else
    exit_status=$?
    _update_core_write_timestamp "$dotfiles_timestamp" $exit_status "$error"
    return $exit_status
  fi
}

function handle_self_update() {
  emulate -L zsh

    if ! _update_core_acquire_lock "$dotfiler_cache_dir/self_update.lock"; then
        return
    fi

    trap "
        ret=\$?
        _update_core_release_lock '$dotfiler_cache_dir/self_update.lock'
        unset dotfiler_cache_dir 2>/dev/null
        unset -f handle_self_update 2>/dev/null
        return \$ret
    " EXIT INT QUIT

    local _self_stamp="${dotfiler_cache_dir}/dotfiler_scripts_update"
    local _self_freq
    zstyle -s ':dotfiler:update' frequency _self_freq || _self_freq=${UPDATE_DOTFILE_SECONDS:-3600}

    if ! _update_core_should_update "$_self_stamp" "$_self_freq" "$force_update"; then
        return
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
            local _remote_url _remote="${_subtree_spec%% *}"
            _remote_url=$(git -C "$script_dir" config "remote.${_remote}.url" 2>/dev/null)
            _update_core_is_available "$script_dir" "$_remote_url"
            _avail=$? ;;
        subdir|none|*)
            return 0 ;;
    esac

    # _avail==1 means up to date or indeterminate skip -- write stamp and return
    if (( _avail == 1 )); then
        _update_core_write_timestamp "$_self_stamp"
        return
    fi

    "${script_dir}/update_self.sh" --force \
        && _update_core_write_timestamp "$_self_stamp"
}

function handle_update() {
    emulate -L zsh

    local mtime option

    if ! _update_core_acquire_lock "$dotfiles_cache_dir/update.lock"; then
      return
    fi

    # Remove lock directory on exit. `return $ret` is important for when trapping a SIGINT:
    #  The return status from the function is handled specially. If it is zero, the signal is
    #  assumed to have been handled, and execution continues normally. Otherwise, the shell
    #  will behave as interrupted except that the return status of the trap is retained.
    #  This means that for a CTRL+C, the trap needs to return the same exit status so that
    #  the shell actually exits what it's running.
    trap "
      ret=\$?
      unset update_mode
      unset dotfiles_dir dotfiles_cache_dir dotfiles_timestamp 2>/dev/null
        unset -f is_update_available update_dotfiles handle_update 2>/dev/null
     cleanup_helpers 2>/dev/null
        cleanup_logging 2>/dev/null
        _update_core_release_lock '$dotfiles_cache_dir/update.lock'
      return \$ret
    " EXIT INT QUIT

    local _dotfiles_freq
    zstyle -s ':dotfiler:update' frequency _dotfiles_freq || _dotfiles_freq=${UPDATE_DOTFILE_SECONDS:-3600}
    if ! _update_core_should_update "$dotfiles_timestamp" "$_dotfiles_freq" "$force_update"; then
        return
    fi

    # Test if dotfiler directory is a git repository
    if ! (builtin cd -q "$dotfiles_dir" && LANG= git rev-parse &>/dev/null); then
        error "Can't update: not a git repository."
      return
    fi

    # Check if there are updates available before proceeding
    if ! is_update_available; then
        _update_core_write_timestamp "$dotfiles_timestamp"
      return
    fi

    # If in reminder mode or user has typed input, show reminder and exit
    if [[ "$update_mode" = reminder ]] || { [[ "$update_mode" != background-alpha ]] && _update_core_has_typed_input }; then
      printf '\r\e[0K' # move cursor to first column and clear whole line
        info "It's time to update! You can do that by running \`${script_dir}/dotfiler update\`"
      return 0
    fi

    # Don't ask for confirmation before updating if in auto mode
    if [[ "$update_mode" = (auto|background-alpha) ]]; then
      update_dotfiles
      return $?
    fi

    # Ask for confirmation and only update on 'y', 'Y' or Enter
    # Otherwise just show a reminder for how to update
    info_nonl "Would you like to update? [Y/n] "
    read -r -k 1 option
    [[ "$option" = $'\n' ]] || echo
    case "$option" in
      [yY$'\n']) update_dotfiles ;;
        [nN]) _update_core_write_timestamp "$dotfiles_timestamp" ;&
        *) info "You can update manually by running \`${dotfiles_dir}/dotfiler update\`" ;;
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
