#!/usr/bin/env zsh
# test_update_states.zsh — repo-state machinery around updates:
#   - dirty detection (_update_core_check_dirty) incl. --exclude paths
#   - the stash round-trip (_update_core_maybe_stash / _update_core_pop_stash):
#     consent cache branches, dry-run, verify-after-stash, pop conflicts,
#     and local modifications surviving an update
#   - availability states (_update_core_is_available_fetch): behind,
#     up-to-date, ahead, diverged with/without allow, fetch failure
#
# Uses test/lib/update_harness.zsh.

source "${0:A:h}/lib/update_harness.zsh"

harness_init

typeset -gi _dry_run=0   # consumed by _update_core_maybe_stash

check_rc() {
    local _desc=$1 _got=$2 _want=$3
    if [[ "$_got" == "$_want" ]]; then
        (( pass++ ))
    else
        printf 'FAIL  %s\n      rc=%s want=%s\n' "$_desc" "$_got" "$_want"
        (( fail++ ))
    fi
}

# ---------------------------------------------------------------------------
section "dirty detection"
fixture_repo dirtyrepo .zshrc="v1" .config/app/conf="c1"
repo="$REPLY"

_update_core_check_dirty "$repo"; check_rc "clean tree" $? 0
print -r -- "edited" > "$repo/.zshrc"
_update_core_check_dirty "$repo"; check_rc "modified tracked file is dirty" $? 1
git -C "$repo" checkout -q -- .zshrc
print -r -- "stray" > "$repo/.untracked"
_update_core_check_dirty "$repo"; check_rc "untracked file is dirty" $? 1
_update_core_check_dirty "$repo" --exclude .untracked
check_rc "excluded path is tolerated" $? 0
rm -f "$repo/.untracked"

# ---------------------------------------------------------------------------
section "stash round-trip across an update"
fixture_origin "$repo"
git clone -q "$REPLY" "$SBX/repos/dirty-peer"
peer="$SBX/repos/dirty-peer"

# local edit to one file; upstream changes a DIFFERENT file (no conflict)
print -r -- "local WIP" > "$repo/.config/app/conf"
fixture_commit "$peer" "upstream" .zshrc="v2"
git -C "$peer" push -q origin main
git -C "$repo" fetch -q origin

_dotfiler_stash_consent[${repo:A}]=y
_update_core_maybe_stash "$repo" "test"; rc=$?
check_rc "maybe_stash proceeds with cached consent" $rc 0
check_rc "a stash was created (REPLY)" $REPLY 1
_update_core_check_dirty "$repo"; check_rc "tree clean after stash" $? 0

git -C "$repo" merge -q --ff-only origin/main
_update_core_pop_stash "$repo" "test"; check_rc "stash pop succeeds" $? 0
if [[ "$(<"$repo/.zshrc")" == "v2" ]]; then (( pass++ )); else printf 'FAIL  upstream change merged under the stash\n'; (( fail++ )); fi
if [[ "$(<"$repo/.config/app/conf")" == "local WIP" ]]; then (( pass++ )); else printf 'FAIL  local WIP restored by pop\n'; (( fail++ )); fi
git -C "$repo" checkout -q -- .   # tidy for later sections

# declined consent: no stash, dirty preserved, abort
print -r -- "more WIP" > "$repo/.config/app/conf"
_dotfiler_stash_consent[${repo:A}]=n
_update_core_maybe_stash "$repo" "test" 2>/dev/null; rc=$?
check_rc "maybe_stash aborts on cached refusal" $rc 1
if [[ -z "$(git -C "$repo" stash list)" ]]; then (( pass++ )); else printf 'FAIL  no stash on refusal\n'; (( fail++ )); fi
if [[ "$(<"$repo/.config/app/conf")" == "more WIP" ]]; then (( pass++ )); else printf 'FAIL  dirty state preserved on refusal\n'; (( fail++ )); fi

# dry-run: never stash, never prompt, proceed reporting clean
_dotfiler_stash_consent=()
_dry_run=1
_update_core_maybe_stash "$repo" "test"; rc=$?
check_rc "dry-run proceeds without stashing" $rc 0
check_rc "dry-run created no stash (REPLY)" $REPLY 0
_update_core_check_dirty "$repo"; check_rc "dry-run leaves the dirt alone" $? 1
_dry_run=0

# pop conflict: upstream and stash touch the SAME file
_dotfiler_stash_consent[${repo:A}]=y
git -C "$repo" checkout -q -- .
print -r -- "conflicting WIP" > "$repo/.zshrc"
fixture_commit "$peer" "upstream again" .zshrc="v3"
git -C "$peer" push -q origin main
git -C "$repo" fetch -q origin
_update_core_maybe_stash "$repo" "test"
git -C "$repo" merge -q --ff-only origin/main
_update_core_pop_stash "$repo" "test" 2>/dev/null; rc=$?
check_rc "conflicting pop reports failure for manual resolution" $rc 1
git -C "$repo" checkout -q -- . 2>/dev/null
git -C "$repo" stash drop -q 2>/dev/null

# ---------------------------------------------------------------------------
section "availability states (is_available_fetch)"
fixture_repo staterepo .file="base"
state="$REPLY"
fixture_origin "$state"
git clone -q "$REPLY" "$SBX/repos/state-peer"
speer="$SBX/repos/state-peer"

_update_core_is_available_fetch "$state" 2>/dev/null
check_rc "up-to-date → 1" $? 1

fixture_commit "$speer" "upstream moves" .file="upstream"
git -C "$speer" push -q origin main
_update_core_is_available_fetch "$state" 2>/dev/null
check_rc "behind → 0 (update available)" $? 0
git -C "$state" merge -q --ff-only origin/main   # converge again

fixture_commit "$state" "local only" .localwork="ahead"
_update_core_is_available_fetch "$state" 2>/dev/null
check_rc "ahead → 1 (nothing to pull)" $? 1

fixture_commit "$speer" "upstream divergence" .file="diverged"
git -C "$speer" push -q origin main
_update_core_is_available_fetch "$state" 0 2>/dev/null
check_rc "diverged, allow=0 → 1 (skip)" $? 1
_update_core_is_available_fetch "$state" 1 2>/dev/null
check_rc "diverged, allow=1 → 0 (proceed)" $? 0

git -C "$state" remote set-url origin /nonexistent/nowhere.git
_update_core_is_available_fetch "$state" 2>/dev/null
check_rc "fetch failure → 2" $? 2

harness_summary
