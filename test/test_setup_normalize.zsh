#!/usr/bin/env zsh
# test_setup_normalize.zsh — unit tests for normalize_path_to_dest_relative:
# the target-detection cases across all three modes (cwd | dest | unpack).
#
# Each check calls the production function directly with controlled globals
# (_setup_link_dest, dotfiles_dir) and a controlled working directory, and
# asserts the produced dest-relative path (or failure).
setopt extendedglob

source "${0:A:h}/../setup_core.zsh"

typeset -i pass=0 fail=0

section() { printf '\n--- %s ---\n' "$1"; }

# Sandbox layout (:A dodges the macOS /tmp symlink — the normalizer
# deliberately does not resolve symlinks in its inputs)
SBX="$(mktemp -d)"; SBX="${SBX:A}"
trap '[[ -n "$SBX" ]] && rm -rf "$SBX"' EXIT INT TERM

H="$SBX/home"
DOT="$H/.dotfiles"
mkdir -p "$H/.ssh" "$H/sub" "$H/Development" \
         "$DOT/.ssh" "$DOT/sub/.ssh" "$DOT/.config/app"
print -r -- "x" > "$H/.exists"
print -r -- "k" > "$DOT/.ssh/key"
print -r -- "c" > "$DOT/.config/app/conf"
print -r -- "shadow" > "$DOT/sub/.ssh/key"   # for the ambiguity case

# Globals the production function reads
typeset -g _setup_link_dest="$H"
typeset -g dotfiles_dir="$DOT"

# norm <cwd> <input> <mode> — run the function from <cwd>; capture output+rc.
typeset -g NORM_OUT="" NORM_RC=0
norm() {
    local _cwd=$1 _input=$2 _mode=$3
    NORM_OUT="$(cd "$_cwd" && normalize_path_to_dest_relative "$_input" "$_mode" 2>/dev/null)"
    NORM_RC=$?
}

# check <desc> <cwd> <input> <mode> <expected | !fail>
check() {
    local desc=$1 cwd=$2 input=$3 mode=$4 expect=$5
    norm "$cwd" "$input" "$mode"
    local ok=0
    if [[ "$expect" == '!fail' ]]; then
        (( NORM_RC != 0 )) && ok=1
    else
        [[ $NORM_RC -eq 0 && "$NORM_OUT" == "$expect" ]] && ok=1
    fi
    if (( ok )); then
        (( pass++ ))
    else
        printf 'FAIL  %s\n      cwd=%s input=%s mode=%s\n      got rc=%s out=%s  want=%s\n' \
            "$desc" "${cwd#$SBX/}" "$input" "$mode" "$NORM_RC" "$NORM_OUT" "$expect"
        (( fail++ ))
    fi
}

# ---------------------------------------------------------------------------
section "cwd mode (ingest/track/untrack semantics)"
check "existing file, bare name, cwd=home"        "$H"      .exists      cwd  .exists
check "nonexistent file resolves against cwd"     "$H/.ssh" newfile      cwd  .ssh/newfile
check "absolute path under home"                  "$H"      "$H/.ssh/k"  cwd  .ssh/k
check "dot-dot traversal normalized"              "$H/sub"  ../.exists   cwd  .exists
check "absolute path outside home fails"          "$H"      /etc/hosts   cwd  '!fail'
check "empty input fails"                         "$H"      ""           cwd  '!fail'

# symlink policy: the input path is NOT symlink-resolved — ingesting a file
# already linked into dotfiles must yield its HOME-side path, not .dotfiles/…
ln -s "$DOT/.ssh/key" "$H/.linked"
check "symlink input keeps its home-side path"    "$H"      .linked      cwd  .linked

# ---------------------------------------------------------------------------
section "dest mode (forced home-relative)"
check "bare name from foreign cwd"                "$SBX"    .zshrc       dest .zshrc
check "nested path from foreign cwd"              "$SBX"    .ssh/key     dest .ssh/key
check "cwd is irrelevant in dest mode"            "$H/sub"  .ssh/key     dest .ssh/key

# ---------------------------------------------------------------------------
section "unpack mode: the four naming modalities"
check "absolute under home"                       "$SBX"    "$H/.ssh/key"   unpack .ssh/key
check "absolute under dotfiles (repo prefix wins)" "$SBX"   "$DOT/.ssh/key" unpack .ssh/key
check "bare name, cwd inside home subdir"         "$H/.ssh" key             unpack .ssh/key
check "bare name, cwd inside dotfiles subdir"     "$DOT/.ssh" key           unpack .ssh/key
check "repo-root-relative from repo root"         "$DOT"    .ssh/key        unpack .ssh/key
check "home-relative from foreign cwd (contract)" "$H/Development" .ssh/key unpack .ssh/key
check "deep repo file, cwd inside repo"           "$DOT/.config/app" conf   unpack .config/app/conf

# ---------------------------------------------------------------------------
section "unpack mode: precedence and fallbacks"
# cwd reading may only beat the home-relative contract when it names a real
# repo file: from ~/sub, '.ssh/key' exists in the repo BOTH as
# sub/.ssh/key (cwd reading) and .ssh/key (contract reading) — cwd wins.
check "cwd reading preferred when both exist"     "$H/sub"  .ssh/key     unpack sub/.ssh/key
# …but with no repo file at the cwd reading, the contract reading wins:
check "contract wins when cwd names nothing real" "$H/Development" .ssh/key unpack .ssh/key
# neither exists, cwd inside the repo → cwd reading (sensible error later)
check "neither exists, cwd in repo: cwd reading"  "$DOT/.ssh" ghost      unpack .ssh/ghost
# neither exists, foreign cwd → contract reading (matches old behavior)
check "neither exists, foreign cwd: contract"     "$SBX"    .ssh/ghost   unpack .ssh/ghost
check "absolute outside home and repo fails"      "$SBX"    /etc/hosts   unpack '!fail'

printf '\n%d passed, %d failed\n' $pass $fail
(( fail == 0 ))
