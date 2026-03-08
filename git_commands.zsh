#!/bin/zsh
# git_commands.zsh - Transparent git wrappers for common dotfiles repo operations.
#
# Each command prints the underlying git invocation so there is no magic.
# These are conveniences, not replacements for git — use git directly for
# anything more complex.
#
# All commands accept --help / -h for per-command usage.

source "${0:A:h}/helpers.zsh"
source "${0:A:h}/logging.zsh"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

function _gc_dotfiles_dir() {
    find_dotfiles_directory
}

# Run a git command against the dotfiles repo, printing it first.
function _gc_run() {
    local dotfiles_dir="$1"; shift
    info "git -C $dotfiles_dir $*"
    git -C "$dotfiles_dir" "$@"
}

# ---------------------------------------------------------------------------
# ingest
# ---------------------------------------------------------------------------

function _gc_usage_ingest() {
    cat <<EOF
Usage: dotfiler ingest <file> [<file> ...]

Move one or more files from \$HOME into the dotfiles repo and replace them
with symlinks. This is a wrapper around 'dotfiler setup -i'.

Each <file> should be an absolute path or a path relative to \$HOME.

Examples:
    dotfiler ingest ~/.zshrc
    dotfiler ingest ~/.config/starship.toml
EOF
}

function _gc_ingest() {
    if [[ $# -eq 0 || "$1" == --help || "$1" == -h ]]; then
        _gc_usage_ingest
        return $(( $# == 0 ))
    fi

    local script_dir="${0:A:h}"
    # Delegate entirely to setup -i; it owns the ingest logic.
    info "dotfiler setup -i $*"
    exec "$script_dir/setup.zsh" -i "$@"
}

# ---------------------------------------------------------------------------
# add
# ---------------------------------------------------------------------------

function _gc_usage_add() {
    cat <<EOF
Usage: dotfiler add [<pathspec> ...]

Stage files in the dotfiles repo. Equivalent to:
    git -C <dotfiles-dir> add [<pathspec> ...]

With no pathspecs, stages nothing (git behaviour). Use '.' to stage all
changes, or pass individual paths relative to the dotfiles repo root or
as absolute paths inside the repo.

Examples:
    dotfiler add .zshrc
    dotfiler add .config/starship.toml
    dotfiler add .
EOF
}

function _gc_add() {
    if [[ "$1" == --help || "$1" == -h ]]; then
        _gc_usage_add
        return 0
    fi

    local dotfiles_dir
    dotfiles_dir=$(_gc_dotfiles_dir)
    _gc_run "$dotfiles_dir" add "$@"
}

# ---------------------------------------------------------------------------
# commit
# ---------------------------------------------------------------------------

function _gc_usage_commit() {
    cat <<EOF
Usage: dotfiler commit [-m <message>] [<git-commit-options>...]

Commit staged changes in the dotfiles repo. Equivalent to:
    git -C <dotfiles-dir> commit [options]

All arguments are passed through to git commit unchanged.

Examples:
    dotfiler commit -m "Add starship config"
    dotfiler commit -a -m "Update zshrc"
EOF
}

function _gc_commit() {
    if [[ "$1" == --help || "$1" == -h ]]; then
        _gc_usage_commit
        return 0
    fi

    local dotfiles_dir
    dotfiles_dir=$(_gc_dotfiles_dir)
    _gc_run "$dotfiles_dir" commit "$@"
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

function _gc_usage_status() {
    cat <<EOF
Usage: dotfiler status [--fetch]

Show the current state of the dotfiles repo in three sections:

  1. Working tree — modified, staged, and untracked files (git status)
  2. Ahead        — local commits not yet pushed to upstream
  3. Behind       — upstream commits not yet pulled (requires --fetch or a
                    recent fetch; otherwise uses cached remote refs)

Options:
    --fetch    Fetch from remote before checking ahead/behind state

Examples:
    dotfiler status
    dotfiler status --fetch
EOF
}

function _gc_status() {
    local do_fetch=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fetch) do_fetch=1; shift ;;
            --help|-h) _gc_usage_status; return 0 ;;
            *) warn "Unknown option: $1"; _gc_usage_status; return 1 ;;
        esac
    done

    local dotfiles_dir
    dotfiles_dir=$(_gc_dotfiles_dir)

    # --- Section 1: working tree ---
    info "git -C $dotfiles_dir status --short"
    local status_out
    status_out=$(git -C "$dotfiles_dir" status --short 2>&1)
    if [[ -n "$status_out" ]]; then
        echo ""
        action "Working tree changes:"
        echo "$status_out"
    else
        echo ""
        success "Working tree clean."
    fi

    # --- Optional fetch ---
    if (( do_fetch )); then
        echo ""
        info "git -C $dotfiles_dir fetch"
        git -C "$dotfiles_dir" fetch 2>&1
    fi

    # --- Section 2: ahead (local commits not pushed) ---
    echo ""
    info "git -C $dotfiles_dir log @{u}.. --oneline"
    local ahead_out
    ahead_out=$(git -C "$dotfiles_dir" log '@{u}..' --oneline 2>/dev/null)
    local ahead_rc=$?
    if (( ahead_rc != 0 )); then
        warn "Could not determine ahead/behind state (no upstream configured?)."
    elif [[ -n "$ahead_out" ]]; then
        action "Commits not yet pushed:"
        echo "$ahead_out"
    else
        success "Nothing to push."
    fi

    # --- Section 3: behind (upstream commits not pulled) ---
    echo ""
    info "git -C $dotfiles_dir log ..@{u} --oneline"
    local behind_out
    behind_out=$(git -C "$dotfiles_dir" log '..@{u}' --oneline 2>/dev/null)
    if (( $? == 0 )); then
        if [[ -n "$behind_out" ]]; then
            action "Upstream commits not yet pulled$(( do_fetch )) && echo '' || echo ' (run --fetch for current state)':"
            echo "$behind_out"
        else
            (( do_fetch )) \
                && success "Up to date with upstream." \
                || success "Up to date with upstream (cached; run --fetch for current state)."
        fi
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# push
# ---------------------------------------------------------------------------

function _gc_usage_push() {
    cat <<EOF
Usage: dotfiler push [<git-push-options>...]

Push commits in the dotfiles repo to its remote. Equivalent to:
    git -C <dotfiles-dir> push [options]

All arguments are passed through to git push unchanged.

Examples:
    dotfiler push
    dotfiler push --force-with-lease
EOF
}

function _gc_push() {
    if [[ "$1" == --help || "$1" == -h ]]; then
        _gc_usage_push
        return 0
    fi

    local dotfiles_dir
    dotfiles_dir=$(_gc_dotfiles_dir)
    _gc_run "$dotfiles_dir" push "$@"
}

# ---------------------------------------------------------------------------
# Dispatch — called from dotfiler main script
# ---------------------------------------------------------------------------

function _gc_dispatch() {
    local verb="$1"; shift
    case "$verb" in
        ingest)  _gc_ingest  "$@" ;;
        add)     _gc_add     "$@" ;;
        commit)  _gc_commit  "$@" ;;
        status)  _gc_status  "$@" ;;
        push)    _gc_push    "$@" ;;
        *)
            error "git_commands: unknown verb '$verb'"
            return 1
            ;;
    esac
}

case "${1:-}" in
    --help|-h)
        cat <<EOF
Usage: dotfiler <command> [options]

Git wrappers (transparent — each prints the underlying git command):
    ingest <file>...    Move homedir file(s) into repo and symlink back
    add [<path>...]     Stage files in the dotfiles repo (git add)
    commit [options]    Commit staged changes (git commit)
    status [--fetch]    Show working tree, ahead, and behind state
    push [options]      Push commits to remote (git push)

Run 'dotfiler <command> --help' for per-command usage.
EOF
        ;;
    '')
        error "git_commands: no command specified"
        exit 1
        ;;
    *)
        _gc_dispatch "$@"
        ;;
esac
