# Authoring Install Files

Install files are numbered zsh scripts that run when you provision a new
machine with `dotfiler install`. They live in your dotfiles repo
(`.nounpack/install/` by default — configurable via
`zstyle ':dotfiles:install' path`) alongside your config files, numbered to
control execution order.

The fastest start is copying the shipped example and editing:

```zsh
cp -r .nounpack/dotfiler/example_install/ .nounpack/install/
```

## File Naming

```
00-dotfiler-install.zsh   # always first — bootstraps dotfiler itself
01-package-manager.zsh
02-shell-utils.zsh
...
09-post-install.zsh       # always last — post-install messages
```

Files are sourced in lexicographic order. Use two-digit prefixes so ordering
is unambiguous, keep dotfiler bootstrap first, and post-install messages
last.

## Module Structure

Each file defines three variables and one function:

```zsh
#!/bin/zsh
module_name="my-tools"
module_description="Install my development tools"
module_main_function="run_my_tools_module"

function run_my_tools_module() {
    # installation logic here
}
```

`module_main_function` names the entry point `dotfiler install` calls. It
can technically be omitted — the fallback derives
`run_<filename>_module` from the *file* name (hyphens → underscores) — but
since install files carry numeric prefixes, the derived name would be
`run_02_my_tools_module`-style. Set it explicitly, as every shipped example
does.

## Helper Functions: Two Layers

Two distinct sources provide the functions available inside a module — you
never source either yourself:

**Core helpers** are loaded by `dotfiler install` before any module runs,
from dotfiler itself:

- Logging: `action` (blue), `info` (plain), `success` (green), `warn`
  (yellow, stderr), `error` (red, stderr), `verbose` / `log_debug`
  (gated by `DOTFILER_VERBOSE` / `DOTFILER_DEBUG`).
- `DOTFILES_OS` — set automatically before any module runs: `Darwin` or
  `Linux`.
- `add_final_instruction "msg"` — queue a message printed after all modules
  complete.
- `INSTALL_PROFILE` (default `full`) and `FORCE_INSTALL` (set by
  `--force`) — exported automatically.

**Install-dir helpers** come from `helpers.zsh` *inside your install
directory* — it is sourced automatically when present. The example install
ships one, so copying `example_install/` brings along `force_install`,
`check_profile` / `check_profile_not`, `print_section` /
`print_subsection`, `os_is_osx` / `os_is_linux` / `os_is_debian`, and a
library of `ensure_*` / download helpers. These are **yours** — they live
in your repo, and you extend them as your modules need. The full reference
is [example_install/README.md](../example_install/README.md).

If you write an install dir from scratch (without copying the example),
only the core layer is present.

## Profiles

Profiles let one install set behave differently across machines (work vs
personal, laptop vs server):

```zsh
# In a module — only run on the 'full' or 'work' profiles
check_profile full work || return 0
```

```zsh
INSTALL_PROFILE=minimal dotfiler install
dotfiler install --profile minimal      # equivalent
```

## Force Re-install

Modules are idempotent by convention — skip work that's already done unless
the user forced:

```zsh
if ! force_install && command -v foo &>/dev/null; then
    info "foo already installed"
    return 0
fi
```

`force_install` returns true when `dotfiler install --force` (or `-f`) was
used.

## Typical Module Pattern

```zsh
#!/bin/zsh
module_name="my-tools"
module_description="Install my development tools"
module_main_function="run_my_tools_module"

function run_my_tools_module() {
    print_section "My Tools"

    if ! force_install && command -v mytool &>/dev/null; then
        info "mytool already installed"
        return 0
    fi

    action "Installing mytool..."

    if [[ "$DOTFILES_OS" = "Darwin" ]]; then
        brew install mytool || { error "brew install failed"; return 1; }
    else
        sudo apt-get install -y mytool || { error "apt install failed"; return 1; }
    fi

    success "mytool installed"
    add_final_instruction "Configure mytool at ~/.config/mytool/config"
}
```

## Running Install

```zsh
dotfiler install                   # run all modules
dotfiler install --force           # re-run even if already installed
dotfiler install-module my-tools   # run one module by name
INSTALL_PROFILE=work dotfiler install
```

Flags: [CLI Reference → install](commands.md#install).
