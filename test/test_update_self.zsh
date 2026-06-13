#!/usr/bin/env zsh
# test_update_self.zsh — dotfiler's OWN update across its deployment
# topologies (standalone clone, submodule, subtree --squash, plain subdir):
# init/detect, self-directed plan (range + file lists), pull (content
# actually advances on disk), and post (SHA marker lifecycle).
#
# Uses test/lib/update_harness.zsh; sources update.zsh (source-guarded) for
# the _update_dotfiler_* phase functions.

source "${0:A:h}/lib/update_harness.zsh"
source "${0:A:h}/../update.zsh"
source "${0:A:h}/../setup.zsh"   # _setup_bootstrap_hook (source-guarded; main is a no-op when sourced)

harness_init

typeset -gi pass=$pass fail=$fail   # shared with harness
typeset -gi _force=0 _dry_run=0
export XDG_CACHE_DIR="$SBX/cache"
zstyle ':dotfiler:update' release-channel any   # follow tips, not semver tags

check_eq() {
    local _desc=$1 _got=$2 _want=$3
    if [[ "$_got" == "$_want" ]]; then
        (( pass++ ))
    else
        printf 'FAIL  %s\n      got=%s want=%s\n' "$_desc" "$_got" "$_want"
        (( fail++ ))
    fi
}

# Fresh registry + plan state per topology scenario
reset_self() {
    _update_core_init_registry
    _dotfiler_registered_hooks=()
    typeset -g _dotfiler_plan_dotfiler_range=""
    typeset -g _dotfiler_hint_range_dotfiler=""
    typeset -ga _dotfiler_plan_dotfiler_to_unpack=() _dotfiler_plan_dotfiler_to_remove=()
}

# The dotfiler-ish file set; dotfiles_exclude is required by the plan step.
DFILES=(update.zsh="u1" helpers.zsh="h1" lib/extra.zsh="e1" dotfiles_exclude="")

# upstream_move <repo> — the upstream change the self-update should mirror
upstream_move() {
    fixture_commit "$1" "self update" update.zsh="u2" lib/new.zsh="n1"
}

# ---------------------------------------------------------------------------
section "topology: standalone (dotfiler is its own clone)"
reset_self
fixture_repo selfsolo "${DFILES[@]}"
solo="$REPLY"
fixture_origin "$solo"
git clone -q "$REPLY" "$SBX/repos/self-peer"
upstream_move "$SBX/repos/self-peer"
git -C "$SBX/repos/self-peer" push -q origin main

script_dir="$solo"
_update_dotfiler_init >/dev/null 2>&1
check_eq "standalone detected" "$_dotfiler_topology" standalone
_update_dotfiler_plan >/dev/null 2>&1
if [[ -n "$_dotfiler_plan_dotfiler_range" ]]; then (( pass++ )); else printf 'FAIL  standalone: plan set a range\n'; (( fail++ )); fi
assert_unpack "standalone: plan lists changed files" update.zsh lib/new.zsh
_update_dotfiler_pull >/dev/null 2>&1; rc=$?
check_eq "standalone: pull succeeds" $rc 0
assert_content_at "standalone: scripts advanced on disk" "$solo/update.zsh" "u2"
assert_content_at "standalone: new file arrived" "$solo/lib/new.zsh" "n1"

# ---------------------------------------------------------------------------
section "topology: submodule (dotfiler inside the dotfiles repo)"
reset_self
fixture_repo selfsub "${DFILES[@]}"
selfsub="$REPLY"
fixture_repo subhost .gitconfig="g"
host="$REPLY"
mkdir -p "$host/.nounpack"
fixture_submodule_add "$host" "$selfsub" ".nounpack/dotfiler"
upstream_move "$selfsub"

script_dir="$host/.nounpack/dotfiler"
_update_dotfiler_init >/dev/null 2>&1
check_eq "submodule detected" "$_dotfiler_topology" submodule
_update_dotfiler_plan >/dev/null 2>&1
if [[ -n "$_dotfiler_plan_dotfiler_range" ]]; then (( pass++ )); else printf 'FAIL  submodule: plan set a range\n'; (( fail++ )); fi
assert_unpack "submodule: plan lists changed files" update.zsh lib/new.zsh
_update_dotfiler_pull >/dev/null 2>&1; rc=$?
check_eq "submodule: pull succeeds" $rc 0
assert_content_at "submodule: scripts advanced on disk" \
    "$host/.nounpack/dotfiler/update.zsh" "u2"

# ---------------------------------------------------------------------------
section "topology: subtree --squash (marker lifecycle)"
reset_self
fixture_repo selftree "${DFILES[@]}"
selftree="$REPLY"
fixture_repo treehost .gitconfig="g"
thost="$REPLY"
mkdir -p "$thost/.nounpack"
synced=$(repo_sha "$selftree")
git -C "$thost" subtree add -q --prefix=.nounpack/dotfiler "$selftree" main --squash
# Seed the SHA marker the way bootstrap/post would (tracked, adjacent)
_update_core_sha_marker_path "$thost/.nounpack/dotfiler"
marker="$REPLY"
print -r -- "$synced" > "$marker"
git -C "$thost" add "$marker" && git -C "$thost" commit -qm "marker"
# Subtree remote/branch config for the fixture
git -C "$thost" remote add dotfiler "$selftree"
zstyle ':dotfiler:update' subtree-remote "dotfiler"
zstyle ':dotfiler:update' subtree-url "$selftree"
zstyle ':dotfiler:update' branch main
upstream_move "$selftree"

script_dir="$thost/.nounpack/dotfiler"
_update_dotfiler_init >/dev/null 2>&1
check_eq "subtree detected" "$_dotfiler_topology" subtree
_update_dotfiler_plan >/dev/null 2>&1
if [[ -n "$_dotfiler_plan_dotfiler_range" ]]; then (( pass++ )); else printf 'FAIL  subtree: plan set a range\n'; (( fail++ )); fi
check_eq "subtree: range starts at the marker SHA" "${_dotfiler_plan_dotfiler_range%%..*}" "$synced"
assert_unpack "subtree: plan lists changed files" update.zsh lib/new.zsh
_update_dotfiler_pull >/dev/null 2>&1; rc=$?
check_eq "subtree: pull succeeds" $rc 0
assert_content_at "subtree: scripts advanced in the parent prefix" \
    "$thost/.nounpack/dotfiler/update.zsh" "u2"
_update_dotfiler_post >/dev/null 2>&1
new_tip=$(repo_sha "$selftree")
check_eq "subtree: post rewrote the SHA marker to the new tip" \
    "$(<"$marker")" "$new_tip"

# ---------------------------------------------------------------------------
section "topology: embedded, unconfigured (documents current behavior)"
# The default subtree spec ("dotfiler") and canonical subtree-url mean an
# embedded dotfiler is treated as a subtree pulling from the PUBLISHED repo
# — the intended user update channel. A plain subdir embedding never
# detects as subdir via self-update; its updates arrive through the MAIN
# repo pull instead (the scripts are ordinary tracked files — see
# test_update_mirror.zsh), so the self-update hook standing down here is
# the correct outcome. The no-marker bootstrap path is covered in the next
# section. (zdot has the same shape: default spec "zdot main".)
reset_self
fixture_repo dirhost .gitconfig="g" .nounpack/dotfiler/update.zsh="u1"
dhost="$REPLY"
zstyle -d ':dotfiler:update' subtree-remote
zstyle -d ':dotfiler:update' subtree-url
script_dir="$dhost/.nounpack/dotfiler"   # shuck: ignore=C001  # read by sourced fns
_update_dotfiler_init >/dev/null 2>&1
check_eq "embedded-unconfigured detects as subtree (default spec is non-empty)" \
    "$_dotfiler_topology" subtree
_update_dotfiler_plan >/dev/null 2>&1
check_eq "no marker: self-directed plan is a clean no-op" \
    "$_dotfiler_plan_dotfiler_range" ""
_update_dotfiler_plan --phase=dotfiles >/dev/null 2>&1
check_eq "no hint: dotfiles-phase plan is a clean no-op" \
    "$_dotfiler_plan_dotfiler_range" ""
_update_dotfiler_pull >/dev/null 2>&1; rc=$?
check_eq "pull is a clean skip" $rc 0

# ---------------------------------------------------------------------------
section "the REAL bootstrap writer records the child SHA (not parent HEAD)"
# Drive _setup_bootstrap_hook directly against a sandbox subtree — the
# faithful path, instead of hand-seeding the marker. This is the test that
# would have caught the parent-SHA poisoning bug: `rev-parse HEAD` inside a
# subtree prefix yields the PARENT merge commit, while the marker must hold
# the CHILD split SHA.
reset_self
typeset -ga force=() dry_run=()   # consumed by _update_core_maybe_stash in the commit path  # shuck: ignore=C001
fixture_repo bootchild "${DFILES[@]}"
bootchild="$REPLY"
child_sha=$(repo_sha "$bootchild")
fixture_repo boothost .gitconfig="g"
boothost="$REPLY"
mkdir -p "$boothost/.nounpack"
git -C "$boothost" subtree add -q --prefix=.nounpack/dotfiler "$bootchild" main --squash

# A minimal hook that self-registers with the subtree topology + comp_dir,
# the way a real component hook does at source time.
mkdir -p "$boothost/.config/dotfiler/hooks"
cat > "$boothost/wibble-hook.zsh" <<HOOK
_update_register_hook wibble '' '' '' '' '' '' \\
    "${boothost}/.nounpack/dotfiler" subtree ''
HOOK

# in_dotfiles=1, dotfiles_dir=boothost, force=1 (auto-commit, no prompt)
_setup_bootstrap_hook "$boothost/wibble-hook.zsh" 1 \
    "$boothost/.config/dotfiler/hooks" 1 "$boothost" >/dev/null 2>&1

_update_core_sha_marker_path "$boothost/.nounpack/dotfiler"
boot_marker="$REPLY"
check_eq "bootstrap wrote the child split SHA into the marker" \
    "$(<"$boot_marker" 2>/dev/null)" "$child_sha"
# And the marker the test hand-seeds elsewhere == what bootstrap produces,
# so the idealized fixtures and reality now agree.
_update_core_subtree_split_sha "$boothost" ".nounpack/dotfiler"
check_eq "split helper agrees with the written marker" "$REPLY" "$child_sha"

# ---------------------------------------------------------------------------
section "subtree marker is bootstrap-owned: missing = loud error, no auto-fix"
# The marker is created by setup --bootstrap-hook, propagated by clone
# (it is tracked), and advanced by post. A missing marker on a real
# subtree is an error: plan refuses loudly with restore instructions and
# never silently re-pins. A prefix with no subtree metadata (plain
# subdir) defers to the parent quietly.
reset_self
fixture_repo selftree2 "${DFILES[@]}"
selftree2="$REPLY"
fixture_repo treehost2 .gitconfig="g"
thost2="$REPLY"
mkdir -p "$thost2/.nounpack"
synced2=$(repo_sha "$selftree2")
git -C "$thost2" subtree add -q --prefix=.nounpack/dotfiler "$selftree2" main --squash
git -C "$thost2" remote add dotfiler "$selftree2"
zstyle ':dotfiler:update' subtree-remote "dotfiler"
zstyle ':dotfiler:update' subtree-url "$selftree2"
zstyle ':dotfiler:update' branch main
upstream_move "$selftree2"

# the split-trailer helper recovers the authoritative last-synced SHA
_update_core_subtree_split_sha "$thost2" ".nounpack/dotfiler"
check_eq "split trailer records the synced child SHA" "$REPLY" "$synced2"

script_dir="$thost2/.nounpack/dotfiler"
_update_dotfiler_init >/dev/null 2>&1
plan_err=$(_update_dotfiler_plan 2>&1 >/dev/null)
check_eq "no marker: plan refuses (empty range)" "$_dotfiler_plan_dotfiler_range" ""
if [[ "$plan_err" == *"SHA marker missing"* && "$plan_err" == *"bootstrap"* ]]; then
    (( pass++ ))
else
    printf 'FAIL  plan error names the marker and bootstrap\n      err=%s\n' "$plan_err"
    (( fail++ ))
fi
_update_dotfiler_pull >/dev/null 2>&1; rc=$?
check_eq "pull is a clean skip (nothing planned)" $rc 0
assert_content_at "no content was pulled" \
    "$thost2/.nounpack/dotfiler/update.zsh" "u1"

# Following the restore instruction (== what bootstrap writes) heals it:
_update_core_sha_marker_path "$thost2/.nounpack/dotfiler"
marker2="$REPLY"
print -r -- "$synced2" > "$marker2"
git -C "$thost2" add "$marker2" && git -C "$thost2" commit -qm "restore marker"
reset_self
_update_dotfiler_init >/dev/null 2>&1
_update_dotfiler_plan >/dev/null 2>&1
check_eq "restored marker: plan range starts at the synced SHA" \
    "${_dotfiler_plan_dotfiler_range%%..*}" "$synced2"
_update_dotfiler_pull >/dev/null 2>&1
assert_content_at "update flows after restore" \
    "$thost2/.nounpack/dotfiler/update.zsh" "u2"
_update_dotfiler_post >/dev/null 2>&1
check_eq "post advances the marker to the child tip" \
    "$(<"$marker2")" "$(repo_sha "$selftree2")"

# Regression guard: --force while up to date must NOT poison the marker
# with the parent repo's SHA (the fallback prefers the marker).
reset_self
_force=1
_update_dotfiler_init >/dev/null 2>&1
_update_dotfiler_plan >/dev/null 2>&1
_update_dotfiler_pull >/dev/null 2>&1
_update_dotfiler_post >/dev/null 2>&1
_force=0
check_eq "force-while-current preserves the child-tip marker" \
    "$(<"$marker2")" "$(repo_sha "$selftree2")"

# Never-subtree-added prefix (plain subdir): quiet defer, no error spam
reset_self
fixture_repo plainhost .gitconfig="g" .nounpack/dotfiler/update.zsh="u1"
phost="$REPLY"
script_dir="$phost/.nounpack/dotfiler"
zstyle ':dotfiler:update' subtree-url "$selftree2"   # still configured
_update_dotfiler_init >/dev/null 2>&1
plan_err=$(_update_dotfiler_plan 2>&1 >/dev/null)
check_eq "never-added prefix: plan no-ops" "$_dotfiler_plan_dotfiler_range" ""
if [[ "$plan_err" != *"SHA marker missing"* ]]; then
    (( pass++ ))
else
    printf 'FAIL  subdir must not get marker-missing error spam\n'
    (( fail++ ))
fi
# ...and availability must not nag either (no metadata → parent manages)
_update_core_is_dotfiler_available "$script_dir" \
    "$_dotfiler_subtree_spec" "$_dotfiler_subtree_url" >/dev/null 2>&1; rc=$?
check_eq "never-added prefix: not reported as update-available" $rc 1
# ...while a broken subtree (metadata, no marker) IS reported, so the
# update run surfaces the loud error
_update_core_sha_marker_path "$thost2/.nounpack/dotfiler"
rm -f "$REPLY"
_update_core_is_dotfiler_available "$thost2/.nounpack/dotfiler" \
    "dotfiler" "$selftree2" >/dev/null 2>&1; rc=$?
check_eq "broken subtree (marker lost): reported available to surface the error" $rc 0

harness_summary
