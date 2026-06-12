#!/usr/bin/env zsh
# test_update_unpack.zsh — L2/L3 tests: plan against a git history, execute
# the unpack exactly the way update.zsh does, and assert the ON-DISK state at
# the link dest (symlinks, content visible through them, removals). Also
# exercises deployment topologies: plain repo, subtree, submodule.
#
# Uses test/lib/update_harness.zsh.

source "${0:A:h}/lib/update_harness.zsh"

harness_init

# ---------------------------------------------------------------------------
section "plan → unpack → disk state (plain repo)"
fixture_repo deploy .zshrc="zsh v1" .config/app/conf="conf v1" \
    dotfiles_exclude=""
repo="$REPLY"

# initial deployment: link everything the plan names
fixture_commit "$repo" "noop"   # ensure HEAD has a parent for the init range
plan_run "$repo" "$(git -C "$repo" rev-list --max-parents=0 HEAD)..HEAD"
update_unpack_exec "$repo" "${_update_core_files_to_unpack[@]}" >/dev/null 2>&1
assert_dest_link    "zshrc linked"            .zshrc "$repo"
assert_dest_link    "nested conf linked"      .config/app/conf "$repo"
assert_dest_content "content readable through link" .zshrc "zsh v1"

# upstream modify: content changes are visible through the existing link
# WITHOUT re-unpacking — that's the point of symlink deployment
fixture_commit "$repo" "modify zshrc" .zshrc="zsh v2"
assert_dest_content "modified content visible through link, no re-unpack" \
    .zshrc "zsh v2"

# upstream add: plan + exec links the new file
sha1=$(repo_sha "$repo")
fixture_commit "$repo" "add alias file" .aliases="alias v1"
plan_run "$repo" "${sha1}..HEAD"
update_unpack_exec "$repo" "${_update_core_files_to_unpack[@]}" >/dev/null 2>&1
assert_dest_link    "newly added file linked"  .aliases "$repo"
assert_dest_content "new file content on disk" .aliases "alias v1"

# upstream delete: plan says remove; update's removal loop unlinks it
sha2=$(repo_sha "$repo")
fixture_commit "$repo" "drop aliases" --rm=.aliases
plan_run "$repo" "${sha2}..HEAD"
assert_remove "delete planned" .aliases
update_remove_exec "${_update_core_files_to_remove[@]}"
assert_dest_absent "removed file unlinked from dest" .aliases

# removal loop must NOT delete a non-symlink (user's real file)
print -r -- "precious" > "$SBX/home/.aliases"
update_remove_exec .aliases
assert_dest_content "removal never deletes a real file" .aliases "precious"
rm -f "$SBX/home/.aliases"

# force path: -U relinks over a divergent regular file
rm -f "$SBX/home/.zshrc"
print -r -- "local edits" > "$SBX/home/.zshrc"
update_unpack_exec -U "$repo" .zshrc >/dev/null 2>&1
assert_dest_link    "-U replaces a divergent file with the link" .zshrc "$repo"
assert_dest_content "-U restores repo content" .zshrc "zsh v2"

# ---------------------------------------------------------------------------
section "topology: subtree component inside the dotfiles repo"
fixture_repo vendorchild .vendorrc="vendor v1" themes/dark="dark v1"
child="$REPLY"
fixture_repo subtreeparent .gitconfig="git v1" dotfiles_exclude=""
parent="$REPLY"

# --squash is the supported workflow: the squash commit (git-subtree-dir +
# git-subtree-split trailers) is skipped by the plan builder, and the merge
# commit that follows carries the changes with dotfiles-relative paths.
sha_pre=$(repo_sha "$parent")
fixture_subtree_add "$parent" "$child" ".vendor" --squash
plan_run "$parent" "${sha_pre}..HEAD"
assert_unpack "squash subtree add plans prefixed files via the merge commit" \
    .vendor/.vendorrc .vendor/themes/dark
update_unpack_exec "$parent" "${_update_core_files_to_unpack[@]}" >/dev/null 2>&1
assert_dest_link    "subtree file linked under prefix" .vendor/.vendorrc "$parent"
assert_dest_content "subtree content on disk" .vendor/themes/dark "dark v1"

# subtree pull --squash of upstream child changes
fixture_commit "$child" "child update" themes/dark="dark v2" themes/light="light v1"
sha_pull=$(repo_sha "$parent")
fixture_subtree_pull "$parent" "$child" ".vendor" --squash
plan_run "$parent" "${sha_pull}..HEAD"
assert_unpack "squash subtree pull plans changed+new prefixed files" \
    .vendor/themes/dark .vendor/themes/light
update_unpack_exec "$parent" "${_update_core_files_to_unpack[@]}" >/dev/null 2>&1
assert_dest_content "pulled subtree change visible on disk" \
    .vendor/themes/dark "dark v2"
assert_dest_content "pulled subtree addition on disk" \
    .vendor/themes/light "light v1"

# DOCUMENTS CURRENT BEHAVIOR: a NON-squash `git subtree add` produces a
# single merge commit that itself carries the dir+split trailers, so the
# squash-skip heuristic discards it and nothing is planned. Fine for
# registered components (their machinery owns their files); a plain
# vendored non-squash subtree would miss its initial files until they
# next change.
fixture_repo vendorchild2 .v2rc="v2"
child2="$REPLY"
sha_ns=$(repo_sha "$parent")
fixture_subtree_add "$parent" "$child2" ".vendor2"
plan_run "$parent" "${sha_ns}..HEAD"
assert_not_planned "non-squash subtree add is skipped by the squash heuristic (known gap)" \
    .vendor2/.v2rc

# ---------------------------------------------------------------------------
section "topology: submodule pointer bumps"
# Documents current plan behavior: a submodule bump shows as M of the
# gitlink path. Real deployments exclude component dirs from the main
# unpack (exclude_component_dirs); the plan layer itself does not.
fixture_repo subchild inner.txt="inner v1"
subchild="$REPLY"
fixture_repo subparent .gitconfig="git v1"
subparent="$REPLY"
fixture_submodule_add "$subparent" "$subchild" ".component"

fixture_commit "$subchild" "child moves" inner.txt="inner v2"
sha_bump=$(repo_sha "$subparent")
git -C "$subparent/.component" pull -q origin main 2>/dev/null || \
    git -C "$subparent/.component" fetch -q "$subchild" main 2>/dev/null
git -C "$subparent/.component" checkout -q "$(repo_sha "$subchild")"
git -C "$subparent" add .component
git -C "$subparent" commit -qm "bump component"
plan_run "$subparent" "${sha_bump}..HEAD"
assert_unpack "submodule bump plans the gitlink path (excluded later by component machinery)" \
    .component

harness_summary
