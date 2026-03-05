# zdot Integration

dotfiler integrates with [zdot](https://github.com/georgeharker/zdot), a modular
zsh configuration manager, but **does not require it**. dotfiler works with any
shell setup.

---

## What zdot Provides

When used together, zdot and dotfiler form a layered system:

- **dotfiler** manages your dotfiles repo: link-tree unpacking, config file
  ingestion, and keeping the repo up to date
- **zdot** manages your zsh configuration: modular loading of plugins, themes,
  and shell config, all stored inside your dotfiles repo

zdot is itself managed by dotfiler — it lives in your dotfiles repo as a
submodule or subtree, and dotfiler keeps it updated alongside everything else.

---

## How the Integration Works

zdot ships a dotfiler update hook (`dotfiler-hook.zsh`) that registers zdot as
a component with dotfiler's update system. This means:

1. When dotfiler checks for updates, it also checks whether zdot has upstream
   changes
2. When dotfiler applies an update, zdot's files are pulled and unpacked as part
   of the same run
3. zdot's shell init (`update.zsh`) registers a hook that runs at each new shell
   startup to check for updates in the background

The hook is sourced from your dotfiles linktree. dotfiler discovers it via the
configured hooks directory (`$XDG_CONFIG_HOME/dotfiler/hooks/`).

### Environment Variables

The integration uses two sets of environment variables that mirror each other:

| dotfiler | zdot | Purpose |
|----------|------|---------|
| `DOTFILER_VERBOSE` | `ZDOT_VERBOSE` | Enable verbose progress output |
| `DOTFILER_DEBUG` | `ZDOT_DEBUG` | Enable debug tracing (implies verbose) |

Setting either debug var automatically enables verbose output for that system.

---

## Using dotfiler Without zdot

dotfiler requires no zdot-specific code to function. If you use a different shell
configuration manager (or none at all), dotfiler works identically — you simply
won't have the zdot update hook registered.

All of dotfiler's core features are standalone:

- Link-tree unpacking of config files
- Config file ingestion
- Auto-update for your dotfiles repo
- Modular install scripts for new machine setup
- Shell completions

---

## Setting Up the Integration

If you use zdot and want dotfiler to manage it:

1. Add zdot to your dotfiles repo:
   ```zsh
   git submodule add https://github.com/georgeharker/zdot .config/zdot
   ```

2. Ensure your zdot init sources the dotfiler hook. zdot does this automatically
   if you use the standard `dotfiler.zsh` plugin that ships with zdot.

3. Configure the update mode:
   ```zsh
   # In your zdot config
   zstyle ':dotfiler:update' mode prompt
   ```

4. On first run, dotfiler will detect zdot as a submodule and register it with
   the update system automatically.
