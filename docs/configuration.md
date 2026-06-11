# Configuration Reference

All dotfiler configuration: `zstyle` keys, the exclusions file, and
environment variables. Set zstyles in your `.zshrc` **before** sourcing
`check_update.zsh`.

---

## Paths — `:dotfiles:*`

Source: `helpers.zsh`. Each key reads the style named `path`; relative
values resolve against the dotfiles directory.

| Key | Default | Description |
|---|---|---|
| `':dotfiles:directory' path` | auto-detected | The dotfiles repo location. |
| `':dotfiles:scripts' path` | `.nounpack/dotfiler` inside the repo | Where dotfiler's scripts live (set for standalone installs). |
| `':dotfiles:install' path` | `.nounpack/install` inside the repo | The install-modules directory. |
| `':dotfiles:exclude' path` | `dotfiles_exclude` in the repo root | The exclusions file. |

```zsh
zstyle ':dotfiles:directory' path '/path/to/dotfiles'
zstyle ':dotfiles:scripts'   path "$HOME/.dotfiler"     # standalone install
zstyle ':dotfiles:install'   path '/path/to/install'
zstyle ':dotfiles:exclude'   path '/path/to/my-exclusions.txt'
```

## Updates — `:dotfiler:update`

Source: `check_update.zsh`, `update_core.zsh`. See
[How Updates Work](how-updates-work.md) for behavior;
[Update Internals](update-internals.md) for mechanics.

| Key | Default | Description |
|---|---|---|
| `mode` | `prompt` | Login-check behavior: `prompt` \| `auto` \| `background` \| `reminder` \| `disabled`. |
| `frequency` | `3600` | Seconds between login checks (also gates self-update; env fallback `UPDATE_DOTFILE_SECONDS`). |
| `release-channel` | `release` | Round 2 targets: `release` (semver-tagged commits only) \| `any` (branch tip). |
| `branch` | _(empty)_ | Explicit Round 2 branch override — actively checked out when set. |
| `in-tree-commit` | `auto` | Pointer/marker recording after component updates: `auto` \| `prompt` \| `none`. |
| `subtree-remote` | _(empty)_ | Subtree topology: `'<remote>'` or `'<remote> <branch>'`. **Required** for subtree self-update detection. |
| `subtree-url` | _(empty)_ | Remote URL override for subtree pulls. |
| `verbose` | `default` | Set `silent` to pass `-q` to the login-triggered update run. |

Component scopes mirror these keys — e.g. `':zdot:update' branch`,
`release-channel` for zdot, or `':my-component:update'` for your own hooks.

OMZ compatibility: when `':dotfiler:update' mode` is unset, `':omz:update'
mode` is consulted, then the legacy `DISABLE_UPDATE_PROMPT=true` (→ `auto`)
and `DISABLE_AUTO_UPDATE=true` (→ `disabled`) env vars.

## Hooks — `:dotfiler:hooks`

| Key | Default | Description |
|---|---|---|
| `dir` | `$XDG_CONFIG_HOME/dotfiler/hooks` | Directory scanned for component update hooks ([Update Hooks](update-hooks.md)). |

## The exclusions file

gitignore-style patterns deciding which files are skipped during
auto-ingest and unpack. Default location: `dotfiles_exclude` in the repo
root (copy the shipped example to start).

```
.git/              # never track version control internals
.nounpack/         # never track dotfiler itself
dotfiles_exclude   # never track the exclusion file
node_modules/
.DS_Store
*.swp
```

Pattern types: trailing `/` matches a directory and its contents; a pattern
containing `/` matches the full relative path; a bare name matches the
filename anywhere; shell globs apply. Exclusions are the authoritative gate
for what gets unpacked — files under `.nounpack/` are never included.

## Environment variables

| Variable | Description |
|---|---|
| `DOTFILER_VERBOSE` | Progress output from the update machinery. |
| `DOTFILER_DEBUG` | Debug tracing (implies verbose). |
| `GH_TOKEN` / `GITHUB_TOKEN` | Authenticated GitHub API requests for update checks (raises rate limits). |
| `UPDATE_DOTFILE_SECONDS` | Fallback for `':dotfiler:update' frequency`. |
| `INSTALL_PROFILE` | Install profile for `dotfiler install` (default `full`). |
| `FORCE_INSTALL` | Set automatically by `install --force`; read by install modules. |
