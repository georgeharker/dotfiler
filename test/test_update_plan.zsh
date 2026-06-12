#!/usr/bin/env zsh
# test_update_plan.zsh — L1 tests for _update_core_build_file_lists: crafted
# git histories in a sandbox, assertions on the unpack/remove plan arrays.
#
# Uses test/lib/update_harness.zsh (real git, file:// fixtures, no user state).

source "${0:A:h}/lib/update_harness.zsh"

harness_init

# ---------------------------------------------------------------------------
section "adds, modifies, deletes"
fixture_repo planrepo .base="base"
local repo="$REPLY"
local sha0=$(repo_sha "$repo")

fixture_commit "$repo" "add files" .zshrc="z1" .config/app/conf="c1"
fixture_commit "$repo" "modify one" .zshrc="z2"
plan_run "$repo" "${sha0}..HEAD"
assert_unpack "added+modified files planned"   .zshrc .config/app/conf
assert_plan_counts "dedup: modified-after-add appears once" 2 0

local sha1=$(repo_sha "$repo")
fixture_commit "$repo" "delete conf" --rm=.config/app/conf
plan_run "$repo" "${sha1}..HEAD"
assert_remove "deleted file planned for removal" .config/app/conf
assert_plan_counts "delete-only range" 0 1

# add then delete within one range — net effect is removal only
local sha2=$(repo_sha "$repo")
fixture_commit "$repo" "add ephemeral" .ephemeral="tmp"
fixture_commit "$repo" "drop ephemeral" --rm=.ephemeral
plan_run "$repo" "${sha2}..HEAD"
assert_not_unpack "add-then-delete cancels the unpack" .ephemeral
assert_remove "add-then-delete still removes a stale link" .ephemeral

# delete then re-add within one range — net effect is unpack
local sha3=$(repo_sha "$repo")
fixture_commit "$repo" "drop zshrc" --rm=.zshrc
fixture_commit "$repo" "restore zshrc" .zshrc="z3"
plan_run "$repo" "${sha3}..HEAD"
assert_unpack "delete-then-re-add unpacks" .zshrc

# ---------------------------------------------------------------------------
section "renames"
local sha4=$(repo_sha "$repo")
fixture_commit "$repo" "seed rename source" .oldname="same content"
local sha5=$(repo_sha "$repo")
fixture_commit "$repo" "rename it" --mv=.oldname:.newname
plan_run "$repo" "${sha5}..HEAD"
assert_remove "rename removes the old path" .oldname
assert_unpack "rename unpacks the new path" .newname

# rename in the same range as the add: old path was never linked, but a
# remove entry for it is harmless; the new path must be planned.
plan_run "$repo" "${sha4}..HEAD"
assert_unpack "add+rename range plans the final name" .newname

# ---------------------------------------------------------------------------
section "merges (--first-parent)"
local sha6=$(repo_sha "$repo")
fixture_branch_merge "$repo" feature "merge feature" "feature work" \
    .feature_file="ff" .config/app/feat="cf"
plan_run "$repo" "${sha6}..HEAD"
assert_unpack "merged branch files arrive via the merge commit" \
    .feature_file .config/app/feat

# ---------------------------------------------------------------------------
section "exclusions"
local sha7=$(repo_sha "$repo")
fixture_commit "$repo" "excluded + kept" \
    always_exclude=$'.secret*' .secret_token="s" .kept="k"
plan_run "$repo" "${sha7}..HEAD"
assert_unpack "non-excluded file planned" .kept
assert_not_planned "always_exclude filters at plan time" .secret_token

# user-level excludes file via --excludes
local sha8=$(repo_sha "$repo")
fixture_commit "$repo" "user-excluded" .noisy="n" .wanted="w"
print -r -- ".noisy" > "$SBX/user_excludes"
plan_run --excludes "$SBX/user_excludes" "$repo" "${sha8}..HEAD"
assert_unpack "non-excluded survives user excludes" .wanted
assert_not_planned "--excludes file filters at plan time" .noisy

# enforce layer: .git/ and .nounpack/ are always excluded
local sha9=$(repo_sha "$repo")
fixture_commit "$repo" "nounpack content" .nounpack/inner="x" .visible="v"
plan_run "$repo" "${sha9}..HEAD"
assert_unpack "sibling of enforced exclusion planned" .visible
assert_not_planned ".nounpack/ enforced at plan time" .nounpack/inner

# ---------------------------------------------------------------------------
section "remote-range shape (origin fixture)"
# The real update flow plans over HEAD..origin/main after a fetch. Simulate:
# a second clone pushes upstream work, the primary fetches and plans.
fixture_repo remoterepo .tracked="t0"
local prim="$REPLY"
fixture_origin "$prim"
git clone -q "$REPLY" "$SBX/repos/peer"
local peer="$SBX/repos/peer"
fixture_commit "$peer" "upstream work" .tracked="t1" .upstream_new="u1"
git -C "$peer" push -q origin main
git -C "$prim" fetch -q origin
plan_run "$prim" "HEAD..origin/main"
assert_unpack "fetched-but-unmerged range plans upstream files" \
    .tracked .upstream_new
assert_plan_counts "remote range counts" 2 0

harness_summary
