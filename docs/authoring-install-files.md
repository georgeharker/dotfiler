# Authoring Install Files

Install files are numbered zsh scripts that run when you provision a new machine
with `dotfiler install`. They live in your dotfiles repo alongside your config
files, numbered to control execution order.

## File Naming

```
00-dotfiler-install.zsh   # always first — bootstraps dotfiler itself
01-package-manager.zsh
02-shell-utils.zsh
03-development-tools.zsh
...
08-post-install.zsh       # always last — post-install messages
```

Files are sourced in lexicographic order. Use two-digit prefixes so ordering is
unambiguous.

## Module Structure

Each file must define three variables and one function:

```zsh
#!/bin/zsh
module_name="my-tools"
module_description="Install my development tools"

function run_my_tools_module() {
    # installation logic here
}
```

The function name must be `run_<module_name>_module` with hyphens replaced by
underscores. `dotfiler install` discovers and calls it automatically.

## Available Functions

The full helper API is available automatically — you do not need to source
`helpers.zsh` yourself. `dotfiler install` loads it before any module runs.

### Output / Logging

```zsh
action "Installing foo..."    # blue — action being taken
info   "foo is already installed"  # plain — informational
success "foo installed"       # green — success
warn   "foo not found, skipping"   # yellow stderr — non-fatal
error  "foo install failed"   # red stderr — fatal
```

### OS Detection

`DOTFILES_OS` is set automatically before any module runs — you do not need to
call `detect_os` yourself. Its value is either `Darwin` (macOS) or `Linux`.

```zsh
if [[ "$DOTFILES_OS" = "Darwin" ]]; then
    # macOS-specific
fi
```

### Profile Support

Profiles let you maintain one install script that behaves differently across
machines (e.g. work vs personal, laptop vs server):

```zsh
# Only run on the 'full' or 'work' profiles
check_profile full work || return 0

# Check what profile is active
echo "Profile: ${INSTALL_PROFILE:-full}"
```

Set the profile before running:

```zsh
INSTALL_PROFILE=minimal dotfiler install
```

### Force Re-install

```zsh
# Skip if already installed, unless --force was passed to dotfiler install
if ! force_install && command -v foo &>/dev/null; then
    info "foo already installed"
    return 0
fi
```

`force_install` returns true when `dotfiler install --force` (or `-f`) was used.
`FORCE_INSTALL` is set automatically by dotfiler — you do not need to set it
yourself.

### Deferred Instructions

Queue a message to be printed after all modules complete:

```zsh
add_final_instruction "Restart your shell to activate foo"
```

## Typical Module Pattern

```zsh
#!/bin/zsh
module_name="my-tools"
module_description="Install my development tools"

function run_my_tools_module() {
    print_section "My Tools"

    # Skip if already present
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

## Section Headings

Use `print_section` and `print_subsection` to visually group output:

```zsh
print_section "Development Tools"
print_subsection "Languages"
```

## The `00-dotfiler-install.zsh` Convention

Your first module should always bootstrap dotfiler itself — ensuring the `dotfiler`
command is on `$PATH` before subsequent modules rely on it. See
`example_install/00-dotfiler-install.zsh` for a reference implementation.

## Running Install

```zsh
dotfiler install              # run all modules
dotfiler install --force      # re-run even if already installed (sets FORCE_INSTALL=1)
dotfiler install -f           # shorthand for --force
INSTALL_PROFILE=work dotfiler install
```

See `example_install/` in the dotfiler repo for a complete working example.
