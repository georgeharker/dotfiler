# dotfiler CLI Reference

```
dotfiler <command> [options...]
```

Every command also accepts `-h`/`--help`. Tab completion for all commands
and flags is provided by `completions.zsh` (see the
[README](../README.md#shell-completions)).

## Quick reference

| Command | Purpose |
|---------|---------|
| [`setup`](#setup) | Track, link, and unpack dotfiles |
| [`check-updates`](#check-updates) | Check for upstream changes |
| [`update`](#update) | Pull updates and re-link |
| [`update-self`](#update-self) | Update dotfiler's own scripts |
| [`install`](#install) / [`install-module`](#install-module) | Bootstrap a machine with install modules |
| [`gui`](#gui) | Terminal UI for tracking/managing files |
| [`ingest` / `add` / `commit` / `status` / `push`](#git-wrappers) | Transparent git wrappers for the dotfiles repo |

---

## setup

Track and link dotfiles (`setup.zsh` / `setup_core.zsh`).

| Flag | Long form | Description |
|------|-----------|-------------|
| `-s` | `--setup` | Auto-ingest dotfiles found under `~/` |
| `-i file …` | `--ingest file …` | Track the listed files and create symlinks (≥ 1 file) |
| `-u [file …]` | `--unpack [file …]` | Create/restore symlinks for the listed files, or everything if none given (respects exclusions) |
| `-U [file …]` | `--force-unpack [file …]` | Same as `-u` but ignores exclusions |
| `-t file …` | `--track file …` | Track without creating a symlink (≥ 1 file) |
| `-x file …` | `--untrack file …` | Untrack (≥ 1 file) |
| `-d [file …]` | `--diff [file …]` | Read-only: report how repo files relate to home (linked / identical / missing / differing, with unified diffs); no changes made |
| `-D` | `--dry-run` | Show what would happen without doing it |
| `-q` | `--quiet` | Suppress non-error output |
| `-g` | `--debug` | Debug tracing |
| `-y` / `-n` | `--yes` / `--no` | Default answer to all prompts |

Exactly one action flag may be given per invocation; every file argument
(shell globs included) belongs to that action.

Path arguments to `-i`/`-t`/`-x` resolve like normal shell paths (absolute, or
relative to the current directory). `-u`/`-U` arguments may name the file
either by where it lands (absolute under `~`, home-relative from anywhere, or
relative to a current directory inside `~`) or by where it lives in the
repo (absolute or cwd-relative under the dotfiles directory) — all four
spellings resolve to the same link.
| `-C name` | `--component name` | Operate on one registered hook component (repeatable) |
| | `--list-components` | List registered components |
| | `--bootstrap` | Fresh-machine mode: initializes submodules (`--init --recursive`), reads hooks from the repo, implies `-u` |
| | `--bootstrap-hook <file>` | Install a hook symlink into the dotfiles repo |

```zsh
dotfiler setup -i ~/.zshrc ~/.gitconfig  # track and link specific files
dotfiler setup -u                        # restore all symlinks
dotfiler setup -u -D                     # dry run
dotfiler setup --bootstrap               # fresh machine: unpack everything
dotfiler setup -u --component zdot       # unpack one component
```

## check-updates

Run the update check now (`check_update.zsh` — normally sourced at login;
see [How Updates Work](how-updates-work.md)).

| Flag | Long form | Description |
|------|-----------|-------------|
| `-f` | `--force` | Ignore the frequency timestamp |
| `-v` | `--verbose` | Show progress output |
| `-d` | `--debug` | Debug tracing (implies verbose) |

## update

Pull updates and re-link (`update.zsh`). Default mode: fetch → plan → pull →
unpack → post, across both rounds (see
[How Updates Work](how-updates-work.md#two-rounds-of-four-phases)).

| Flag | Long form | Description |
|------|-----------|-------------|
| `-q` | `--quiet` | Suppress non-error output |
| `-v` | `--verbose` | Verbose output |
| `-d` | `--debug` | Debug tracing |
| `-f` | `--force` | Force even if the timestamp is recent |
| `-D` | `--dry-run` | Plan only — print what would change, touch nothing |
| `-c hash` | `--commit-hash hash` | Replay one commit's file changes into `$HOME` (manual use; no pull) |
| `-r range` | `--range range` | Replay an arbitrary revision range (manual use; no pull) |
| | `--update-phases <p>` | Restrict to `dotfiles`, `hooks`, or `dotfiler` (repeatable; default: all) |

## update-self

Update dotfiler's own scripts — equivalent to
`dotfiler update --update-phases dotfiler`. Accepts `-f`, `-q`, `-v`, `-D`.

## install

Run all install modules in order (`install.zsh`; see
[Authoring Install Files](authoring-install-files.md)).

| Flag | Long form | Description |
|------|-----------|-------------|
| `-f` | `--force` | Re-install even if already present (sets `FORCE_INSTALL=1`) |
| `-p name` | `--profile name` | Select the install profile (also: `INSTALL_PROFILE=name`; default `full`) |

## install-module

Run one install module by name: `dotfiler install-module <name> [--force]`.

```zsh
dotfiler install-module shell-utils
dotfiler install-module shell-utils --force
INSTALL_PROFILE=minimal dotfiler install
```

## gui

Terminal UI for browsing, tracking, and managing files
(`pip install -r requirements.txt` first). Options: `--dotfiles-dir <dir>`,
`--setup-script <file>`.

- **Add Mode** — browse the filesystem and track config files
- **Manage Mode** — view status (linked, broken, conflicted) of tracked files
- **Batch operations** — select multiple files for tracking or unlinking

Controls: `↑↓←→` navigate, `Space`/`Enter` select, `I` track, `F` file
info, `Q` quit.

## Git wrappers

Transparent wrappers around git in the dotfiles repo — each prints the
underlying git command it runs:

```zsh
dotfiler ingest ~/.zshrc           # move a homedir file into the repo and symlink back
dotfiler add .zshrc                # git add
dotfiler commit -m "Update zshrc"  # git commit (options pass through)
dotfiler status [--fetch]          # working tree + ahead/behind (--fetch checks the network)
dotfiler push                      # git push (options pass through)
```
