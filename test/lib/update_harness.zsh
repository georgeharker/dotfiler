#!/usr/bin/env zsh
# update_harness.zsh — sandboxed git fixtures + assertions for testing the
# dotfiler update machinery (and, by extension, component update impls such
# as zdot's).
#
# Design
# ------
# Real git, no fakes: fixtures are real repositories under a mktemp sandbox,
# with bare "origins" for pull/fetch scenarios (file:// transport, no
# network). Git is isolated from the user's environment via
# GIT_CONFIG_GLOBAL/SYSTEM, so nothing reads or writes user state.
#
# Layers a test file can target:
#   L1 plan      — drive _update_core_build_file_lists over crafted histories
#                  and assert on _update_core_files_to_unpack/_to_remove.
#                  (test_update_plan.zsh)
#   L2 phases    — register stub hooks via _update_register_hook that record
#                  their invocations; assert ordering/arguments.   (future)
#   L3 end-to-end— bare origin + clone + fake HOME; push upstream commits,
#                  run the update entry point, assert links on disk. (future)
#
# Extending to zdot: this file deliberately knows nothing about dotfiler's
# repo layout beyond where to source the production libraries from. A zdot
# test sources this harness from a dotfiler checkout (env DOTFILER_SRC, or
# the harness's own location when zdot embeds dotfiler), then sources
# zdot's core/update-impl.zsh on top and uses the same fixtures/assertions
# against zdot's plan/unpack functions and its own link dest.
#
# Conventions match test_gitignore_match.zsh / test_setup_args.zsh:
# pass/fail counters, section(), and harness_summary at the end.

setopt extendedglob

# Where the production code lives: the dotfiler root containing this
# harness, overridable for out-of-tree consumers (zdot).
typeset -g DOTFILER_SRC="${DOTFILER_SRC:-${${(%):-%x}:A:h:h:h}}"

source "${DOTFILER_SRC}/helpers.zsh"
source "${DOTFILER_SRC}/setup_core.zsh"    # exclusion parser shared with the plan builder
source "${DOTFILER_SRC}/update_core.zsh"

typeset -gi pass=0 fail=0
typeset -g SBX=""

section() { printf '\n--- %s ---\n' "$1"; }

# ---------------------------------------------------------------------------
# Sandbox lifecycle
# ---------------------------------------------------------------------------

harness_init() {
    SBX="$(mktemp -d)"; SBX="${SBX:A}"   # :A — dodge the macOS /tmp symlink
    mkdir -p "$SBX/repos" "$SBX/origins" "$SBX/home"

    # Git isolation: fixtures never read the user's config, hooks, or
    # attributes; identity and default branch come from a sandbox config.
    export GIT_CONFIG_SYSTEM=/dev/null
    export GIT_CONFIG_GLOBAL="$SBX/gitconfig"
    git config --file "$GIT_CONFIG_GLOBAL" user.name "harness"
    git config --file "$GIT_CONFIG_GLOBAL" user.email "harness@test"
    git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
    git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always

    # Production precondition: setup_core_main's component-exclusion pass
    # reads the hook registry, which update.zsh always initializes before
    # any hook or unpack runs. Mirror that here (subshells inherit it).
    _update_core_init_registry
}

harness_cleanup() {
    [[ -n "$SBX" && -d "$SBX" ]] && rm -rf "$SBX"
    SBX=""
}

# NOTE: a zsh `trap ... EXIT` registered inside a function fires when that
# FUNCTION returns — registering cleanup inside harness_init would destroy
# the sandbox immediately. Register at file (sourcing) scope instead, which
# binds it to the test script's exit.
trap 'harness_cleanup' EXIT INT TERM

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# fixture_repo <name> [file=content ...]
#   Create $SBX/repos/<name> with an initial commit containing the given
#   files. Always seeds an EMPTY always_exclude: without one, the plan
#   builder falls back to dotfiler's own always_exclude, which would couple
#   tests to its contents. Tests that want exclusion behavior write their
#   own always_exclude/exclude files via fixture_commit.
#   Sets REPLY to the repo path.
fixture_repo() {
    local _name=$1; shift
    local _repo="$SBX/repos/$_name"
    mkdir -p "$_repo"
    git -C "$_repo" init -q -b main
    : > "$_repo/always_exclude"
    git -C "$_repo" add -A
    fixture_commit "$_repo" "init" "$@"
    REPLY="$_repo"
}

# fixture_commit <repo> <msg> [spec ...]
#   spec: file=content     write file (parent dirs created) and stage it
#         --rm=file        git rm
#         --mv=src:dst     git mv
#   Empty spec list yields an --allow-empty commit.
fixture_commit() {
    local _repo=$1 _msg=$2; shift 2
    local _spec _f
    for _spec in "$@"; do
        case "$_spec" in
            --rm=*) git -C "$_repo" rm -q -- "${_spec#--rm=}" ;;
            --mv=*) local _pair="${_spec#--mv=}"
                    git -C "$_repo" mv -- "${_pair%%:*}" "${_pair#*:}" ;;
            *=*)    _f="${_spec%%=*}"
                    mkdir -p "$_repo/${_f:h}"
                    print -r -- "${_spec#*=}" > "$_repo/$_f"
                    git -C "$_repo" add -- "$_f" ;;
            *)      printf 'harness: bad fixture_commit spec: %s\n' "$_spec"
                    return 1 ;;
        esac
    done
    git -C "$_repo" commit -q --allow-empty -m "$_msg"
}

# fixture_branch_merge <repo> <branch> <merge-msg> <commit-msg> [spec ...]
#   Create <branch> from HEAD, commit the specs on it, return to main and
#   merge --no-ff. Exercises the plan builder's --first-parent handling:
#   the branch's files must arrive via the merge commit's parent-1 diff.
fixture_branch_merge() {
    local _repo=$1 _branch=$2 _merge_msg=$3 _commit_msg=$4; shift 4
    git -C "$_repo" checkout -q -b "$_branch"
    fixture_commit "$_repo" "$_commit_msg" "$@"
    git -C "$_repo" checkout -q main
    git -C "$_repo" merge -q --no-ff -m "$_merge_msg" "$_branch"
}

# fixture_origin <repo>
#   Create a bare origin from an existing fixture repo and wire it as
#   `origin`. For L3 scenarios: push upstream changes from a second clone,
#   then fetch in the primary. Sets REPLY to the bare path.
fixture_origin() {
    local _repo=$1
    local _bare="$SBX/origins/${_repo:t}.git"
    git clone -q --bare "$_repo" "$_bare"
    git -C "$_repo" remote add origin "$_bare"
    git -C "$_repo" fetch -q origin
    REPLY="$_bare"
}

# repo_sha <repo> [ref]
repo_sha() { git -C "$1" rev-parse "${2:-HEAD}" }

# fixture_subtree_add <parent> <child> <prefix> [--squash]
#   Add <child> into <parent> at <prefix> via git subtree.
fixture_subtree_add() {
    local _parent=$1 _child=$2 _prefix=$3 _squash=${4:-}
    git -C "$_parent" subtree add -q --prefix="$_prefix" "$_child" main \
        ${_squash:+--squash}
}

# fixture_subtree_pull <parent> <child> <prefix> [--squash]
fixture_subtree_pull() {
    local _parent=$1 _child=$2 _prefix=$3 _squash=${4:-}
    git -C "$_parent" subtree pull -q --prefix="$_prefix" "$_child" main \
        ${_squash:+--squash} -m "subtree pull $_prefix"
}

# fixture_submodule_add <parent> <child> <path>
fixture_submodule_add() {
    local _parent=$1 _child=$2 _path=$3
    git -C "$_parent" -c protocol.file.allow=always \
        submodule add -q "$_child" "$_path"
    git -C "$_parent" commit -qm "add submodule $_path"
}

# ---------------------------------------------------------------------------
# Execute layer: run the production unpack/remove the way update.zsh does
# ---------------------------------------------------------------------------

# update_unpack_exec [-U] <repo> [file ...]
#   Mirror _update_main_unpack's invocation: setup_core_main in a subshell
#   with the planned files as positionals. Link dest is the sandbox home.
update_unpack_exec() {
    local _flag="-u"
    [[ "${1:-}" == "-U" ]] && { _flag="-U"; shift; }
    local _repo=$1; shift
    (
        typeset -ga _dotfiler_registered_hooks
        setup_core_main "$_flag" -y -q \
            --repo-dir "$_repo" --link-dest "$SBX/home" \
            --excludes "$_repo/dotfiles_exclude" "$@"
    )
}

# update_remove_exec <file ...>
#   Mirror update.zsh's removal loop: delete the dest only if it is a symlink.
update_remove_exec() {
    local _f _dest
    for _f in "$@"; do
        _dest="$SBX/home/$_f"
        [[ -L "$_dest" ]] && rm -f -- "$_dest"
    done
}

# ---------------------------------------------------------------------------
# Plan invocation (L1)
# ---------------------------------------------------------------------------

# plan_run [--excludes file] <repo> <range>
#   Reset the plan arrays and run the production builder.
plan_run() {
    typeset -gaU _update_core_files_to_unpack _update_core_files_to_remove
    _update_core_files_to_unpack=()
    _update_core_files_to_remove=()
    _update_core_build_file_lists "$@"
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

# assert_unpack <desc> <file ...>   — every file is in the unpack plan
assert_unpack() {
    local _desc=$1; shift
    local _f _missing=""
    for _f in "$@"; do
        (( ${_update_core_files_to_unpack[(Ie)$_f]} )) || _missing+=" $_f"
    done
    if [[ -z "$_missing" ]]; then
        (( pass++ ))
    else
        printf 'FAIL  %s\n      missing from unpack:%s\n      unpack=(%s)\n' \
            "$_desc" "$_missing" "${_update_core_files_to_unpack[*]}"
        (( fail++ ))
    fi
}

# assert_remove <desc> <file ...>   — every file is in the remove plan
assert_remove() {
    local _desc=$1; shift
    local _f _missing=""
    for _f in "$@"; do
        (( ${_update_core_files_to_remove[(Ie)$_f]} )) || _missing+=" $_f"
    done
    if [[ -z "$_missing" ]]; then
        (( pass++ ))
    else
        printf 'FAIL  %s\n      missing from remove:%s\n      remove=(%s)\n' \
            "$_desc" "$_missing" "${_update_core_files_to_remove[*]}"
        (( fail++ ))
    fi
}

# assert_not_unpack <desc> <file ...> — file is NOT in the unpack plan
# (it may legitimately be in the remove plan)
assert_not_unpack() {
    local _desc=$1; shift
    local _f _hit=""
    for _f in "$@"; do
        (( ${_update_core_files_to_unpack[(Ie)$_f]} )) && _hit+=" $_f"
    done
    if [[ -z "$_hit" ]]; then
        (( pass++ ))
    else
        printf 'FAIL  %s\n      unexpectedly in unpack:%s\n' "$_desc" "$_hit"
        (( fail++ ))
    fi
}

# assert_not_planned <desc> <file ...> — file appears in NEITHER plan array
assert_not_planned() {
    local _desc=$1; shift
    local _f _hit=""
    for _f in "$@"; do
        (( ${_update_core_files_to_unpack[(Ie)$_f]} )) && _hit+=" unpack:$_f"
        (( ${_update_core_files_to_remove[(Ie)$_f]} )) && _hit+=" remove:$_f"
    done
    if [[ -z "$_hit" ]]; then
        (( pass++ ))
    else
        printf 'FAIL  %s\n      unexpectedly planned:%s\n' "$_desc" "$_hit"
        (( fail++ ))
    fi
}

# assert_plan_counts <desc> <n-unpack> <n-remove>
assert_plan_counts() {
    local _desc=$1 _eu=$2 _er=$3
    local _gu=${#_update_core_files_to_unpack[@]}
    local _gr=${#_update_core_files_to_remove[@]}
    if [[ "$_gu" == "$_eu" && "$_gr" == "$_er" ]]; then
        (( pass++ ))
    else
        printf 'FAIL  %s\n      counts: unpack=%s want=%s, remove=%s want=%s\n      unpack=(%s) remove=(%s)\n' \
            "$_desc" "$_gu" "$_eu" "$_gr" "$_er" \
            "${_update_core_files_to_unpack[*]}" "${_update_core_files_to_remove[*]}"
        (( fail++ ))
    fi
}

# ---------------------------------------------------------------------------
# Disk-state assertions (target mode)
# ---------------------------------------------------------------------------

# assert_link_at <desc> <abs-path> <abs-target>
#   Generic: path is a symlink with exactly the given target.
assert_link_at() {
    local _desc=$1 _dest=$2 _target=$3
    if [[ -L "$_dest" && "$(readlink "$_dest")" == "$_target" ]]; then
        (( pass++ ))
    else
        local _got="not a symlink"
        [[ -L "$_dest" ]] && _got="$(readlink "$_dest")"
        printf 'FAIL  %s\n      %s: link=%s want=%s\n' "$_desc" "$_dest" \
            "$_got" "$_target"
        (( fail++ ))
    fi
}

# assert_content_at <desc> <abs-path> <expected>
assert_content_at() {
    local _desc=$1 _dest=$2 _expect=$3
    local _got=""
    [[ -r "$_dest" ]] && _got="$(<"$_dest")"
    if [[ "$_got" == "$_expect" ]]; then
        (( pass++ ))
    else
        printf 'FAIL  %s\n      %s: content=%s want=%s\n' \
            "$_desc" "$_dest" "${_got:-<unreadable>}" "$_expect"
        (( fail++ ))
    fi
}

# assert_absent_at <desc> <abs-path>
assert_absent_at() {
    local _desc=$1 _dest=$2
    if [[ ! -e "$_dest" && ! -L "$_dest" ]]; then
        (( pass++ ))
    else
        printf 'FAIL  %s\n      %s still exists\n' "$_desc" "$_dest"
        (( fail++ ))
    fi
}

# assert_dest_link <desc> <home-rel> <repo>
#   The dest path is a symlink pointing at the repo's copy of the same file.
assert_dest_link() {
    assert_link_at "$1" "$SBX/home/$2" "$3/$2"
}

# assert_dest_content <desc> <home-rel> <expected>
#   Reading the dest path (through any symlink) yields the expected content.
assert_dest_content() {
    assert_content_at "$1" "$SBX/home/$2" "$3"
}

# assert_dest_absent <desc> <home-rel>
assert_dest_absent() {
    assert_absent_at "$1" "$SBX/home/$2"
}

harness_summary() {
    printf '\n%d passed, %d failed\n' $pass $fail
    (( fail == 0 ))
}
