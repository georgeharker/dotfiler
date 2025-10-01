#!/bin/zsh

script_dir=`dirname $0`
script_dir=$script_dir:A

# Allow override of dotfiles directory via zstyle
zstyle -s ':dotfiles:directory' path dotfiles_override
if [[ -n "$dotfiles_override" ]]; then
  script_dir="${dotfiles_override:A}"
fi

commit_hash=()
range=()
function usage(){
  echo "Usage: $0 [--quiet | -q] [--commit-hash hash | -c hash] [--range range | -r range]"
}

zmodload zsh/zutil
zparseopts -D -E - q=quiet -q=quiet \
                   c+:=commit_hash -commit-hash+:=commit_hash \
                   r+:=range -range+:=range || \
  (usage; exit 1)

# Clean up commit_hash array
commit_hash=("${(@)commit_hash:#-c}")
commit_hash=("${(@)commit_hash:#--commit-hash}")
# Clean up range array
range=("${(@)range:#-r}")
range=("${(@)range:#--range}")
if [[ `uname` != "Darwin" ]]; then
    GREP=("grep" "-P")
else
    GREP="grep"
fi

function info(){
    [[ ${#quiet[@]} == 0 ]] && print -P "$@"
}
function info_nonl(){
    [[ ${#quiet[@]} == 0 ]] && print -n -P "$@"
}
function action(){
    [[ ${#quiet[@]} == 0 ]] && print -P "%F{blue}$@%f"
}
function error(){
    [[ ${#quiet[@]} == 0 ]] && print -P "%F{red}$@%f"
}
function warn(){
    [[ ${#quiet[@]} == 0 ]] && print -P "%F{yellow}$@%f"
}

# Ensure relative to dotfiles
cd "${script_dir}"

# Get default remote and branch
function get_default_remote(){
    # Get the remote that the current branch tracks, fallback to 'origin'
    local current_branch=$(git branch --show-current)
    local upstream=$(git config --get branch.${current_branch}.remote 2>/dev/null)
    if [[ -n "$upstream" ]]; then
        echo "$upstream"
    else
        # Fallback to first remote, typically 'origin'
        git remote | head -n1
    fi
}

function get_default_branch(){
    local remote="${1:-$(get_default_remote)}"
    
    # Try to get the default branch from remote HEAD
    local default_branch=$(git symbolic-ref refs/remotes/${remote}/HEAD 2>/dev/null | sed "s@^refs/remotes/${remote}/@@")
    
    # If that fails, try to get it from remote show
    if [[ -z "$default_branch" ]]; then
        default_branch=$(git remote show "$remote" 2>/dev/null | grep "HEAD branch" | cut -d: -f2 | tr -d ' ')
    fi
    
    # Final fallback to common default branches
    if [[ -z "$default_branch" ]]; then
        for branch in main master; do
            if git show-ref --verify --quiet refs/remotes/${remote}/${branch}; then
                default_branch="$branch"
                break
            fi
        done
    fi
    
    echo "$default_branch"
}

# Determine diff range based on mode
if [[ ${#commit_hash[@]} -gt 0 ]]; then
    # Commit hash mode: diff between specified commit and its parent
    target_commit="${commit_hash[1]}"
    parent_commit=$(git rev-parse "${target_commit}^")
    diff_range="${parent_commit}..${target_commit}"
    info "Using commit hash mode: ${diff_range}"
elif [[ ${#range[@]} -gt 0 ]]; then
    # Range mode: use specified range directly
    diff_range="${range[1]}"
    info "Using range mode: ${diff_range}"
else
    # Default mode: diff between local HEAD and default remote/branch
    default_remote=$(get_default_remote)
    default_branch=$(get_default_branch "$default_remote")
    
    git fetch -q "$default_remote" "$default_branch"
    diff_range="HEAD...${default_remote}/${default_branch}"
    info "Using ${default_remote}/${default_branch} mode: ${diff_range}"
fi

deleted_files=()
while IFS= read -r file; do
    if [[ -n "$file" ]]; then
        warn "found $file as deleted"
        deleted_files+=("$file")
    fi
done < <(git log -m -1 --name-status --diff-filter=D --no-decorate --pretty=oneline ${diff_range} | ${GREP} "^D\t" | cut -f 2)

added_files=()
while IFS= read -r file; do
    if [[ -n "$file" ]]; then
        info "found $file as added"
        added_files+=("$file")
    fi
done < <(git log -m -1 --name-status --diff-filter=A --no-decorate --pretty=oneline ${diff_range} | ${GREP} "^A\t" | cut -f 2)

modified_files=()
while IFS= read -r file; do
    if [[ -n "$file" ]]; then
        info "found $file as modified"
        modified_files+=("$file")
    fi
done < <(git log -m -1 --name-status --diff-filter=M --no-decorate --pretty=oneline ${diff_range} | ${GREP} "^M\t" | cut -f 2)

# Only pull in origin/master mode
if [[ ${#commit_hash[@]} == 0 && ${#range[@]} == 0 ]]; then
    default_remote=$(get_default_remote)
    default_branch=$(get_default_branch "$default_remote")
    git pull "$default_remote" "$default_branch"
fi

delete_if_needed(){
    src=$1:A
    fullpath_script_dir=$script_dir:A
    dest="$HOME/"${1#$fullpath_script_dir/}
    destdir="$script_dir/"`dirname ${src#$fullpath_home/}`
    if [[ -L "$dest" ]]; then
        action "cleaning up $dest"
        rm "$dest"
    else
        warn "$dest is not a symlink, not removing"
    fi
}

echo ${deleted_files}
echo ${deleted_files[@]}
for file in ${deleted_files[@]}; do
    info "checking deleted $file"
    delete_if_needed "$file"
done

# Combine added and modified files for unpacking
files_to_unpack=("${added_files[@]}" "${modified_files[@]}")

if [[ ${#files_to_unpack[@]} -gt 0 ]]; then
    info "files to unpack (added: ${#added_files[@]}, modified: ${#modified_files[@]}): ${files_to_unpack[*]}"
    if [[ ${#quiet[@]} == 0 ]]; then
        ${script_dir}"/setup.sh" -u "${files_to_unpack[@]}"
    else
        ${script_dir}"/setup.sh" -u -q "${files_to_unpack[@]}"
    fi
fi
