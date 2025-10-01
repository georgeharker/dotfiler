#!/bin/zsh

# Check if script is being executed directly (not sourced)
# In zsh, when sourced, $0 is the name of the calling shell, not the script
force_update=false
if [[ "${(%):-%N}" == "${0:t}" ]] || [[ "$0" == *"check_update.sh" ]]; then
    # Script is being executed directly, parse arguments
    zmodload zsh/zutil
    local -a force
    zparseopts -D -E - f=force -force=force || {
        echo "Usage: $0 [-f|--force]" >&2
        echo "  -f, --force    Force update check even if timestamp is recent" >&2
        exit 1
    }
    
    if [[ ${#force[@]} -gt 0 ]]; then
        force_update=true
    fi
fi

# Allow override of dotfiles directory via zstyle
zstyle -s ':dotfiles:directory' path dotfiles || dotfiles="${HOME}/.dotfiles"
dotfiles="${dotfiles:A}"  # Convert to absolute path

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
# - the current user doesn't have write permissions nor owns the $dotfiles directory
# - is not run from a tty
# - git is unavailable on the system
# - $dotfiles is not a git repository
if [[ "$update_mode" = disabled ]] \
   || [[ ! -w "$dotfiles" || ! -O "$dotfiles" ]] \
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
    local current_branch=$(builtin cd -q "$dotfiles"; git branch --show-current)
    local upstream=$(builtin cd -q "$dotfiles"; git config --get branch.${current_branch}.remote 2>/dev/null)
    if [[ -n "$upstream" ]]; then
        echo "$upstream"
    else
        # Fallback to first remote, typically 'origin'
        builtin cd -q "$dotfiles"; git remote | head -n1
    fi
}

function get_default_branch(){
    local remote="${1:-$(get_default_remote)}"
    
    # Try to get the default branch from remote HEAD
    local default_branch=$(builtin cd -q "$dotfiles"; git symbolic-ref refs/remotes/${remote}/HEAD 2>/dev/null | sed "s@^refs/remotes/${remote}/@@")
    
    # If that fails, try to get it from remote show
    if [[ -z "$default_branch" ]]; then
        default_branch=$(builtin cd -q "$dotfiles"; git remote show "$remote" 2>/dev/null | grep "HEAD branch" | cut -d: -f2 | tr -d ' ')
    fi
    
    # Final fallback to common default branches
    if [[ -z "$default_branch" ]]; then
        for branch in main master; do
            if (builtin cd -q "$dotfiles"; git show-ref --verify --quiet refs/remotes/${remote}/${branch}); then
                default_branch="$branch"
                break
            fi
        done
    fi
    
    echo "$default_branch"
}

function is_update_available() {
  local branch
  # Use unlikely defaults that we can detect and replace with dynamic detection
  branch=${"$(builtin cd -q "$dotfiles"; git config --local oh-my-zsh.branch)":-__DOTFILES_UNLIKELY_BRANCH__}
  
  # If the unlikely default was used, detect actual default branch
  if [[ "$branch" == "__DOTFILES_UNLIKELY_BRANCH__" ]]; then
      branch=$(get_default_branch)
  fi

  local remote remote_url remote_repo
  # Use unlikely defaults that we can detect and replace with dynamic detection
  remote=${"$(builtin cd -q "$dotfiles"; git config --local oh-my-zsh.remote)":-__DOTFILES_UNLIKELY_REMOTE__}
  
  # If the unlikely default was used, detect actual default remote
  if [[ "$remote" == "__DOTFILES_UNLIKELY_REMOTE__" ]]; then
      remote=$(get_default_remote)
  fi
  
  remote_url=$(builtin cd -q "$dotfiles"; git config remote.$remote.url)

  local repo
  case "$remote_url" in
  https://github.com/*) repo=${${remote_url#https://github.com/}%.git} ;;
  git@github.com:*) repo=${${remote_url#git@github.com:}%.git} ;;
  *)
    # If the remote is not using GitHub we can't check for updates
    # Let's assume there are updates
    return 0 ;;
  esac

  local api_url="https://api.github.com/repos/${repo}/commits/${branch}"

  # Get local HEAD. If this fails assume there are updates
  local local_head
  local_head=$(builtin cd -q "$dotfiles"; git rev-parse $branch 2>/dev/null) || return 0

  # Get remote HEAD. If no suitable command is found assume there are updates
  # On any other error, skip the update (connection may be down)
  local remote_head
  remote_head=$(
    if (( ${+commands[curl]} )); then
      curl --connect-timeout 2 -fsSL -H 'Accept: application/vnd.github.v3.sha' -H "Authorization: Bearer ${GH_TOKEN}" $api_url 2>/dev/null
    elif (( ${+commands[wget]} )); then
      wget -T 2 -O- --header='Accept: application/vnd.github.v3.sha' --header="Authorization: Bearer ${GH_TOKEN}"  $api_url 2>/dev/null
    else
      exit 0
    fi
  ) || return 1

  # Compare local and remote HEADs (if they're equal there are no updates)
  [[ "$local_head" != "$remote_head" ]] || return 1

  # If local and remote HEADs don't match, check if there's a common ancestor
  # If the merge-base call fails, $remote_head might not be downloaded so assume there are updates
  local base
  base=$(builtin cd -q "$dotfiles"; git merge-base $local_head $remote_head 2>/dev/null) || return 0

  # If the common ancestor ($base) is not $remote_head,
  # the local HEAD is older than the remote HEAD
  [[ $base != $remote_head ]]
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
    && LANG= ZSH="$ZSH" zsh -f "$dotfiles/update.sh" "$quiet"; then
    update_last_updated_file
    return $?
  fi

  local exit_status error
  if error=$(LANG= ZSH="$ZSH" zsh -f "$dotfiles/update.sh" -q 2>&1); then
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
      unset dotfiles dotfiles_cache_dir dotfiles_timestamp 2>/dev/null
      unset -f current_epoch get_default_remote get_default_branch is_update_available update_last_updated_file update_dotfiles handle_update 2>/dev/null
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
    # Test if enough time has passed until the next update
    if (( ( $(current_epoch) - $LAST_EPOCH ) < $epoch_target )); then
      if [[ "$force_update" != "true" ]]; then
        return
      else
        echo "[dotfiles] Forcing update check despite recent timestamp"
      fi
    fi

    # Test if Oh My Zsh directory is a git repository
    if ! (builtin cd -q "$dotfiles" && LANG= git rev-parse &>/dev/null); then
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
      echo "[dotfiles] It's time to update! You can do that by running \`${dotfiles}/update.sh\`"
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
      *) echo "[dotfiles] You can update manually by running \`${dotfiles}/update.sh\`" ;;
    esac
  }

  unset update_mode
  unset dotfiles dotfiles_cache_dir dotfiles_timestamp
  unset -f current_epoch get_default_remote get_default_branch is_update_available update_last_updated_file update_dotfiles handle_update
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
