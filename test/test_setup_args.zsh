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
section "answer flags and prompting without a terminal"
# run_core_notty <args...> — run_core with no controlling terminal (setsid),
# the way agents, CI and cron invoke it: /dev/tty can't be opened.
run_core_notty() {
    REPLY_OUT="$(env HOME="$H" perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' zsh -c "
        source '$core_dir/helpers.zsh'
        source '$core_dir/setup_core.zsh'
        typeset -ga _dotfiler_registered_hooks
        setup_core_main $*" </dev/null 2>&1)"
}
make_sandbox .a
print new > "$H/.y1"; print new > "$H/.y2"; print new > "$H/.y3"
print new > "$H/.n1"; print new > "$H/.p1"

run_core_notty -i --yes --repo-dir "$DOTREPO" --link-dest "$H" "$H/.y1"
check "--yes long form answers yes"         1 '\.\. Copied'
run_core_notty -i -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.y2"
check "-y short form answers yes"           1 '\.\. Copied'
run_core_notty -i --repo-dir "$DOTREPO" --link-dest "$H" "$H/.y3" --yes
check "--yes after the file list"           1 '\.\. Copied'
run_core_notty -i --no --repo-dir "$DOTREPO" --link-dest "$H" "$H/.n1"
check "--no long form answers no"           0 '\.\. Copied|No terminal'
check "declined track: no stray git add"     0 'pathspec|could not open directory'
check "declined ingest: not linked"         0 'File not found in dotfiles|Linking'
check "declined ingest: says so"            1 'Not tracking'
if [[ ! -L "$H/.n1" && ! -L "$H/.a" ]]; then
    (( ++pass ))
else
    printf 'FAIL  declined ingest left home untouched\n'; (( ++fail ))
fi
run_core_notty -i -D --repo-dir "$DOTREPO" --link-dest "$H" "$H/.n1"
check "dry-run ingest: reports the copy"    1 'DRY RUN\] Would copy'
check "dry-run ingest: not declined"        0 'Not tracking|No terminal'
# -s walks every dotfile in home; declining each must neither abort the run
# nor leak loop-scoped `local` re-declarations (`name=value`) into output.
run_core_notty -s --no --repo-dir "$DOTREPO" --link-dest "$H"
check "setup -s declined: keeps going"      2 'Not tracking'
check "setup -s declined: no local leaks"   0 '^[_a-z]+=[^ ]*$'
check "setup -s skips the repo itself"     0 '\.dotfiles/\.dotfiles|Source [^ ]*/\.dotfiles is already'
run_core_notty -i --repo-dir "$DOTREPO" --link-dest "$H" "$H/.p1"
check "no terminal: prompt says so"         1 'No terminal to ask'
check "no terminal: no zsh read error"      0 "can't open terminal"
check "no terminal: defaults to no"         0 '\.\. Copied'

destroy_sandbox

# ---------------------------------------------------------------------------
section "setup -s: a prefix-sibling of the repo is an ordinary dotfile"
# ~/.dotfiles.bak shares the repo's path as a string prefix but is not inside
# it; it must be offered for tracking like any dotfile, never skipped as
# "already in dotfiles" and then linked from a repo path that doesn't exist.
make_sandbox .a
mkdir -p "$H/.dotfiles.bak"; print old > "$H/.dotfiles.bak/x"
run_core_notty -s --no --repo-dir "$DOTREPO" --link-dest "$H"
check "sibling not mistaken for the repo"    0 'already in dotfiles directory'
check "sibling offered (declined)"           1 'Not tracking [^ ]*/\.dotfiles\.bak'
check "declined sibling: no link attempt"    0 'Linked [^ ]*\.dotfiles\.bak|File exists|Refused link'
if [[ -d "$H/.dotfiles.bak" && ! -L "$H/.dotfiles.bak" && ! -e "$DOTREPO/.dotfiles.bak" ]]; then
    (( ++pass ))
else
    printf 'FAIL  declined sibling: home and repo untouched\n'; (( ++fail ))
fi
run_core_notty -s --yes --repo-dir "$DOTREPO" --link-dest "$H"
check "accepted sibling: copied in"          1 'Copied [^ ]*/\.dotfiles\.bak to '
check "accepted sibling: no bogus link"      0 'File exists|Refused link|Failed to link'
destroy_sandbox

# ---------------------------------------------------------------------------
section "link_if_needed / dolink report failure instead of claiming success"
# run_core_fn <code> — source the core, init for the sandbox, run <code>,
# then print rc=<status> so the exit status is checkable in REPLY_OUT.
run_core_fn() {
    REPLY_OUT="$(env HOME="$H" zsh -c "
        source '$core_dir/helpers.zsh'
        source '$core_dir/setup_core.zsh'
        typeset -ga _dotfiler_registered_hooks
        _setup_init '$DOTREPO' '$H' 0 0 0 0
        $1
        print rc=\$?" 2>&1)"
}
make_sandbox .a
run_core_fn "link_if_needed '$DOTREPO/.nope'"
check "missing src: refused"                 1 'Refused link of [^ ]*/\.nope to [^ ]*, not in the dotfiles directory'
check "missing src: fails"                   1 '^rc=1$'
check "missing src: never says Linked"       0 'Linked'
[[ ! -e "$H/.nope" && ! -L "$H/.nope" ]] && (( ++pass )) || { printf 'FAIL  missing src: no link created\n'; (( ++fail )); }
# dolink links INTO dest's directory under src's own name (ln -s src dir/),
# so an occupied dest means a real file of that name already there.
print keep > "$H/.a"
run_core_fn "dolink '$DOTREPO/.a' '$H/.a'"
check "occupied dest: dolink reports failure" 1 'Failed to link [^ ]*/\.a to [^ ]*/\.a'
check "occupied dest: dolink fails"          1 '^rc=1$'
check "occupied dest: never says Linked"     0 'Linked'
[[ "$(<"$H/.a")" == keep && ! -L "$H/.a" ]] && (( ++pass )) || { printf 'FAIL  occupied dest: file untouched\n'; (( ++fail )); }
rm -f "$H/.a"
run_core_fn "link_if_needed '$DOTREPO/.a'"
check "normal link still works"             1 'Linked [^ ]*/\.a to '
check "normal link: rc 0"                    1 '^rc=0$'
[[ -L "$H/.a" ]] && (( ++pass )) || { printf 'FAIL  normal link created\n'; (( ++fail )); }
destroy_sandbox

# ---------------------------------------------------------------------------
section "untrack (-x) removes the home link, and only ours"
# untrack_if_needed used to resolve the home path with :A, turning the link
# into the repo file, so it never unlinked: git rm then left home dangling.
is_link_to() { [[ -L "$1" && "$(readlink "$1")" == "$2" ]] }
make_sandbox .a .b .c .config/app/c1 .config/app/c2
run_core -u -y --repo-dir "$DOTREPO" --link-dest "$H"
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.a"
check "file: link removed"                   1 'Removed symlink [^ ]*/\.a($|[^[:alnum:]._/-])'
if [[ ! -e "$H/.a" && ! -L "$H/.a" && ! -e "$DOTREPO/.a" ]]; then
    (( ++pass ))
else
    printf 'FAIL  file: home and repo both gone, nothing dangling\n'; (( ++fail ))
fi
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.config/app"
check "dir: per-file links removed"          2 'Removed symlink [^ ]*/\.config/app/c[12]($|[^[:alnum:]._/-])'
if [[ ! -L "$H/.config/app/c1" && ! -L "$H/.config/app/c2" ]]; then
    (( ++pass ))
else
    printf 'FAIL  dir: no dangling links left\n'; (( ++fail ))
fi
# not ours: a real file, and a link pointing somewhere else
rm -f "$H/.b"; print mine > "$H/.b"
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.b"
check "real file: left with a warning"       1 'exists but is not a symlink; leaving it'
if [[ "$(<"$H/.b")" == mine && ! -L "$H/.b" ]]; then
    (( ++pass ))
else
    printf 'FAIL  real file: untouched\n'; (( ++fail ))
fi
rm -f "$H/.c"; print o > "$H/other"; ln -s "$H/other" "$H/.c"
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.c"
check "foreign link: left with a warning"    1 'points elsewhere'
if is_link_to "$H/.c" "$H/other"; then
    (( ++pass ))
else
    printf 'FAIL  foreign link: untouched\n'; (( ++fail ))
fi
destroy_sandbox

make_sandbox .a
run_core -u -y --repo-dir "$DOTREPO" --link-dest "$H"
run_core_notty -x -y -D --repo-dir "$DOTREPO" --link-dest "$H" "$H/.a"
check "dry run: reports the unlink"          1 'DRY RUN\] Would remove: [^ ]*/\.a'
if is_link_to "$H/.a" "$DOTREPO/.a" && [[ -e "$DOTREPO/.a" ]]; then
    (( ++pass ))
else
    printf 'FAIL  dry run: link and repo file untouched\n'; (( ++fail ))
fi
destroy_sandbox

# -x takes the same spellings as -u: where the file lands OR where it lives
# in the repo, absolute or cwd-relative; excluded repo paths are refused.
make_sandbox .a .b .c .config/app/c1 .nounpack/tool
run_core -u -y --repo-dir "$DOTREPO" --link-dest "$H"
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$DOTREPO/.a"
check "repo path (absolute): untracked"      1 'Removed symlink [^ ]*/\.a($|[^[:alnum:]._/-])'
if [[ ! -L "$H/.a" ]]; then
    (( ++pass ))
else
    printf 'FAIL  repo path (absolute): home link gone\n'; (( ++fail ))
fi
cd "$DOTREPO"
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" .b
cd - >/dev/null
check "repo path (cwd in repo): untracked"   1 'Removed symlink [^ ]*/\.b($|[^[:alnum:]._/-])'
if [[ ! -L "$H/.b" ]]; then
    (( ++pass ))
else
    printf 'FAIL  repo path (cwd in repo): home link gone\n'; (( ++fail ))
fi
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$DOTREPO/.config/app"
check "repo dir path: per-file links gone"   1 'Removed symlink [^ ]*/\.config/app/c1($|[^[:alnum:]._/-])'
mkdir -p "$H/Development"; cd "$H/Development"
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" .c
cd - >/dev/null
check "home-relative from outside: untracked" 1 'Removed symlink [^ ]*/\.c($|[^[:alnum:]._/-])'
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$DOTREPO/.nounpack/tool"
check "excluded repo path: refused"          1 'Refused to untrack \.nounpack/tool: excluded from unpacking'
check "excluded repo path: not git rm'd"     0 'Removed [^ ]*\.nounpack'
if [[ -f "$DOTREPO/.nounpack/tool" ]] && git -C "$DOTREPO" ls-files --error-unmatch .nounpack/tool >/dev/null 2>&1; then
    (( ++pass ))
else
    printf 'FAIL  excluded repo path: still in repo and tracked\n'; (( ++fail ))
fi
destroy_sandbox

# git rm refusing one file (staged-but-uncommitted changes) must not cost it
# its link, must not stop the other files, and must fail the run overall.
make_sandbox .a
run_core -u -y --repo-dir "$DOTREPO" --link-dest "$H"
print new > "$DOTREPO/.n"; git -C "$DOTREPO" add .n; ln -s "$DOTREPO/.n" "$H/.n"
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.n" "$H/.a"
check "staged: git rm failure reported"      1 'git rm failed for \.n; home links left in place'
check "staged: other files still processed"  1 'Removed symlink [^ ]*/\.a($|[^[:alnum:]._/-])'
check "staged: run fails, naming the file"   1 'Could not untrack: \.n($|[^[:alnum:]._/-])'
if is_link_to "$H/.n" "$DOTREPO/.n" && [[ -e "$H/.n" ]]; then
    (( ++pass ))
else
    printf 'FAIL  staged: home keeps its working link\n'; (( ++fail ))
fi
if [[ ! -L "$H/.a" ]]; then
    (( ++pass ))
else
    printf 'FAIL  staged: the other file was unlinked\n'; (( ++fail ))
fi
destroy_sandbox

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' $pass $fail
(( fail == 0 ))
