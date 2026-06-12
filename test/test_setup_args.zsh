#!/usr/bin/env zsh
# test_setup_args.zsh — regression tests for `dotfiler setup` argument handling
# and path normalization.
#
# Covers the CLI contract:
#   - exactly one action flag per invocation, all positionals are its file list
#   - unpack path modalities: files may be named by where they land (home) or
#     where they live (repo), absolute or CWD-relative
#   - the update-cycle invocation shapes (setup_core_main called directly with
#     -u/-U + positional file lists, as update.zsh and zdot's update-impl do)
#
# Each check runs setup.zsh (or setup_core_main) against a throwaway
# HOME/dotfiles sandbox. Exit status: 0 = all passed.
setopt extendedglob

local script_dir="${0:A:h}"
local setup_zsh="${script_dir}/../setup.zsh"
local core_dir="${script_dir}/.."

typeset -i pass=0 fail=0

section() { printf '\n--- %s ---\n' "$1"; }

# Fresh sandbox: $H (fake home) containing $H/.dotfiles with the given
# repo-relative files committed. Sets globals H and DOTREPO.
make_sandbox() {
    # :A resolves /tmp → /private/tmp on macOS; the normalizer deliberately
    # does not resolve symlinks in inputs, so the sandbox must not sit
    # behind one.
    H="$(mktemp -d)" ; H="${H:A}"
    DOTREPO="$H/.dotfiles"
    mkdir -p "$DOTREPO"
    local f
    for f in "$@"; do
        mkdir -p "$DOTREPO/${f:h}"
        print -r -- "content-$f" > "$DOTREPO/$f"
    done
    git -C "$DOTREPO" init -q
    git -C "$DOTREPO" add -A
    git -C "$DOTREPO" -c user.email=t@t -c user.name=t commit -qm init
}

destroy_sandbox() { rm -rf "$H"; }

# run_setup <cwd> <args...> — run setup.zsh from <cwd> inside the sandbox.
# Output goes to $REPLY_OUT; return status preserved.
run_setup() {
    local _cwd="$1"; shift
    REPLY_OUT="$(cd "$_cwd" && env HOME="$H" XDG_CONFIG_HOME="$H/.config" \
        zsh "$setup_zsh" "$@" -y --repo-dir "$DOTREPO" 2>&1)"
}

# run_core <args...> — invoke setup_core_main directly, the way the update
# machinery does (subshell, hook registry initialized, explicit dirs).
run_core() {
    REPLY_OUT="$(env HOME="$H" zsh -c "
        source '$core_dir/helpers.zsh'
        source '$core_dir/setup_core.zsh'
        typeset -ga _dotfiler_registered_hooks
        setup_core_main $*" 2>&1)"
}

# check <desc> <expected-count> <pattern> — count pattern matches in REPLY_OUT.
check() {
    local desc="$1" expect="$2" pattern="$3"
    local got
    got=$(print -r -- "$REPLY_OUT" | grep -cE -- "$pattern")
    if [[ "$got" == "$expect" ]]; then
        (( pass++ ))
    else
        printf 'FAIL  %s\n' "$desc"
        printf '      pattern=%-40s  got=%s  want=%s\n' "$pattern" "$got" "$expect"
        printf '      output: %s\n' "${REPLY_OUT//$'\n'/$'\n      '}"
        (( fail++ ))
    fi
}

# ---------------------------------------------------------------------------
section "unpack path modalities"
make_sandbox .ssh/k1 .ssh/k2 .ssh/k3 .ssh/k4 .ssh/k5 .ssh/k6 .ssh/k7
mkdir -p "$H/.ssh" "$H/Development"

run_setup "$H"                -u "$H/.ssh/k1"
check "absolute path under home"            1 '\.\. Linked'
run_setup "$H"                -u "$H/.dotfiles/.ssh/k2"
check "absolute path under dotfiles"        1 '\.\. Linked'
run_setup "$H/.ssh"           -u k3
check "bare name, cwd inside home"          1 '\.\. Linked'
run_setup "$H/.dotfiles/.ssh" -u k4
check "bare name, cwd inside dotfiles"      1 '\.\. Linked'
run_setup "$H/Development"    -u .ssh/k5
check "home-relative from foreign cwd"      1 '\.\. Linked'
run_setup "$H/.dotfiles"      -u .ssh/k6
check "repo-root-relative"                  1 '\.\. Linked'
run_setup "$H/.dotfiles/.ssh" -U k7
check "force-unpack bare name in repo dir"  1 '\.\. Linked'
run_setup "$H/Development"    -u Development/.ssh/k5
check "cwd reading must not shadow home-relative contract" 1 'not found|not under'

destroy_sandbox

# ---------------------------------------------------------------------------
section "ingest"
make_sandbox .placeholder
mkdir -p "$H/.ssh" "$H/.config/app" "$H/Development"

print -r -- "key" > "$H/.ssh/newkey"
run_setup "$H/.ssh" -i newkey
check "ingest bare name from subdir: copied"  1 'Copying in file .ssh/newkey'
check "ingest bare name from subdir: linked"  1 '\.\. Linked'
if [[ -L "$H/.ssh/newkey" ]]; then
    (( pass++ ))
else
    printf 'FAIL  ingest result is a symlink\n'
    (( fail++ ))
fi

local i; for i in 1 2 3; do print -r -- "f$i" > "$H/.config/app/f$i"; done
# Three positionals after one flag — the same argv a user's `-i .config/app/*`
# glob expansion produces.
run_setup "$H" -i .config/app/f1 .config/app/f2 .config/app/f3
check "ingest multiple files (glob expansion)" 3 'Copying in file'

print -r -- "abs" > "$H/.abs_file"
run_setup "$H/Development" -i "$H/.abs_file"
check "ingest absolute path from foreign cwd" 1 'Copying in file .abs_file'

destroy_sandbox

# ---------------------------------------------------------------------------
section "track / untrack file lists"
make_sandbox .placeholder
print -r -- "a" > "$H/.g1"; print -r -- "b" > "$H/.g2"

run_setup "$H" -t .g1 .g2
check "track two positional files"          2 'Copying in file'
run_setup "$H" -t .g1 -t .g2
check "legacy repeated-flag form still works" 2 'Copying in file'
run_setup "$H" -x .g1 .g2
check "untrack two positional files"        2 'Untracking file'

destroy_sandbox

# ---------------------------------------------------------------------------
section "guards: mutual exclusion and arity"
make_sandbox .a .b
print -r -- "x" > "$H/.g1"

run_setup "$H" -t .g1 -u .a
check "-t and -u together rejected"         1 'mutually exclusive'
run_setup "$H" -u .a -U .b
check "-u and -U together rejected"         1 'mutually exclusive'
run_setup "$H" -u .a -U .b
check "no force-everything escalation"      0 'Force linking all files'
run_setup "$H" -i
check "bare -i rejected (arity)"            1 'requires at least one'
run_setup "$H" -t
check "bare -t rejected (arity)"            1 'requires at least one'
run_setup "$H" -s .g1
check "-s with files rejected (arity)"      1 'takes no file'

destroy_sandbox

# ---------------------------------------------------------------------------
section "diff (-d): read-only state report"
make_sandbox .linked .missing .identical .divergent .config/app/c1
# .linked    — proper symlink into the repo
ln -s "$DOTREPO/.linked" "$H/.linked"
# .identical — same content, not a symlink
print -r -- "content-.identical" > "$H/.identical"
# .divergent — different content
print -r -- "local edit" > "$H/.divergent"
# .missing   — no counterpart in home

run_setup "$H" -d
check "diff reports the missing file"       1 '\.missing: not present'
check "diff reports identical-unlinked"     1 '\.identical: identical content'
check "diff reports divergent content"      1 '\.divergent: content differs'
check "diff shows a unified diff"           1 '^\+content-\.divergent'
check "diff summary line"                   1 'diff: 1 linked, 1 identical \(unlinked\), 2 missing, 1 differing, 0 conflicting'
check "diff made no installations"          0 '\.\. Linked|Copied'
if [[ ! -e "$H/.missing" && ! -L "$H/.identical" ]]; then
    (( pass++ ))
else
    printf 'FAIL  diff must not modify the filesystem\n'
    (( fail++ ))
fi

run_setup "$H" -d .divergent
check "diff of a named file"                1 '\.divergent: content differs'
run_setup "$H" -d .config/app
check "diff of a named directory sweeps it" 1 'c1: not present'
run_setup "$H" -d .nonexistent
check "diff of unknown file warns"          1 'not found in dotfiles'

destroy_sandbox

# ---------------------------------------------------------------------------
section "bare unpack = everything"
make_sandbox .a .b

run_setup "$H" -u
check "bare -u links all files"             1 'Linking all files'

destroy_sandbox

# ---------------------------------------------------------------------------
section "update-cycle invocation shapes (setup_core_main direct)"
# These mirror the _setup_args arrays built by update.zsh's
# _update_main_unpack and zdot's update-impl: one -u/-U flag, passthrough
# flags, explicit --repo-dir/--link-dest/--excludes, positional file list.
make_sandbox .a .b .config/app/c1
: > "$DOTREPO/dotfiles_exclude"

run_core -u -y --repo-dir "$DOTREPO" --link-dest "$H" \
    --excludes "$DOTREPO/dotfiles_exclude" .a .b
check "update shape: -u with file list"     2 '\.\. Linked'

run_core -U -y --repo-dir "$DOTREPO" --link-dest "$H" \
    --excludes "$DOTREPO/dotfiles_exclude" .config/app/c1
check "update shape: -U with file (force path)" 1 '\.\. Linked|\.\. ok'

run_core -u -y --repo-dir "$DOTREPO" --link-dest "$H" \
    --excludes "$DOTREPO/dotfiles_exclude"
check "update shape: bare -u full unpack"   1 'Linking all files'

destroy_sandbox

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' $pass $fail
(( fail == 0 ))
