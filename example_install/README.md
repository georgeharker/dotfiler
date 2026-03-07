# Modular Install System

This directory contains the modular installation system for dotfiles. Each script handles a specific category of installations and can be run independently or as part of the main installation process.

## Structure

- `helpers.sh` - Common helper functions used by all modules
- `00-dotfiler-install.sh` - Install dotfiler command to ~/bin
- `01-package-manager.sh` - Package manager setup (Homebrew/APT) and fonts
- `02-shell-utils.sh` - Shell environment tools (eza, fzf, zoxide, antidote)
- `03-development-tools.sh` - Core development tools (git, delta, cmake)
- `04-editors-terminals.sh` - Editors, terminals, and shell enhancements (tmux, neovim)
- `05-programming-languages.sh` - Language-specific environments (Python, Rust, Node.js)
- `06-applications.sh` - Specific applications (1Password, tailscale)
- `07-post-install.sh` - Post-installation configuration

## Usage

### Full Installation
Run the main script from the root directory:
```bash
./install.sh
```

### Individual Module Installation
You can run individual modules by name:
```bash
./install_module.sh package-manager
./install_module.sh development-tools
./install_module.sh editors-terminals
# etc.
```

### Force Installation

All install commands support a `-f` or `--force` flag to reinstall components:

```bash
# Force reinstall all modules
../install.sh --force

# Force reinstall specific module
../install_module.sh development-tools --force
```

When `--force` is not specified, installation scripts will skip items that are already installed, making subsequent runs fast and safe.

## Conditional Installation System

The installation system uses smart conditional logic to avoid unnecessary work:

- **Normal mode**: Checks if packages/commands already exist before installing
- **Force mode**: Bypasses checks and reinstalls everything (uses appropriate reinstall commands)
- **Cross-platform**: Automatically detects macOS vs Linux and uses appropriate package managers
- **Dependency handling**: Ensures prerequisites are installed before dependent packages

### How It Works

1. Each installer function calls a `check_*()` function first
2. Check functions return `false` (should install) if:
   - Item is not installed, OR
   - Force mode is enabled (`--force` flag)
3. When force mode is active, installers use appropriate reinstall commands:
   - `brew reinstall` instead of `brew install`
   - `cargo install -f` instead of `cargo install`
   - `uv pip install --reinstall` instead of `uv pip install`

### Example Flow

```bash
# Normal run - skips if ripgrep exists
./install_module.sh shell-utils
# Output: "ripgrep already installed"

# Force run - reinstalls even if exists
./install_module.sh shell-utils --force
# Output: "Installing cargo package: ripgrep" (runs cargo install -f)
```

## Architecture Detection

The system automatically detects whether it's running on macOS or Linux and adjusts installation methods accordingly:

- **macOS**: Uses Homebrew for package management
- **Linux**: Uses APT for package management, builds some tools from source

## Helper Functions

The `helpers.sh` file provides a comprehensive set of functions for building reliable, cross-platform installation modules with intelligent conditional installation.

### Core System Functions

- `detect_os()` - Sets `DOTFILES_OS` environment variable (Darwin/Linux)
- `force_install()` - Returns true if `--force` flag was specified
- `print_section(text)` - Print major section headers
- `print_subsection(text)` - Print minor section headers

### Package Management

#### Basic Package Installation
- `install_package [--cask] package1 [package2 ...]` - Universal package installer
  - macOS: Uses Homebrew (`brew install` / `brew install --cask`)
  - Linux: Uses APT (`apt-get install`)
  - Respects force mode (uses `reinstall` commands when forced)
- `package_installed package` - Check if package is installed
- `check_package package` - Conditional check (respects force mode)

#### Command-based Installation
- `command_exists command` - Check if command is available in PATH
- `check_command command` - Conditional check (respects force mode)

### Language-Specific Installers

#### Node.js and NPM
- `ensure_nodejs()` - Install Node.js if needed
- `install_npm_package package` - Install npm package globally
- `npm_package_installed package` - Check if npm package is installed
- `check_npm_package package` - Conditional check (respects force mode)

#### Python and UV
- `ensure_uv()` - Install UV Python package manager
- `ensure_python3()` - Install Python 3 via UV
- `ensure_global_python_venv()` - Create ~/.venv if needed
- `activate_global_python_venv()` - Activate ~/.venv
- `activate_global_or_local_python_venv()` - Activate local venv if available, otherwise global
- `pip_install package1 [package2 ...]` - Install Python packages via UV
- `pip_packages_installed package1 [package2 ...]` - Check if packages are installed
- `check_pip_packages package1 [package2 ...]` - Conditional check (respects force mode)

#### Rust and Cargo
- `ensure_rust()` - Install Rust toolchain if needed
- `install_cargo_package package` - Install Cargo package (with .deb fallback on Linux)
- `cargo_crate_installed package` - Check if cargo crate is installed
- `check_cargo_crate package` - Conditional check (respects force mode)

### Git-based Installation

- `ensure_git()` - Install git and git-lfs if needed
- `install_using_git name repo_url dest_dir [post_install_func]` - Clone git repository
  - Skips if directory exists (unless force mode)
  - Creates parent directories automatically
  - Runs optional post-install function after cloning
- `git_directory_exists dir` - Check if directory is a git repository
- `check_git_directory dir` - Conditional check (respects force mode)

### System Dependencies

#### Platform-specific
- `ensure_homebrew()` - Install Homebrew if needed (macOS only)
- `ensure_deb_packages()` - Clone custom Debian package repository
- `install_deb_package package` - Install custom .deb package (Linux only)

### Conditional Installation Logic

All `check_*()` functions follow the same pattern:

```bash
check_something() {
    if force_install; then
        return 1  # Should install (force mode)
    fi
    something_installed "$1"  # Check actual state
}
```

This ensures:
- Normal mode: Only install if not present
- Force mode: Always install (with appropriate reinstall commands)

### Best Practices for Install Scripts

1. **Always check before installing**: Use `check_*()` functions
2. **Handle dependencies**: Use `ensure_*()` functions for prerequisites
3. **Provide feedback**: Use `action()`, `info()`, and `error()` logging functions
4. **Cross-platform support**: Use helper functions instead of direct package manager calls

```bash
# Example installation function
install_ripgrep() {
    action "Installing ripgrep..."
    if ! check_command rg; then
        if [[ "$DOTFILES_OS" == "Darwin" ]]; then
            install_package ripgrep
        else
            install_cargo_package ripgrep
        fi
    else
        info "ripgrep already installed"
    fi
}
```

### Force Mode Behavior

When `--force` is specified:

| Function | Normal Command | Force Command |
|----------|---------------|---------------|
| `install_package` | `brew install pkg` | `brew reinstall pkg` |
| `install_npm_package` | `npm install -g pkg` | `npm install -f -g pkg` |
| `install_cargo_package` | `cargo install pkg` | `cargo install -f pkg` |
| `pip_install` | `uv pip install pkg` | `uv pip install --reinstall pkg` |
| `install_using_git` | Skip if exists | Remove and re-clone |

## Customization

Each module is self-contained and can be modified independently. The modular structure makes it easy to:

1. Add new installation categories
2. Modify existing installations without affecting others
3. Skip certain modules if not needed
4. Test individual components

## Order

The modules are numbered to ensure consistent installation order across architectures:

1. Package managers must be installed first
2. Development tools provide the foundation
3. Editors and terminals build on development tools
4. Programming languages add specific environments
5. Applications add end-user tools
6. Post-install handles configuration that depends on everything else
