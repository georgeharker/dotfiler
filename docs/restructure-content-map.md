# Docs Restructure Content Map

Review artifact for the 2026-06 documentation restructure. Every section of
the pre-restructure docs is mapped to where its content now lives, or an
explicit drop reason. Validate with `scripts/check-docs.zsh`. Delete after
review.

Destinations are relative to `docs/`.

## README.md (old)

| Old section | Destination |
|---|---|
| Why Dotfiler? / Comparison with alternatives / Works great with zdot | `../README.md#why-dotfiler` |
| Documentation | `../README.md#documentation` (now the journey table) + `README.md` (docs index) |
| Quick Start | `../README.md#quick-start` |
| Installation (Option 1: Git Submodule / Option 2: Git Subtree / Option 3: Standalone Clone) | `../README.md#installation` (subtree-spec detail → `configuration.md#updates--dotfilerupdate`) |
| New Machine Setup | `../README.md#new-machine-setup` |
| Commands: dotfiler setup — Track and link dotfiles; dotfiler check-updates — Check for upstream changes; dotfiler update — Pull updates and re-link; dotfiler install — Bootstrap a new machine; dotfiler gui — Graphical interface | `commands.md#quick-reference` — corrected against the dispatcher: added `update-self`, the git wrappers (ingest/add/commit/status/push), `setup -g/--debug`, `update -d/--debug`, `install --profile`; fixed `-t`=track / `-x`=untrack |
| Auto-Update on Login / Integration | `../README.md#updates-at-login` (modes) + `how-updates-work.md#setting-up-automatic-checks` |
| Auto-Update / Update modes table | `how-updates-work.md#update-modes` + `configuration.md#updates--dotfilerupdate` (OMZ fallback noted there) |
| Auto-Update / Debugging the update check | `how-updates-work.md#debugging-the-login-check` |
| Auto-Update / Check frequency | `how-updates-work.md#update-frequency` |
| Auto-Update / How the check works | `how-updates-work.md#how-the-login-check-works` — corrected: lock staleness is 10 minutes, not 24 h; no tty check exists (dropped from the skip list) |
| Auto-Update / Authenticated GitHub API requests | `how-updates-work.md#how-the-login-check-works` + `configuration.md#environment-variables` |
| Auto-Update / background mode and typed-input fallback | `how-updates-work.md#background-mode-and-typed-input` |
| Auto-Update / Skipped silently when | `how-updates-work.md#how-the-login-check-works` |
| Modular Install System (incl. module table) | `../README.md#modular-install-system` — table corrected to the current 00–09 set (07-ai added; post-install now 09) |
| Configuration (zstyle block) | `configuration.md` — corrected: `':dotfiles:install'` reads style `path` (not `directory`); added `release-channel`, `in-tree-commit`, `verbose`, `subtree-url` |
| Branch overrides and switching | `how-updates-work.md#branch-overrides-round-2-only` (user) + `update-internals.md#branch-resolution` (chain mechanics) |
| File Exclusions | `configuration.md#the-exclusions-file` |
| Shell Completions | `../README.md#shell-completions` |
| Directory Structure | `../README.md#directory-structure` |
| Typical Workflows (Track a new config file; Edit a tracked config; Pull updates on another machine; Restore everything on a new machine) | `../README.md#day-to-day` (now via the git wrappers) + `../README.md#new-machine-setup` |
| Troubleshooting | `../README.md#troubleshooting` |
| Acknowledgements | `../README.md#acknowledgements` |

## docs/how-updates-work.md (split)

| Old section | Destination |
|---|---|
| From a User Perspective / Setting Up Automatic Checks | `how-updates-work.md#setting-up-automatic-checks` — corrected: `dotfiler scripts-dir` does not exist; canonical sourcing line restored |
| Update Modes / Update Frequency / Release Channel | unchanged in place (rounds now defined before first use) |
| Branch Overrides | `how-updates-work.md#branch-overrides-round-2-only` (user how-to) + `update-internals.md#branch-resolution` (5-tier chain, switch behavior, subtree spec) |
| Two Rounds of Four Phases (1. Plan / 2. Pull / 3. Unpack / 4. Post) | `how-updates-work.md#two-rounds-of-four-phases` (high level); hint mechanics → `update-internals.md#hint-resolution-round-1` — corrected: SHA-change check + safe degradation, not merge-base |
| Plan-phase file discovery | `update-internals.md#file-discovery` — corrected: updates walk the commit range; the two find passes belong to setup-style full unpacks |
| Why Dotfiles Run First | `how-updates-work.md#why-dotfiles-run-first` (summary) + `update-internals.md#ordering-dotfiles-first-hooks-from-the-linktree` |
| dotfiler Self-Update | `update-internals.md#dotfiler-self-update` — corrected: `self-frequency` zstyle does not exist; one frequency gate |
| Deployment Topologies / In-Tree Commits | `update-internals.md#deployment-topologies` + `update-internals.md#pointer-and-marker-bookkeeping-post-phase`; user-level setting kept at `how-updates-work.md#after-a-submodule-update` |
| Manual Update Commands | `how-updates-work.md#manual-update-commands` — added the third `--update-phases` value (`hooks`) |

## docs/authoring-install-files.md (rewritten in place)

| Old section | Destination |
|---|---|
| File Naming | `authoring-install-files.md#file-naming` — corrected: post-install is 09 |
| Module Structure | `authoring-install-files.md#module-structure` — corrected: the third variable is `module_main_function`; the fallback derives from the numbered filename, so it is set explicitly |
| Available Functions / OS Detection / Profile Support / Force Re-install / Deferred Instructions / Section Headings | `authoring-install-files.md#helper-functions-two-layers` — corrected: `force_install`, `check_profile`, `print_section`/`print_subsection`, `os_is_*` are install-dir helpers (travel with the copied example), not core API |
| Typical Module Pattern | `authoring-install-files.md#typical-module-pattern` (now sets `module_main_function`) |
| The 00-dotfiler-install.zsh Convention | `authoring-install-files.md#file-naming` |
| Running Install | `authoring-install-files.md#running-install` + `commands.md#install` |

## docs/update-hooks.md (corrected in place)

| Change | Destination |
|---|---|
| `_update_core_commit_parent` 2-arg example (real signature is 5 args) | `update-hooks.md#committing-parent` — now shows `_update_core_component_post_marker` as the high-level path plus the real primitive signature |
| SHA/ext marker functions documented as `reply[1]` (they set `REPLY`) | `update-hooks.md#sha-markers` |
| build_file_lists find-passes description | `update-hooks.md#file-change-lists` — commit-range walk, `typeset -aU` requirement noted |

## Unchanged

`zdot-integration.md` (validated during the zdot pass). `../example_install/README.md`
corrected in place (`.sh` → `.zsh` filenames). New files: `commands.md`,
`configuration.md`, `update-internals.md`, `README.md` (this index).
