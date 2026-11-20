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
# a directory, so ingested file by file
check "accepted sibling: copied in"          1 'Copied [^ ]*/\.dotfiles\.bak/x to '
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
section "untrack-delete (-X) removes the home link, and only ours"
# -X: untrack AND delete (what -x did before it learned to keep a copy).
# untrack_if_needed used to resolve the home path with :A, turning the link
# into the repo file, so it never unlinked: git rm then left home dangling.
is_link_to() { [[ -L "$1" && "$(readlink "$1")" == "$2" ]] }
make_sandbox .a .b .c .config/app/c1 .config/app/c2
run_core -u -y --repo-dir "$DOTREPO" --link-dest "$H"
run_core_notty -X -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.a"
check "file: link removed"                   1 'Removed symlink [^ ]*/\.a($|[^[:alnum:]._/-])'
if [[ ! -e "$H/.a" && ! -L "$H/.a" && ! -e "$DOTREPO/.a" ]]; then
    (( ++pass ))
else
    printf 'FAIL  file: home and repo both gone, nothing dangling\n'; (( ++fail ))
fi
run_core_notty -X -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.config/app"
check "dir: per-file links removed"          2 'Removed symlink [^ ]*/\.config/app/c[12]($|[^[:alnum:]._/-])'
if [[ ! -L "$H/.config/app/c1" && ! -L "$H/.config/app/c2" ]]; then
    (( ++pass ))
else
    printf 'FAIL  dir: no dangling links left\n'; (( ++fail ))
fi
# not ours: a real file, and a link pointing somewhere else
rm -f "$H/.b"; print mine > "$H/.b"
run_core_notty -X -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.b"
check "real file: left with a warning"       1 'exists but is not a symlink; leaving it'
if [[ "$(<"$H/.b")" == mine && ! -L "$H/.b" ]]; then
    (( ++pass ))
else
    printf 'FAIL  real file: untouched\n'; (( ++fail ))
fi
rm -f "$H/.c"; print o > "$H/other"; ln -s "$H/other" "$H/.c"
run_core_notty -X -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.c"
check "foreign link: left with a warning"    1 'points elsewhere'
if is_link_to "$H/.c" "$H/other"; then
    (( ++pass ))
else
    printf 'FAIL  foreign link: untouched\n'; (( ++fail ))
fi
destroy_sandbox

make_sandbox .a
run_core -u -y --repo-dir "$DOTREPO" --link-dest "$H"
run_core_notty -X -y -D --repo-dir "$DOTREPO" --link-dest "$H" "$H/.a"
check "dry run: reports the unlink"          1 'DRY RUN\] Would remove: [^ ]*/\.a'
if is_link_to "$H/.a" "$DOTREPO/.a" && [[ -e "$DOTREPO/.a" ]]; then
    (( ++pass ))
else
    printf 'FAIL  dry run: link and repo file untouched\n'; (( ++fail ))
fi
destroy_sandbox

# -x/-X take the same spellings as -u: where the file lands OR where it lives
# in the repo, absolute or cwd-relative; excluded repo paths are refused.
make_sandbox .a .b .c .config/app/c1 .nounpack/tool
run_core -u -y --repo-dir "$DOTREPO" --link-dest "$H"
run_core_notty -X -y --repo-dir "$DOTREPO" --link-dest "$H" "$DOTREPO/.a"
check "repo path (absolute): untracked"      1 'Removed symlink [^ ]*/\.a($|[^[:alnum:]._/-])'
if [[ ! -L "$H/.a" ]]; then
    (( ++pass ))
else
    printf 'FAIL  repo path (absolute): home link gone\n'; (( ++fail ))
fi
cd "$DOTREPO"
run_core_notty -X -y --repo-dir "$DOTREPO" --link-dest "$H" .b
cd - >/dev/null
check "repo path (cwd in repo): untracked"   1 'Removed symlink [^ ]*/\.b($|[^[:alnum:]._/-])'
if [[ ! -L "$H/.b" ]]; then
    (( ++pass ))
else
    printf 'FAIL  repo path (cwd in repo): home link gone\n'; (( ++fail ))
fi
run_core_notty -X -y --repo-dir "$DOTREPO" --link-dest "$H" "$DOTREPO/.config/app"
check "repo dir path: per-file links gone"   1 'Removed symlink [^ ]*/\.config/app/c1($|[^[:alnum:]._/-])'
mkdir -p "$H/Development"; cd "$H/Development"
run_core_notty -X -y --repo-dir "$DOTREPO" --link-dest "$H" .c
cd - >/dev/null
check "home-relative from outside: untracked" 1 'Removed symlink [^ ]*/\.c($|[^[:alnum:]._/-])'
run_core_notty -X -y --repo-dir "$DOTREPO" --link-dest "$H" "$DOTREPO/.nounpack/tool"
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
run_core_notty -X -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.n" "$H/.a"
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
# ---------------------------------------------------------------------------
section "untrack (-x) keeps the file in home as a real copy"
is_real_copy() { [[ -f "$1" && ! -L "$1" && "$(<"$1")" == "$2" ]] }
untracked() { ! git -C "$DOTREPO" ls-files --error-unmatch "$1" >/dev/null 2>&1 }
make_sandbox .a .b .r .config/app/c1 .config/app/c2 .whole/w1
run_core -u -y --repo-dir "$DOTREPO" --link-dest "$H"
rm -rf "$H/.whole"; ln -s "$DOTREPO/.whole" "$H/.whole"   # a dir linked as a whole
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.a"
check "keep file: says so"                   1 'Kept [^ ]*/\.a as a real copy'
if is_real_copy "$H/.a" content-.a && [[ ! -e "$DOTREPO/.a" ]] && untracked .a; then
    (( ++pass ))
else
    printf 'FAIL  keep file: real copy in home, gone from repo and git\n'; (( ++fail ))
fi
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.config/app"
if is_real_copy "$H/.config/app/c1" content-.config/app/c1 \
   && is_real_copy "$H/.config/app/c2" content-.config/app/c2 \
   && [[ ! -e "$DOTREPO/.config/app" ]] && untracked .config/app/c1; then
    (( ++pass ))
else
    printf 'FAIL  keep dir (per-file links): real copies, gone from repo\n'; (( ++fail ))
fi
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.whole"
if [[ -d "$H/.whole" && ! -L "$H/.whole" ]] && is_real_copy "$H/.whole/w1" content-.whole/w1 \
   && [[ ! -e "$DOTREPO/.whole" ]]; then
    (( ++pass ))
else
    printf 'FAIL  keep dir (linked whole): real directory copy\n'; (( ++fail ))
fi
rm -f "$H/.b"                                       # nothing in home at all
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.b"
if is_real_copy "$H/.b" content-.b && [[ ! -e "$DOTREPO/.b" ]]; then
    (( ++pass ))
else
    printf 'FAIL  keep: missing home path restored from the repo\n'; (( ++fail ))
fi
rm -f "$H/.r"; print mine > "$H/.r"                 # a real file of the user's own
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.r"
check "keep: real home file left, warned"     1 'exists but is not a symlink; leaving it'
if is_real_copy "$H/.r" mine; then
    (( ++pass ))
else
    printf 'FAIL  keep: real home file untouched\n'; (( ++fail ))
fi
destroy_sandbox

make_sandbox .a
run_core -u -y --repo-dir "$DOTREPO" --link-dest "$H"
run_core_notty -x -y -D --repo-dir "$DOTREPO" --link-dest "$H" "$H/.a"
check "keep dry run: reports the copy"        1 'DRY RUN\] Would copy: [^ ]*/\.a'
if is_link_to "$H/.a" "$DOTREPO/.a" && [[ -e "$DOTREPO/.a" ]] && ! untracked .a; then
    (( ++pass ))
else
    printf 'FAIL  keep dry run: nothing changed\n'; (( ++fail ))
fi
destroy_sandbox

# staged-but-uncommitted: git rm --cached accepts it, so -x keeps it safely
make_sandbox .a
print new > "$DOTREPO/.n"; git -C "$DOTREPO" add .n; ln -s "$DOTREPO/.n" "$H/.n"
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.n"
check "keep staged: no failure"               0 'git rm failed|Could not untrack'
if is_real_copy "$H/.n" new && [[ ! -e "$DOTREPO/.n" ]] && untracked .n; then
    (( ++pass ))
else
    printf 'FAIL  keep staged: real copy in home, untracked\n'; (( ++fail ))
fi
run_core -x -X -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.a"
check "-x and -X are mutually exclusive"      1 'mutually exclusive'
destroy_sandbox

# A symlink committed in the repo is handled as itself: keep must never act
# on (let alone delete) what it points at.
make_sandbox .a
print precious > "$H/outside.txt"; ln -s "$H/outside.txt" "$DOTREPO/.lnk"
git -C "$DOTREPO" add .lnk; git -C "$DOTREPO" -c user.email=t@t -c user.name=t commit -qm lnk
ln -s "$DOTREPO/.lnk" "$H/.lnk"
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.lnk"
if [[ "$(<"$H/outside.txt")" == precious ]] && is_link_to "$H/.lnk" "$H/outside.txt" \
   && [[ ! -e "$DOTREPO/.lnk" && ! -L "$DOTREPO/.lnk" ]]; then
    (( ++pass ))
else
    printf 'FAIL  keep committed symlink: target untouched, link copied to home\n'; (( ++fail ))
fi
destroy_sandbox

# Uncommitted edits in the repo are never lost: -x deletes a repo working
# copy only when it was copied home or matches HEAD; -X relies on git rm,
# which refuses a file with local modifications.
make_sandbox .e .l .u
print "UNCOMMITTED E" > "$DOTREPO/.e"; print "home's own" > "$H/.e"   # real home file
print "UNCOMMITTED L" > "$DOTREPO/.l"; ln -s "$DOTREPO/.l" "$H/.l"      # linked home
print "home's own" > "$H/.u"                                           # unedited, real home
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.e" "$H/.l" "$H/.u"
check "keep: unsafe repo copy kept, warned"  1 '\.e has changes git history doesn.t have'
if is_real_copy "$DOTREPO/.e" "UNCOMMITTED E" && is_real_copy "$H/.e" "home's own" && untracked .e; then
    (( ++pass ))
else
    printf 'FAIL  keep: uncommitted edit stays in repo (untracked), home untouched\n'; (( ++fail ))
fi
if is_real_copy "$H/.l" "UNCOMMITTED L" && [[ ! -e "$DOTREPO/.l" ]]; then
    (( ++pass ))
else
    printf 'FAIL  keep: linked file with an edit lands in home, repo copy removed\n'; (( ++fail ))
fi
check "keep: committed copy removed silently" 0 '\.u has changes'
if [[ ! -e "$DOTREPO/.u" ]] && is_real_copy "$H/.u" "home's own"; then
    (( ++pass ))
else
    printf 'FAIL  keep: repo copy matching HEAD removed, home untouched\n'; (( ++fail ))
fi
destroy_sandbox
make_sandbox .e
print "UNCOMMITTED E" > "$DOTREPO/.e"; ln -s "$DOTREPO/.e" "$H/.e"
run_core_notty -X -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.e"
check "delete: git rm refuses local edits"   1 'git rm failed for \.e'
if is_real_copy "$DOTREPO/.e" "UNCOMMITTED E" && is_link_to "$H/.e" "$DOTREPO/.e"; then
    (( ++pass ))
else
    printf 'FAIL  delete: uncommitted edit and home link untouched\n'; (( ++fail ))
fi
destroy_sandbox

# Directories linked as a whole. A file seen through such a link IS the repo
# file, so untracking it alone is refused (else it would vanish from home);
# untracking the parent turns a linked subdirectory into a real one (keep)
# or removes its link (delete). Filenames with spaces included.
mk_linked_dirs() {
    make_sandbox .config/app/conf .config/top .foo/bar ".sp/a file"
    mkdir -p "$H/.config" "$H/.sp"
    ln -s "$DOTREPO/.config/app" "$H/.config/app"; ln -s "$DOTREPO/.config/top" "$H/.config/top"
    ln -s "$DOTREPO/.foo" "$H/.foo"; ln -s "$DOTREPO/.sp/a file" "$H/.sp/a file"
}
mk_linked_dirs
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.foo/bar"
check "inside a linked dir: refused"         1 'Refused to untrack \.foo/bar: it is inside a directory linked'
if [[ "$(<"$H/.foo/bar")" == content-.foo/bar ]] && ! untracked .foo/bar; then
    (( ++pass ))
else
    printf 'FAIL  inside a linked dir: file still there and tracked\n'; (( ++fail ))
fi
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.config"
if [[ -d "$H/.config/app" && ! -L "$H/.config/app" ]] && is_real_copy "$H/.config/app/conf" content-.config/app/conf \
   && is_real_copy "$H/.config/top" content-.config/top && [[ ! -e "$DOTREPO/.config" ]]; then
    (( ++pass ))
else
    printf 'FAIL  keep: linked subdir becomes a real dir, repo dirs left empty removed\n'; (( ++fail ))
fi
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.sp"
if is_real_copy "$H/.sp/a file" "content-.sp/a file"; then
    (( ++pass ))
else
    printf 'FAIL  keep: filename with a space\n'; (( ++fail ))
fi
destroy_sandbox
mk_linked_dirs
run_core_notty -X -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.config"
check "delete: linked subdir link removed"   1 'Removed symlink [^ ]*/\.config/app($|[^[:alnum:]._/-])'
if [[ ! -e "$H/.config/app" && ! -L "$H/.config/app" && ! -L "$H/.config/top" ]]; then
    (( ++pass ))
else
    printf 'FAIL  delete: nothing dangling under a linked subdir\n'; (( ++fail ))
fi
destroy_sandbox

# a RELATIVE committed symlink keeps pointing at the same file from home
make_sandbox .a .conf/real
ln -s real "$DOTREPO/.conf/alias"
git -C "$DOTREPO" add .conf/alias; git -C "$DOTREPO" -c user.email=t@t -c user.name=t commit -qm rel
mkdir -p "$H/.conf"; ln -s "$DOTREPO/.conf/alias" "$H/.conf/alias"
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.conf/alias"
if is_link_to "$H/.conf/alias" "$DOTREPO/.conf/real" && [[ "$(<"$H/.conf/alias")" == content-.conf/real \
   && -f "$DOTREPO/.conf/real" ]]; then
    (( ++pass ))
else
    printf 'FAIL  keep relative symlink: same target from home, target untouched\n'; (( ++fail ))
fi
destroy_sandbox

# Only tracked files are untracked: an ignored file in the same directory
# stays in the repo and is not copied into home.
make_sandbox .app/conf
print local-secret > "$DOTREPO/.app/.gitignore"
git -C "$DOTREPO" add .app/.gitignore; git -C "$DOTREPO" -c user.email=t@t -c user.name=t commit -qm ign
print secret > "$DOTREPO/.app/local-secret"
mkdir -p "$H/.app"
ln -s "$DOTREPO/.app/conf" "$H/.app/conf"; ln -s "$DOTREPO/.app/.gitignore" "$H/.app/.gitignore"
run_core_notty -x -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.app"
if [[ "$(<"$DOTREPO/.app/local-secret")" == secret && ! -e "$H/.app/local-secret" ]] \
   && is_real_copy "$H/.app/conf" content-.app/conf && [[ ! -e "$DOTREPO/.app/conf" ]]; then
    (( ++pass ))
else
    printf 'FAIL  keep dir: ignored file stays in repo, not copied home\n'; (( ++fail ))
fi
run_core_notty -X -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.app" 2>/dev/null
check "untracked path: refused"              1 '\.app is not tracked in the dotfiles repo'
destroy_sandbox

section "setup -s: directories are ingested file by file, one prompt each"
# -s used to cp -r a top-level dir INTO <repo>/<dir> (nesting it) and never
# link it; with the dir already in the repo, a src/* glob both skipped
# dotfiles and broke safe_cp_r's two-argument call while claiming success.
mk_cfg() {
    mkdir -p "$H/.cfg/app" "$H/.cfg/node_modules/m"
    print main > "$H/.cfg/app/conf"; print hidden > "$H/.cfg/.hidden"; print top > "$H/.cfg/top"
    print junk > "$H/.cfg/node_modules/m/x.js"; print bak > "$H/.cfg/old.bak"
    print other > "$H/elsewhere"; ln -s "$H/elsewhere" "$H/.cfg/foreign"
}
cfg_linked() {  # every expected file is a link into the repo with home's content
    local f
    for f in .cfg/app/conf .cfg/.hidden .cfg/top; do
        [[ -L "$H/$f" && "$(readlink "$H/$f")" == "$DOTREPO/$f" && -f "$DOTREPO/$f" ]] || return 1
    done
}
make_sandbox .a
mk_cfg
run_core_notty -s --repo-dir "$DOTREPO" --link-dest "$H"
check "dir: asked once for the whole directory" 1 'Track 3 new file\(s\) under [^ ]*/\.cfg'
check "dir: declined says so"                1 'Not tracking [^ ]*/\.cfg'
if [[ ! -e "$DOTREPO/.cfg" && ! -L "$H/.cfg/top" ]]; then
    (( ++pass ))
else
    printf 'FAIL  dir declined: nothing tracked or linked\n'; (( ++fail ))
fi
run_core_notty -s --yes --repo-dir "$DOTREPO" --link-dest "$H"
if cfg_linked && [[ ! -e "$DOTREPO/.cfg/.cfg" ]]; then
    (( ++pass ))
else
    printf 'FAIL  dir accepted: copied without nesting and linked per file\n'; (( ++fail ))
fi
if [[ ! -e "$DOTREPO/.cfg/node_modules" && ! -e "$DOTREPO/.cfg/old.bak" && ! -L "$H/.cfg/old.bak" ]]; then
    (( ++pass ))
else
    printf 'FAIL  dir: excluded files neither copied nor linked\n'; (( ++fail ))
fi
check "dir: foreign symlink reported"        1 'Skipping symlink [^ ]*/\.cfg/foreign'
if [[ "$(readlink "$H/.cfg/foreign")" == "$H/elsewhere" && ! -e "$DOTREPO/.cfg/foreign" ]]; then
    (( ++pass ))
else
    printf 'FAIL  dir: foreign symlink left alone\n'; (( ++fail ))
fi
check "dir: no second prompt for identical files" 0 'identical, replace with link'
# run again: everything is already linked, so there is nothing to ask
run_core_notty -s --repo-dir "$DOTREPO" --link-dest "$H"
check "dir re-run: no prompt"                0 'Track [0-9]+ new file'
check "dir re-run: nothing to track"         1 'nothing to track under [^ ]*/\.cfg'
destroy_sandbox

# directory already in the repo, home differs: merged per file, dotfiles
# included, then linked
make_sandbox .a .cfg/app/conf
print old > "$DOTREPO/.cfg/app/conf"; git -C "$DOTREPO" -c user.email=t@t -c user.name=t commit -qam old
mk_cfg
# unanswered first: the prompt text is only printed when actually asked
run_core_notty -s --repo-dir "$DOTREPO" --link-dest "$H"
check "dir in repo: only the new files counted" 1 'Track 2 new file\(s\)'
run_core_notty -s --yes --repo-dir "$DOTREPO" --link-dest "$H"
if cfg_linked && [[ "$(<"$DOTREPO/.cfg/app/conf")" == main ]]; then
    (( ++pass ))
else
    printf 'FAIL  dir in repo: differing file updated, all linked\n'; (( ++fail ))
fi
destroy_sandbox

# -t of a directory goes through copy_in_if_needed's directory branches
make_sandbox .a
mk_cfg
run_core_notty -t -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.cfg"
if [[ -f "$DOTREPO/.cfg/app/conf" && -f "$DOTREPO/.cfg/.hidden" && ! -e "$DOTREPO/.cfg/.cfg" ]]; then
    (( ++pass ))
else
    printf 'FAIL  -t dir: copied in without nesting\n'; (( ++fail ))
fi
print newer > "$H/.cfg/app/conf"; print fresh > "$H/.cfg/.fresh"
run_core_notty -t -y --repo-dir "$DOTREPO" --link-dest "$H" "$H/.cfg"
check "-t dir differs: no copy error"        0 'Not a directory|Failed to update'
if [[ "$(<"$DOTREPO/.cfg/app/conf")" == newer && -f "$DOTREPO/.cfg/.fresh" ]]; then
    (( ++pass ))
else
    printf 'FAIL  -t dir differs: merged, dotfiles included\n'; (( ++fail ))
fi
destroy_sandbox

# Exactly which questions -s asks: prompt_yes_no is replaced by a logger
# that answers yes, except "Update tracked file" (declined, so the DIFFERENT
# link question is reached).
make_sandbox .a .b
print old > "$DOTREPO/.b"; git -C "$DOTREPO" -c user.email=t@t -c user.name=t commit -qam old
print content-.a > "$H/.a"                        # identical to the repo copy
print new > "$H/.b"                               # differs from the repo copy
print one > "$H/.one"; print two > "$H/.two"       # new
mkdir -p "$H/.cfg"; print c > "$H/.cfg/c"; print d > "$H/.cfg/d"
run_core_fn "prompt_yes_no() { print -r -- \"ASKED: \$1\"; [[ \$1 != Update\ tracked\ file* ]] }
setup_core_main -s --repo-dir '$DOTREPO' --link-dest '$H'"
check "top-level new file: one question each" 2 'ASKED: Track [^ ]*/\.(one|two)$'
check "top-level: no identical-replace question" 0 'ASKED: .*identical, replace with link'
check "already tracked + identical: not asked" 0 'ASKED: .*/\.a($|[^[:alnum:]._/-])'
check "differing file: DIFFERENT still asked" 1 'ASKED: .*/\.b exists and is DIFFERENT, replace with link'
check "directory: one question for all"      1 'ASKED: Track 2 new file\(s\) under [^ ]*/\.cfg'
check "questions total"                      5 'ASKED: '
if [[ -L "$H/.one" && -L "$H/.two" && -L "$H/.a" && -L "$H/.cfg/c" ]]; then
    (( ++pass ))
else
    printf 'FAIL  -s prompts: everything agreed to is linked\n'; (( ++fail ))
fi
destroy_sandbox

# dry run: nothing copied, so links are reported, not refused, and every
# new file is reached
make_sandbox .a
print one > "$H/.one"; print two > "$H/.two"
run_core_notty -s -D --repo-dir "$DOTREPO" --link-dest "$H"
check "-s dry run: reports each link"        2 'DRY RUN\] Would link [^ ]*/\.(one|two) to'
check "-s dry run: never refuses"            0 'Refused link'
if [[ ! -e "$DOTREPO/.one" && ! -L "$H/.one" ]]; then
    (( ++pass ))
else
    printf 'FAIL  -s dry run: nothing changed\n'; (( ++fail ))
fi
destroy_sandbox

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' $pass $fail
(( fail == 0 ))
