# How Updates Work

## From a User Perspective

dotfiler monitors your dotfiles repository for upstream changes and either
notifies you or applies updates automatically, depending on how it is configured.

### Setting Up Automatic Checks

Add the following to your shell rc file (e.g. `.zshrc`) to enable update checks
at login:

```zsh
# In ~/.zshrc (or your dotfiles' shell init):
if command -v dotfiler &>/dev/null; then
    source "$(dotfiler scripts-dir)/check_update.zsh"
fi
```

If you use zdot, this is handled automatically by the `dotfiler.zsh` zdot plugin
— no manual wiring needed.

### The Update Check

At shell startup, dotfiler runs a lightweight check:

1. Fetches from the configured remote
2. Compares the local HEAD to the remote
3. If updates are available, either prompts you or applies them silently,
   depending on the configured mode

You can also trigger a check manually:

```zsh
dotfiler check-updates          # check now
dotfiler check-updates --force  # ignore the frequency throttle
dotfiler check-updates --verbose # show progress output
dotfiler check-updates --debug  # show full tracing (implies --verbose)
```

### Update Modes

Controlled via zstyle, typically set in your dotfiles init:

```zsh
zstyle ':dotfiler:update' mode prompt     # ask before updating (default)
zstyle ':dotfiler:update' mode background # update silently in background
zstyle ':dotfiler:update' mode disabled   # no automatic updates
```

**`prompt`** — the most common choice. At shell startup, if updates are available
you are shown a prompt and can accept or defer. Updates run interactively so you
see what changed.

**`background`** — updates apply silently. Output is captured and stored with the
timestamp. Good for machines where you don't want shell startup interrupted.

**`disabled`** — no automatic checks. Run `dotfiler check-updates` manually when
you want to update.

### Update Frequency

To avoid checking on every shell open, dotfiler throttles checks using a
timestamp file. The default is once per day. Override with:

```zsh
zstyle ':dotfiler:update' frequency 43200  # seconds — 12 hours
```

Force a check regardless of the timestamp with `--force`.

### What Happens During an Update

1. The main dotfiles repo is pulled from the configured remote
2. Any registered component hooks (e.g. a zdot hook) run their own update logic
3. If the repo contains a submodule or subtree (e.g. dotfiler itself), those are
   updated too
4. A new timestamp is written on success

---

## Deployment Techniques and Tradeoffs

dotfiler supports three ways to be included in your dotfiles repo. The choice
affects how dotfiler itself is updated and how portable your setup is.

### 1. Git Submodule

```zsh
# GitHub
git submodule add https://github.com/georgeharker/dotfiler .nounpack/dotfiler

# Self-hosted / SSH
git submodule add git@your-host:dotfiler.git .nounpack/dotfiler
```

**How it works:** dotfiler is pinned to a specific commit inside your dotfiles
repo. Running `dotfiler update` (or the auto-update mechanism) fetches the
submodule remote and advances the pin.

**Tradeoffs:**

| | |
|---|---|
| ✓ | Explicit versioning — you control exactly which dotfiler commit is active |
| ✓ | Updates are atomic — submodule update + parent commit are a unit |
| ✓ | Easy to roll back by checking out an older parent commit |
| ✗ | Slightly more complex clone (`git clone --recurse-submodules`) |
| ✗ | New machines need `git submodule update --init` |

**Best for:** Most users. Gives you reproducible, versioned tooling with a clear
update trail.

### 2. Git Subtree

```zsh
# GitHub
git subtree add --prefix=.nounpack/dotfiler \
    https://github.com/georgeharker/dotfiler main --squash

# Self-hosted / SSH
git subtree add --prefix=.nounpack/dotfiler \
    git@your-host:dotfiler.git main --squash
```

**How it works:** dotfiler's source is merged directly into your repo history.
No `.gitmodules` file, no separate clone step needed.

**Tradeoffs:**

| | |
|---|---|
| ✓ | Single repo — cloning your dotfiles gives you everything |
| ✓ | No submodule init step on new machines |
| ✓ | Full history of dotfiler available locally |
| ✓ | You can make local patches and merge upstream selectively |
| ✗ | Your repo history gets dotfiler commits merged in |
| ✗ | Pulling updates requires a `git subtree pull` command |

**Best for:** Users who want the simplest clone story; or who are developing
dotfiler itself and need to work against a local fork; or who want to carefully
review every change to their tooling before it lands in their setup.

### 3. Standalone (Pre-installed)

dotfiler is installed separately on each machine (e.g. via a package manager or
manual clone), and your dotfiles repo just calls it by name.

**Tradeoffs:**

| | |
|---|---|
| ✓ | Your dotfiles repo is purely config — no tooling bundled |
| ✓ | dotfiler can be updated independently of your dotfiles |
| ✗ | Requires dotfiler to be installed before your dotfiles can be bootstrapped |
| ✗ | New machine setup has an extra manual step |

**Best for:** Advanced users who manage machine provisioning separately (e.g.
via Ansible or a corporate IT image).

### Recommendation

Use **submodule** unless you have a specific reason not to. It gives the best
balance of reproducibility and update control with minimal operational overhead.
