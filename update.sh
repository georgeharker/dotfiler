#!/bin/zsh

# update.sh — apply dotfiles updates from git history
#
# Structured to mirror the function-based approach of zdot's core/update.zsh
# for maintainability.  The algorithm is identical to the original:
#   1. fetch
#   2. compute range (pre-pull)
#   3. walk commits rev-by-rev with -m (merge-aware) to build file lists
#   4. pull (default mode only)
#   5. delete removed/renamed-away symlinks
#   6. unpack added/modified/renamed-to files via setup.sh
#
# Flags preserved from original: -D/--dry-run, -q/--quiet, -v/--verbose,
#   -c/--commit-hash, -r/--range, --repo-dir, --link-dest

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

script_name="${${(%):-%x}:A}"
helper_script_dir="${script_name:h}"

source "${helper_script_dir}/helpers.sh"
source "${helper_script_dir}/logging.sh"
source "${helper_script_dir}/update_core.sh"

dotfiles_dir=$(find_dotfiles_directory)
script_dir=$(find_dotfiles_script_directory)

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

commit_hash=()
range=()

function usage(){
    echo "Usage: ${script_name} [-D|--dry-run] [-q|--quiet] [-v|--verbose]"
    echo "                      [-c|--commit-hash <hash>] [-r|--range <range>]"
    echo "                      [--repo-dir <path>] [--link-dest <path>]"
}

zmodload zsh/zutil
zparseopts -D -E - \
    q=quiet -quiet=quiet \
                   v=verbose -verbose=verbose \
                   c+:=commit_hash -commit-hash+:=commit_hash \
                   r+:=range -range+:=range \
    D=dry_run -dry-run=dry_run \
    -repo-dir:=opt_repo_dir \
    -link-dest:=opt_link_dest || { usage; exit 1; }

commit_hash=("${(@)commit_hash:#-c}")
commit_hash=("${(@)commit_hash:#--commit-hash}")
range=("${(@)range:#-r}")
range=("${(@)range:#--range}")

[[ ${#quiet[@]} -gt 0 ]] && quiet_mode=true
[[ ${#verbose[@]} -gt 0 ]] && verbose_mode=true

# --repo-dir / --link-dest: override source root and symlink destination
_update_repo_dir="${opt_repo_dir[-1]:-}"
_update_link_dest="${opt_link_dest[-1]:-$HOME}"
[[ -n "$_update_repo_dir" ]] && dotfiles_dir="$_update_repo_dir"

# ---------------------------------------------------------------------------
# Helpers: safe operations (dry-run aware)
# ---------------------------------------------------------------------------

function _update_safe_rm(){
    if [[ ${#dry_run[@]} -gt 0 ]]; then
        action "[DRY RUN] Would remove: $1"
    else
        rm -f "$1"
    fi
}

# ---------------------------------------------------------------------------
# Diff range computation (mirrors update.zsh: fetch first, range pre-pull)
# ---------------------------------------------------------------------------

function _update_compute_range(){
    # Sets _update_diff_range, _update_default_remote, _update_default_branch
    # Returns 1 if nothing to do (commit/range mode with no pull)
if [[ ${#commit_hash[@]} -gt 0 ]]; then
        local target_commit="${commit_hash[1]}"
        local parent_commit
        parent_commit=$(git -C "$dotfiles_dir" rev-parse "${target_commit}^" 2>/dev/null) || {
            warn "Cannot resolve parent of ${target_commit}"; return 1
        }
        _update_diff_range="${parent_commit}..${target_commit}"
        info "Using commit hash mode: ${_update_diff_range}"
elif [[ ${#range[@]} -gt 0 ]]; then
        _update_diff_range="${range[1]}"
        info "Using range mode: ${_update_diff_range}"
else
        _update_default_remote=$(_update_core_get_default_remote "$dotfiles_dir")
        _update_default_branch=$(_update_core_get_default_branch "$dotfiles_dir" "$_update_default_remote")
        git -C "$dotfiles_dir" fetch -q \
            "$_update_default_remote" "$_update_default_branch"
        _update_diff_range="HEAD..${_update_default_remote}/${_update_default_branch}"
        info "Using ${_update_default_remote}/${_update_default_branch} mode: ${_update_diff_range}"
fi
}

# ---------------------------------------------------------------------------
# Commit-by-commit file list builder (mirrors update.zsh exactly)
# Uses -m so merge commits show diffs against each parent.
# Reconciles renames, delete/readd sequences, using unique arrays.
# ---------------------------------------------------------------------------

function _update_build_file_lists(){
    local diff_range=$1
    local git_commits line hash message git_log
    local update_type file_refs

    git_commits=$(git -C "$dotfiles_dir" log --reverse -m \
        --diff-filter=ADMRC --no-decorate \
        --pretty=format:"%H%x09%s" \
        "${diff_range}" 2>/dev/null)

for line in ${(f)git_commits}; do
        hash=${line%%$'\t'*}
        message=${line#*$'\t'}
        report "commit ${hash[1,12]}: ${message}"

        git_log=$(git -C "$dotfiles_dir" log -m --name-status \
            --diff-filter=ADMRC --no-decorate --pretty=format: \
            "${hash}...${hash}^" 2>/dev/null)

    for line in ${(f)git_log}; do
        [[ "$line" =~ "^[ADMRC][0-9]*"$'\t'".*$" ]] || continue
        update_type=${line%%$'\t'*}
        file_refs=${line#*$'\t'}

        if [[ "$update_type" == M ]]; then
                local file=$file_refs
                [[ -n "$file" ]] || continue
                verbose "  $file modified"
                files_to_unpack+=("$file")
                files_to_remove=(${files_to_remove:#"$file"})

        elif [[ "$update_type" == A ]]; then
                local file=$file_refs
                [[ -n "$file" ]] || continue
                verbose "  $file added"
                files_to_unpack+=("$file")
                files_to_remove=(${files_to_remove:#"$file"})

        elif [[ "$update_type" == C<-> ]]; then
                local dst_file=${file_refs#*$'\t'}
                [[ -n "$dst_file" ]] || continue
                verbose "  $dst_file copied"
                files_to_remove=(${files_to_remove:#"$dst_file"})
                files_to_unpack+=("$dst_file")

        elif [[ "$update_type" == R<-> ]]; then
                local src_file=${file_refs%%$'\t'*}
                local dst_file=${file_refs#*$'\t'}
                [[ -n "$dst_file" ]] || continue
                verbose "  $dst_file renamed (from $src_file)"
                files_to_unpack=(${files_to_unpack:#"$src_file"})
                files_to_remove+=("$src_file")
                files_to_unpack+=("$dst_file")

        elif [[ "$update_type" == D ]]; then
                local file=$file_refs
                [[ -n "$file" ]] || continue
                verbose "  $file deleted"
                files_to_unpack=(${files_to_unpack:#"$file"})
                files_to_remove+=("$file")
            fi
        done
    done
}

# ---------------------------------------------------------------------------
# Submodule update (runs after pull, before apply)
# ---------------------------------------------------------------------------
# Pull (default mode only, not commit-hash or range mode)
# ---------------------------------------------------------------------------

function _update_pull(){
    [[ ${#dry_run[@]} -gt 0 ]] && return 0
    [[ ${#commit_hash[@]} -gt 0 || ${#range[@]} -gt 0 ]] && return 0
    git -C "$dotfiles_dir" pull -q \
        "$_update_default_remote" "$_update_default_branch" || {
        warn "Update failed, likely modified files in the way"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Component hooks (default mode only, runs after pull)
# ---------------------------------------------------------------------------

function _update_hooks(){
    # Skip in commit-hash or range mode — hooks operate on tip, not a range.
    [[ ${#commit_hash[@]} -gt 0 || ${#range[@]} -gt 0 ]] && return 0
    local _hooks_dir
    zstyle -s ':dotfiler:hooks' dir _hooks_dir \
        || _hooks_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiler/hooks"
    [[ -d "$_hooks_dir" ]] || return 0
    local _hook _rc=0
    for _hook in "$_hooks_dir"/*.zsh(N); do
        [[ -x "$_hook" ]] || continue
        "$_hook" apply-update ${${(j. .)${dry_run:+--dry-run}}} || {
            warn "update: hook '${_hook:t}' apply-update failed (exit $?)"
            _rc=1
        }
    done
    return $_rc
}

# ---------------------------------------------------------------------------
# Apply: delete removed symlinks, unpack added/modified via setup.sh
# ---------------------------------------------------------------------------

function _update_delete_if_needed(){
    local file=$1
    local dest="${_update_link_dest}/${file}"
    if [[ -L "$dest" ]]; then
        action "cleaning up $dest"
        _update_safe_rm "$dest"
    else
        warn "$dest is not a symlink, not removing"
    fi
}

function _update_apply(){
if [[ ${#files_to_remove[@]} -gt 0 ]]; then
    action "Removing files"
    verbose "files to remove: ${files_to_remove[*]}"
    for file in "${files_to_remove[@]}"; do
            _update_delete_if_needed "$file"
    done
fi

if [[ ${#files_to_unpack[@]} -gt 0 ]]; then
    action "Unpacking files"
    verbose "files to unpack: ${files_to_unpack[*]}"

    local dry_run_arg=""
        [[ ${#dry_run[@]} -gt 0 ]] && dry_run_arg="-D"

        local setup_extra=()
        [[ -n "$_update_repo_dir" ]] && setup_extra+=(--repo-dir "$_update_repo_dir")
        [[ "$_update_link_dest" != "$HOME" ]] && setup_extra+=(--link-dest "$_update_link_dest")

        local quiet_arg=""
        [[ ${#quiet[@]} -gt 0 ]] && quiet_arg="-q"

        "${script_dir}/setup.sh" \
            ${dry_run_arg:+"$dry_run_arg"} \
            "${setup_extra[@]}" \
            -u \
            ${quiet_arg:+"$quiet_arg"} \
            "${files_to_unpack[@]}"
    fi
}

# ---------------------------------------------------------------------------
# Warn if install scripts changed
# ---------------------------------------------------------------------------

function _update_warn_install_scripts(){
    [[ ${#files_to_unpack[@]} -eq 0 ]] && return 0
    local -a modified_install_scripts=()
    local file
    for file in "${files_to_unpack[@]}"; do
        [[ "$file" == .nounpack/install/*.sh ]] && modified_install_scripts+=("$file")
    done
    if [[ ${#modified_install_scripts[@]} -gt 0 ]]; then
        warn "Install scripts modified, you may need to run dotfile install-module"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

typeset -aU files_to_unpack files_to_remove
files_to_unpack=()
files_to_remove=()

_update_compute_range || exit 0
_update_build_file_lists "$_update_diff_range"
_update_pull
_update_hooks
_update_apply
_update_warn_install_scripts

# Cleanup
unset -f \
    _update_safe_rm \
    _update_compute_range \
    _update_build_file_lists \
    _update_pull \
    _update_hooks \
    _update_delete_if_needed \
    _update_apply \
    _update_warn_install_scripts \
    2>/dev/null
_update_core_cleanup
