# Update Internals

How the update machinery works under the hood: deployment topologies, branch
resolution, hint resolution, pointer/marker bookkeeping, and file discovery.
For the user-facing view (modes, frequency, release channels) see
[How Updates Work](how-updates-work.md); for writing a component hook and the
`_update_core_*` API, see [Update Hooks](update-hooks.md).

---

## Deployment Topologies

dotfiler detects how each component repo is structured
(`_update_core_detect_deployment`, `update_core.zsh`) and adapts its pull
strategy accordingly:

| Topology | Detection | Pull strategy |
|----------|-----------|---------------|
| **Submodule** | `.git` is a file (gitdir pointer) and the path appears in the parent's `.gitmodules` | `git submodule update --remote` |
| **Subtree** | SHA marker file (`.<dir>-subtree-sha`) adjacent to the component dir | `git subtree pull --squash` |
| **Standalone** | Own `.git` directory; repo is its own toplevel | `git pull --ff-only --autostash` |
| **Subdir** | Parent repo found, no submodule/subtree indicator | No-op (parent manages it) |

`.git` symlinks are resolved before detection — a component stored under a
linktree directory (where `.git` may be a symlink) is still detected as a
submodule when appropriate.

## Branch Resolution

Round 2 (self-directed) pulls resolve the upstream branch via a chain
(`_update_core_get_default_branch`), highest-priority first:

1. `zstyle ':<scope>:update' branch <name>` — `:dotfiler:update` for
   dotfiler-self, `:zdot:update` for zdot, your own scope for your hooks.
2. `.gitmodules` `submodule.<rel>.branch` *(submodule topology only)*.
3. `refs/remotes/<remote>/HEAD` (local mirror of the remote default).
4. `git remote show <remote>` HEAD branch.
5. `main`, then `master`; `main` if neither resolves.

Tiers 1–2 are **explicit overrides**. When one produces a value and the
worktree isn't on that branch, Round 2 actively switches
(`_update_core_ensure_on_branch`): it checks the branch out, creating a
local tracking branch from `<remote>/<branch>` if missing, then
fast-forwards. There is no rebase fallback — a local branch with commits
ahead of remote fails loudly.

When only tiers 3–5 fire (no explicit override), the pull runs on whatever
branch is currently checked out. This is deliberate: a user who manually
checked out a feature branch for ad-hoc testing shouldn't have origin/HEAD
imposed on them just because they didn't configure an override.

Branch overrides change only Round 2's pull target — Round 1 owns the
pointer trajectory and follows whatever the dotfiles maintainer recorded,
faithfully. One expected side effect when overriding a submodule
component's branch: the parent repo's gitlink will show the submodule as
differing from the worktree. That is normal — you are intentionally ahead
of (or beside) the recorded pointer, and the pointer catches up when the
maintainer records the new SHA.

For subtree topology, `zstyle ':dotfiler:update' subtree-remote` accepts
`'<remote>'` or `'<remote> <branch>'`; when the branch is omitted, this
chain fills it in (`_update_core_resolve_subtree_spec`).
`subtree-url` overrides the remote URL.

## Hint Resolution (Round 1)

When the dotfiles repo has incoming commits, the plan phase reads each
component's old and new pointer from the dotfiles commit range — the
submodule gitlink, subtree SHA marker, or external marker, dispatched by
topology (`_update_core_resolve_component_range`). A hint is attempted only
when the recorded SHA changed, and the resolver degrades safely: an
unchanged component SHA yields no range, and a diverged or backwards pointer
yields an empty hint. In every no-hint case the component is left to
Round 2's self-directed check.

A component pull is then skipped when its plan range is empty, or when its
HEAD already matches the dotfiles-recorded target (e.g. the shell-startup
hook advanced it before `dotfiler update` ran).

## Pointer and Marker Bookkeeping (Post Phase)

After a successful component pull, the post phase records what was
installed (`_update_core_component_post_marker`), dispatched by topology:

- **submodule** — the parent repo's gitlink is committed
  (`_update_core_commit_parent`).
- **subtree** — the `.<dir>-subtree-sha` marker file is written and
  committed.
- **standalone** — an external marker (`.<dir>-ext-sha`) is written and
  committed.

The commit behavior is governed by `zstyle ':<scope>:update'
in-tree-commit` (`auto` by default, or `prompt`/`none`). The stash dance
around the commit tolerates *expected* dirt — the pending gitlink mismatch
or staged marker that the pull itself produced, and sibling components'
pending pointers — while still refusing to auto-commit over unrelated
staged changes.

In Round 1 the dotfiles history is already authoritative, so post does not
write markers or commit pointers; that is Round 2's job after self-directed
pulls.

## File Discovery

Two different mechanisms, used in different situations:

- **Incremental updates** are commit-range based:
  `_update_core_build_file_lists` walks the incoming commits and derives
  exactly which files to unpack (added/modified) and remove (deleted).
  Squashed subtree merge commits are skipped.
- **Full unpacks** (`dotfiler setup -u`, bootstrap) scan the whole repo
  with two independent find passes (`setup_core.zsh`): a *shallow* pass
  (depth 1, dot-prefixed entries — gating which top-level entries appear in
  `$HOME`) and a *deep* pass (all depths, files and symlinks only, pruned
  by exclusions).

Exclusion patterns (`.git/`, `.nounpack/`, your `dotfiles_exclude` rules)
are the authoritative gate in both modes. Files under `.nounpack/` are
never included at any depth.

## Ordering: Dotfiles First, Hooks From the Linktree

Within each phase, the main dotfiles repo runs before any hook (main is
registered first; its pull additionally runs in its own step before the
component loop). This matters for hooks whose code lives *inside* the
dotfiles repo, like zdot's:

1. Pull: dotfiles first → new hook code arrives on disk in the repo.
2. Unpack: dotfiles first → the new hook code is symlinked into its
   linktree destination.
3. Only then do the hook's own pull/unpack run — executing the
   now-current code.

Hook files are sourced from their **linktree** path, which only advances
when an unpack completes successfully. Until then it reflects the last
fully-installed state — so a hook never executes a partially-updated
version of itself that arrived via `git pull` but was not yet unpacked.

## dotfiler Self-Update

dotfiler registers itself as a component (named `dotfiler`, immediately
after `main`), so its updates ride the same two-round dispatch. Its files
live in `.nounpack/dotfiler/` and are not symlinked via the link-tree, so
its unpack phase is a no-op; success is recorded in
`$XDG_CACHE_HOME/dotfiler/dotfiler_scripts_update`. There is no separate
self-update frequency — the login-time check is gated once by
`zstyle ':dotfiler:update' frequency`.
