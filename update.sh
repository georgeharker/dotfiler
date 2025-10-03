#!/bin/zsh


# Capture script name early before functions change context
script_name="${${(%):-%x}:A}"
helper_script_dir="${script_name:h}"

source "${helper_script_dir}/helpers.sh"

# Detect script directory - handle being in .nounpack/scripts/
dotfiles_dir=$(find_dotfiles_directory)
script_dir=$(find_dotfiles_script_directory)

commit_hash=()
range=()
function usage(){
  echo "Usage: ${script_name} [-D | --dry_run] [--quiet | -q] [--commit-hash hash | -c hash] [--range range | -r range]"
}

zmodload zsh/zutil
zparseopts -D -E - q=quiet -q=quiet \
                   c+:=commit_hash -commit-hash+:=commit_hash \
                   r+:=range -range+:=range \
                   D=dry_run -dry-run=dry_run || \
  (usage; exit 1)

# Clean up commit_hash array
commit_hash=("${(@)commit_hash:#-c}")
commit_hash=("${(@)commit_hash:#--commit-hash}")
# Clean up range array
range=("${(@)range:#-r}")
range=("${(@)range:#--range}")
if [[ `uname` != "Darwin" ]]; then
# Set quiet mode for helpers
[[ ${#quiet[@]} -gt 0 ]] && quiet_mode=true

    GREP=("grep" "-P")
else
    GREP="grep"
fi

# Ensure relative to dotfiles
cd "${dotfiles_dir}"

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
    local ref_output default_branch
    ref_output=$(git symbolic-ref refs/remotes/${remote}/HEAD 2>/dev/null)
    default_branch="${ref_output#refs/remotes/${remote}/}"
    
    # If that fails, try to get it from remote show
    if [[ -z "$default_branch" ]]; then
        local remote_output line
        remote_output=$(git remote show "$remote" 2>/dev/null)
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

# Process git changes using zsh array operations
local git_deleted git_added git_modified
git_deleted=$(git log -m -1 --name-status --diff-filter=D --no-decorate --pretty=oneline ${diff_range})
git_added=$(git log -m -1 --name-status --diff-filter=A --no-decorate --pretty=oneline ${diff_range})
git_modified=$(git log -m -1 --name-status --diff-filter=M --no-decorate --pretty=oneline ${diff_range})
modified_files=()
for line in ${(f)git_modified}; do
    [[ "$line" == M$'\t'* ]] || continue
    local file="${line#M$'\t'}"
    if [[ -n "$file" ]]; then
        info "found $file as modified"
        modified_files+=("$file")
    fi
done

# Only pull in origin/master mode
if [[ ${#commit_hash[@]} == 0 && ${#range[@]} == 0 ]]; then
    default_remote=$(get_default_remote)
    default_branch=$(get_default_branch "$default_remote")
    git pull "$default_remote" "$default_branch"
fi

function safe_rm(){
    if [[ ${#dry_run[@]} -gt 0 ]]; then
        action "[DRY RUN] Would remove: $1"
    else
        rm "$1"
    fi
}

delete_if_needed(){
    src=$1:A
    fullpath_dotfiles_dir=$dotfiles_dir:A
    dest="$HOME/"${1#$fullpath_dotfiles_dir/}
    destdir="$dotfiles_dir/"`dirname ${src#$fullpath_home/}`
    if [[ -L "$dest" ]]; then
        action "cleaning up $dest"
        safe_rm "$dest"
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
    local dry_run_arg=""
    if [[ ${#dry_run[@]} -gt 0 ]]; then
        dry_run_arg="-D"
    fi
    if [[ ${#quiet[@]} == 0 ]]; then
        ${script_dir}"/setup.sh" "${dry_run_arg}" -u "${files_to_unpack[@]}"
    else
        ${script_dir}"/setup.sh" "${dry_run_arg}" -u -q "${files_to_unpack[@]}"
    fi
fi
