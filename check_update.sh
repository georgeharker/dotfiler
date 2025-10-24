#!/bin/zsh

# Capture script name early before functions change context
script_name="${${(%):-%x}:A}"
helper_script_dir="${script_name:h}"

source "${helper_script_dir}/helpers.sh"

force_update=false

# Check if script is being executed directly (not sourced)
if ! is_script_sourced; then
    # Script is being executed directly, parse arguments
    zmodload zsh/zutil
    local -a force debug
    zparseopts -D -E - f=force -force=force d=debug -debug=debug || {
        echo "Usage: ${script_name} [-f|--force] [-d|--debug]" >&2
        echo "  -f, --force    Force update check even if timestamp is recent" >&2
        echo "  -d, --debug    Enable debug output for troubleshooting" >&2
        exit 1
    }
    
    if [[ ${#force[@]} -gt 0 ]]; then
        force_update=true
    fi
    
    if [[ ${#debug[@]} -gt 0 ]]; then
        export DOTFILES_DEBUG=1
        echo "DEBUG: Debug mode enabled" >&2
    fi
fi

# Get dotfiles_dir directory using robust detection
script_dir=$(find_dotfiles_script_directory)
dotfiles_dir=$(find_dotfiles_directory)

dotfiles_cache_dir="${XDG_CACHE_DIR:-$HOME/.cache}/dotfiles"
dotfiles_timestamp="${dotfiles_cache_dir}/dotfiles_update"


if [[ ! -d "${dotfiles_cache_dir}" ]]; then
    mkdir -p "${dotfiles_cache_dir}"
fi

zstyle -s ':dotfile:update' mode update_mode || {
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

function current_epoch() {
  zmodload zsh/datetime
  echo $(( EPOCHSECONDS ))
}

# Get default remote and branch (similar to update.sh)
function get_default_remote(){
    # Get the remote that the current branch tracks, fallback to 'origin'
    local current_branch=$(builtin cd -q "$dotfiles_dir"; git branch --show-current)
    local upstream=$(builtin cd -q "$dotfiles_dir"; git config --get branch.${current_branch}.remote 2>/dev/null)
    if [[ -n "$upstream" ]]; then
        echo "$upstream"
    else
        # Fallback to first remote, typically 'origin'
        builtin cd -q "$dotfiles_dir"; git remote | head -n1
    fi
}

function get_default_branch(){
    local remote="${1:-$(get_default_remote)}"
    
    # Try to get the default branch from remote HEAD
    local ref_output default_branch
    ref_output=$(builtin cd -q "$dotfiles_dir"; git symbolic-ref refs/remotes/${remote}/HEAD 2>/dev/null)
    default_branch="${ref_output#refs/remotes/${remote}/}"
    
    # If that fails, try to get it from remote show
    if [[ -z "$default_branch" ]]; then
        local remote_output line
        remote_output=$(builtin cd -q "$dotfiles_dir"; git remote show "$remote" 2>/dev/null)
        for line in ${(f)remote_output}; do
            if [[ "$line" == *"HEAD branch:"* ]]; then
                default_branch="${${line#*: }// /}"  # Remove prefix and spaces
                break
            fi
        done
    fi
    
    # Final fallback to common default branches
    if [[ -z "$default_branch" ]]; then
        for branch in main master; do
            if (builtin cd -q "$dotfiles_dir"; git show-ref --verify --quiet refs/remotes/${remote}/${branch}); then
                default_branch="$branch"
                break
            fi
        done
    fi
    
    echo "$default_branch"
}

function is_update_available() {
  # Debug output function
  local debug_log() {
    [[ -n "$DOTFILES_DEBUG" ]] && echo "[DEBUG] $*" >&2
  }
  
  local branch
  # Use unlikely defaults that we can detect and replace with dynamic detection
  branch=${"$(builtin cd -q "$dotfiles_dir"; git config --local oh-my-zsh.branch)":-__DOTFILES_UNLIKELY_BRANCH__}
  
  # If the unlikely default was used, detect actual default branch
  if [[ "$branch" == "__DOTFILES_UNLIKELY_BRANCH__" ]]; then
      branch=$(get_default_branch)
  fi

  local remote remote_url remote_repo
  # Use unlikely defaults that we can detect and replace with dynamic detection
  remote=${"$(builtin cd -q "$dotfiles_dir"; git config --local oh-my-zsh.remote)":-__DOTFILES_UNLIKELY_REMOTE__}
  
  # If the unlikely default was used, detect actual default remote
  if [[ "$remote" == "__DOTFILES_UNLIKELY_REMOTE__" ]]; then
      remote=$(get_default_remote)
  fi
  
  # Ensure we have valid remote and branch
  if [[ -z "$remote" ]] || [[ -z "$branch" ]]; then
    debug_log "Missing remote ($remote) or branch ($branch)"
    # Can't determine remote/branch, assume updates available
    return 0
  fi
  
  debug_log "Checking for updates: $remote/$branch"
  
  # Fetch from remote to get latest refs (quietly)
  if ! (builtin cd -q "$dotfiles_dir"; git fetch "$remote" "$branch" 2>/dev/null); then
    debug_log "Git fetch failed, falling back to GitHub API"
    # Fetch failed, might be network issue - try GitHub API as fallback
    # Continue with existing API logic
  else
    debug_log "Git fetch succeeded, comparing refs directly"
    # Fetch succeeded, compare local and remote refs directly
    local local_head remote_head
    local_head=$(builtin cd -q "$dotfiles_dir"; git rev-parse HEAD 2>/dev/null) || return 0
    remote_head=$(builtin cd -q "$dotfiles_dir"; git rev-parse "$remote/$branch" 2>/dev/null) || return 0
    
    debug_log "Local HEAD: ${local_head:0:8}, Remote HEAD: ${remote_head:0:8}"
    
    # Simple comparison - if different, updates are available
    if [[ "$local_head" != "$remote_head" ]]; then
      debug_log "Updates available (different HEADs)"
      return 0
    else
      debug_log "No updates available (HEADs match)"
      return 1
    fi
  fi
  
  remote_url=$(builtin cd -q "$dotfiles_dir"; git config remote.$remote.url)

  local repo
  case "$remote_url" in
  https://github.com/*) repo=${${remote_url#https://github.com/}%.git} ;;
  git@github.com:*) repo=${${remote_url#git@github.com:}%.git} ;;
  *)
    debug_log "Non-GitHub remote: $remote_url"
    # Non-GitHub remote and fetch failed, assume updates available
    return 0 ;;
  esac

  # GitHub API fallback (when fetch fails)
  local api_url="https://api.github.com/repos/${repo}/commits/${branch}"
  debug_log "Using GitHub API: $api_url"

  # Get local HEAD. If this fails assume there are updates
  local local_head
  local_head=$(builtin cd -q "$dotfiles_dir"; git rev-parse HEAD 2>/dev/null) || return 0

  # Get remote HEAD via API with better error handling
  local remote_head
  remote_head=$(
    if (( ${+commands[curl]} )); then
      # Use longer timeout and better error handling
      local auth_header=""
      [[ -n "$GH_TOKEN" ]] && auth_header="-H Authorization: Bearer ${GH_TOKEN}"
      curl --connect-timeout 10 --max-time 30 -fsSL \
        -H 'Accept: application/vnd.github.v3.sha' \
        $auth_header "$api_url" 2>/dev/null
    elif (( ${+commands[wget]} )); then
      local auth_header=""
      [[ -n "$GH_TOKEN" ]] && auth_header="--header=Authorization: Bearer ${GH_TOKEN}"
      wget --timeout=30 -O- --header='Accept: application/vnd.github.v3.sha' \
        $auth_header "$api_url" 2>/dev/null
    else
      # No curl or wget available, assume updates
      return 0
    fi
  )
  
  # If API call failed, assume updates available (better safe than sorry)
  if [[ -z "$remote_head" ]]; then
    debug_log "GitHub API call failed, assuming updates available"
    return 0
  fi
  
  debug_log "Local HEAD: ${local_head:0:8}, Remote HEAD (API): ${remote_head:0:8}"

  # Compare local and remote HEADs (if they're equal there are no updates)
  if [[ "$local_head" != "$remote_head" ]]; then
    debug_log "Updates available via API (different HEADs)"
    return 0
  else
    debug_log "No updates available via API (HEADs match)"
    return 1
  fi
}

function update_last_updated_file() {
  local exit_status="$1" error="$2"

  if [[ -z "${1}${2}" ]]; then
    echo "LAST_EPOCH=$(current_epoch)" >! "${dotfiles_timestamp}"
    return
  fi

  cat >! "${dotfiles_timestamp}" <<EOD
LAST_EPOCH=$(current_epoch)
EXIT_STATUS=${exit_status}
ERROR='${error//\'/’}'
EOD
}

function update_dotfiles() {
  local verbose_mode
  zstyle -s ':dotfiles:update' verbose verbose_mode || verbose_mode=default

  local quiet
  if [[ "$verbose_mode" = "silent" ]]; then
    quiet="-q"
  fi

  if [[ "$update_mode" != background-alpha ]] \
    && LANG= ZSH="$ZSH" zsh -f "${script_dir}/update.sh" "$quiet"; then
    update_last_updated_file
    return $?
  fi

  local exit_status error
  if error=$(LANG= ZSH="$ZSH" zsh -f "${script_dir}/update.sh" -q 2>&1); then
    update_last_updated_file 0 "Update successful"
  else
    exit_status=$?
    update_last_updated_file $exit_status "$error"
    return $exit_status
  fi
}

function has_typed_input() {
  # Created by Philippe Troin <phil@fifi.org>
  # https://zsh.org/mla/users/2022/msg00062.html
  emulate -L zsh
  zmodload zsh/zselect

  # Back up stty settings prior to disabling canonical mode
  # Consider that no input can be typed if stty fails
  # (this might happen if stdin is not a terminal)
  local termios
  termios=$(stty --save 2>/dev/null) || return 1
  {
    # Disable canonical mode so that typed input counts
    # regardless of whether Enter was pressed
    stty -icanon

    # Poll stdin (fd 0) for data ready to be read
    zselect -t 0 -r 0
    return $?
  } always {
    # Restore stty settings
    stty $termios
  }
}

function handle_update() {
  () {
    emulate -L zsh

    local epoch_target mtime option LAST_EPOCH

    # Remove lock directory if older than a day
    zmodload zsh/datetime
    zmodload -F zsh/stat b:zstat
    if mtime=$(zstat +mtime "$dotfiles_cache_dir/update.lock" 2>/dev/null); then
      if (( (mtime + 3600 * 24) < EPOCHSECONDS )); then
        command rm -rf "$dotfiles_cache_dir/update.lock"
      fi
    fi

    # Check for lock directory
    if ! command mkdir -p "$dotfiles_cache_dir/update.lock" 2>/dev/null; then
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
      unset -f current_epoch get_default_remote get_default_branch is_update_available update_last_updated_file update_dotfiles handle_update 2>/dev/null
     cleanup_helpers 2>/dev/null
      command rm -rf '$dotfiles_cache_dir/update.lock'
      return \$ret
    " EXIT INT QUIT

    # Create or update .zsh-update file if missing or malformed
    if ! source "${dotfiles_timestamp}" 2>/dev/null || [[ -z "$LAST_EPOCH" ]]; then
      update_last_updated_file
      return
    fi

    # Number of days before trying to update again
    zstyle -s ':dotfiles:update' frequency epoch_target || epoch_target=${UPDATE_DOTFILE_SECONDS:-3600}
    
    # Debug timestamp check
    if [[ -n "$DOTFILES_DEBUG" ]]; then
      local current_time=$(current_epoch)
      local time_diff=$(( current_time - LAST_EPOCH ))
      echo "[DEBUG] Timestamp check: current=$current_time, last=$LAST_EPOCH, diff=${time_diff}s, target=${epoch_target}s" >&2
    fi
    
    # Test if enough time has passed until the next update
    if (( ( $(current_epoch) - $LAST_EPOCH ) < $epoch_target )); then
      if [[ "$force_update" != "true" ]]; then
        [[ -n "$DOTFILES_DEBUG" ]] && echo "[DEBUG] Timestamp check failed, not enough time passed (use -f to force)" >&2
        return
      else
        [[ -n "$DOTFILES_DEBUG" ]] && echo "[DEBUG] Timestamp check failed but force mode enabled" >&2
        echo "[dotfiles] Forcing update check despite recent timestamp"
      fi
    else
      [[ -n "$DOTFILES_DEBUG" ]] && echo "[DEBUG] Timestamp check passed, proceeding with update check" >&2
    fi

    # Test if Oh My Zsh directory is a git repository
    if ! (builtin cd -q "$dotfiles_dir" && LANG= git rev-parse &>/dev/null); then
      echo >&2 "[dotfiles] Can't update: not a git repository."
      return
    fi

    # Check if there are updates available before proceeding
    if ! is_update_available; then
      update_last_updated_file
      return
    fi

    # If in reminder mode or user has typed input, show reminder and exit
    if [[ "$update_mode" = reminder ]] || { [[ "$update_mode" != background-alpha ]] && has_typed_input }; then
      printf '\r\e[0K' # move cursor to first column and clear whole line
      echo "[dotfiles] It's time to update! You can do that by running \`${script_dir}/dotfiler update\`"
      return 0
    fi

    # Don't ask for confirmation before updating if in auto mode
    if [[ "$update_mode" = (auto|background-alpha) ]]; then
      update_dotfiles
      return $?
    fi

    # Ask for confirmation and only update on 'y', 'Y' or Enter
    # Otherwise just show a reminder for how to update
    printf "[dotfiles] Would you like to update? [Y/n] "
    read -r -k 1 option
    [[ "$option" = $'\n' ]] || echo
    case "$option" in
      [yY$'\n']) update_dotfiles ;;
      [nN]) update_last_updated_file ;&
      *) echo "[dotfiles] You can update manually by running \`${dotfiles_dir}/dotfiler update\`" ;;
    esac
  }

  unset update_mode
  unset dotfiles_dir dotfiles_cache_dir dotfiles_timestamp
  unset -f current_epoch get_default_remote get_default_branch is_update_available update_last_updated_file update_dotfiles handle_update
 cleanup_helpers
}

case "$update_mode" in
  background-alpha)
    autoload -Uz add-zsh-hook

    _dotfiles_bg_update() {
      # do the update in a subshell
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
          print -P "\n%F{green}[dotfiles] Update successful.%f"
          return 0
        elif [[ "$EXIT_STATUS" -ne 0 ]]; then
          print -P "\n%F{red}[dotfiles] There was an error updating:%f"
          printf "\n${fg[yellow]}%s${reset_color}" "${ERROR}"
          return 0
        fi
      } always {
        if (( TRY_BLOCK_ERROR == 0 )); then
          # if last update results have been handled, remove them from the status file
          update_last_updated_file

          # deregister background function
          add-zsh-hook -d precmd _dotfiles_bg_update_status
          unset -f _dotfiles_bg_update_status
        fi
      }
    }

    add-zsh-hook precmd _dotfiles_bg_update
    ;;
  *)
    handle_update ;;
esac
