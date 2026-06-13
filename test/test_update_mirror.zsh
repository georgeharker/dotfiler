#!/usr/bin/env zsh
# test_update_mirror.zsh — end-to-end mirroring for the MAIN dotfiles repo:
# upstream commits (modify / add / delete / rename) flow through the real
# cycle — fetch, plan, merge, remove, unpack — and the link dest's on-disk
# state (including file CONTENTS read through the links) mirrors upstream.
#
# Uses test/lib/update_harness.zsh.

source "${0:A:h}/lib/update_harness.zsh"

harness_init

section "main repo: upstream changes mirror to the link dest"

# "Installed" dotfiles repo with an origin, plus a peer clone acting as
# the machine where upstream work happens.
fixture_repo mainrepo .zshrc="zsh v1" .config/app/conf="conf v1" \
    .oldname="rename-me" dotfiles_exclude=""
repo="$REPLY"
fixture_origin "$repo"
git clone -q "$REPLY" "$SBX/repos/peer"
peer="$SBX/repos/peer"

# Initial deployment
plan_run "$repo" "$(git -C "$repo" rev-list --max-parents=0 HEAD)..HEAD"
update_unpack_exec "$repo" "${_update_core_files_to_unpack[@]}" >/dev/null 2>&1
assert_dest_content "initial deploy content" .zshrc "zsh v1"
assert_dest_link    "initial rename source linked" .oldname "$repo"

# Upstream: one commit batch with all four change kinds
fixture_commit "$peer" "upstream batch" \
    .zshrc="zsh v2" .newfile="brand new"
fixture_commit "$peer" "upstream removals" --rm=.config/app/conf
fixture_commit "$peer" "upstream rename" --mv=.oldname:.newname
git -C "$peer" push -q origin main

# The real cycle: fetch → plan (pre-merge range) → merge → remove → unpack
git -C "$repo" fetch -q origin
plan_run "$repo" "HEAD..origin/main"
assert_unpack "plan picks up modify+add+rename-dest" .zshrc .newfile .newname
assert_remove "plan picks up delete+rename-src" .config/app/conf .oldname
git -C "$repo" merge -q --ff-only origin/main
update_remove_exec "${_update_core_files_to_remove[@]}"
update_unpack_exec "$repo" "${_update_core_files_to_unpack[@]}" >/dev/null 2>&1

# Disk state mirrors upstream
assert_dest_content "modified content visible through link" .zshrc "zsh v2"
assert_dest_link    "added file linked"                      .newfile "$repo"
assert_dest_content "added file content"                     .newfile "brand new"
assert_dest_absent  "deleted file unlinked"                  .config/app/conf
assert_dest_absent  "rename source unlinked"                 .oldname
assert_dest_link    "rename dest linked"                     .newname "$repo"
assert_dest_content "rename dest carries the content"        .newname "rename-me"

# Idempotence: the post-merge range is empty — nothing further planned
plan_run "$repo" "HEAD..origin/main"
assert_plan_counts "post-update plan is empty" 0 0

harness_summary
