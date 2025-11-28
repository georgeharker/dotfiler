# Dotfiler

A comprehensive zsh based dotfiles management system with automatic updates, git integration, modular installation, and both command-line and GUI interfaces.

## Quick Start

```bash
# Add as git subtree to your dotfiles repository
git subtree add --prefix=.nounpack/scripts \
    https://github.com/your-username/dotfiler.git main --squash
chmod +x .nounpack/scripts/dotfiler

# Track and link dotfiles
.nounpack/scripts/dotfiler setup -i ~/.bashrc ~/.vimrc ~/.gitconfig
.nounpack/scripts/dotfiler setup -u

# Set up exclusions (recommended)
cp .nounpack/scripts/dotfiles_exclude ./

# Enable automatic updates (optional)
echo 'source ~/.dotfiles/.nounpack/scripts/check_update.sh' >> ~/.zshrc
```
# Enable shell completions (optional)
echo 'source ~/.dotfiles/.nounpack/scripts/completions.zsh' >> ~/.zshrc

## Installation

### Git Subtree Integration (Recommended)

```bash
cd ~/.dotfiles
git subtree add --prefix=.nounpack/scripts \
    https://github.com/your-username/dotfiler.git main --squash
chmod +x .nounpack/scripts/dotfiler
```

Updates:
```bash
git subtree pull --prefix=.nounpack/scripts \
    https://github.com/your-username/dotfiler.git main --squash
```

## Main Commands

```bash
# Track and manage dotfiles
dotfiler setup -i ~/.bashrc ~/.vimrc     # Track files
dotfiler setup -u                        # Create symlinks  
dotfiler setup -t .old-config            # Remove from tracking

# Updates and GUI
dotfiler update                          # Update from git
dotfiler check_update -f                 # Force update check
dotfiler gui                             # Launch GUI

# Installation modules
dotfiler install                         # Run full installation
install_module.sh development-tools     # Run specific module
```

## Modular Installation System

Set up development environments with modular components:

```bash
# Copy templates and customize (if needed)
cp -r .nounpack/scripts/example_install/ .nounpack/scripts/install/
vim .nounpack/scripts/install/02-shell-utils.sh

# Run installation  
.nounpack/scripts/install.sh                        # All modules
.nounpack/scripts/install_module.sh shell-utils     # Specific module
```

Available modules:
- `install/00-dotfiler-install.sh` - Install dotfiler command to ~/bin
- `install/01-package-manager.sh` - Package managers and fonts
- `install/02-shell-utils.sh` - Shell environment tools (eza, fzf, zoxide, antidote)
- `install/03-development-tools.sh` - Development tools (git, delta, cmake)
- `install/04-editors-terminals.sh` - Editors and shell enhancements (tmux, neovim)
- `install/05-programming-languages.sh` - Language runtimes and tools
- `install/06-applications.sh` - End-user applications
- `install/07-post-install.sh` - Final configuration and cleanup

**See `install/README.md` for detailed documentation of the installation system and helper functions.**

**Note**: Copy templates from `example_install/` to `install/` before customizing.

### Force Installation

All install commands support a `-f` or `--force` flag to reinstall components:

```bash
# Force reinstall all modules
.nounpack/scripts/install.sh --force

# Force reinstall specific module
.nounpack/scripts/install_module.sh shell-utils --force
```

When `--force` is not specified, installation scripts will skip items that are already installed, making subsequent runs fast and safe.

## Configuration Options (zstyle)

```bash
# Directory and update settings
zstyle ':dotfiles:directory' path '/path/to/dotfiles'
zstyle ':dotfiles:scripts' directory '/path/to/scripts'     # Custom script location, may be relative to dotfiles:directory
zstyle ':dotfiles:install' directory '/path/to/install'     # Custom install modules location, may be relative to dotfiles:directory
zstyle ':dotfiles:exclude' path '/path/to/exclude/file'    # Override exclusions file (default: dotfiles_exclude), may be relative to dotfiles:directory
zstyle ':dotfiles:update' mode 'auto|prompt|reminder|disabled'
zstyle ':dotfiles:update' frequency 86400  # seconds

# Shell integration - add to .zshrc/.bashrc
[[ -f ~/.dotfiles/.nounpack/scripts/check_update.sh ]] && source ~/.dotfiles/.nounpack/scripts/check_update.sh
```

## Shell Completions

Dotfiler includes zsh completions for tab completion of commands and options.

### Enable Completions

Add to your `.zshrc`:

```bash
# Enable dotfiler completions
source ~/.dotfiles/.nounpack/scripts/completions.zsh
```

### Completion Features

The completions provide:

- **Command completion**: `dotfiler <TAB>` shows available commands (gui, setup, check_update, update)
- **Option completion**: `dotfiler setup -<TAB>` shows available options with descriptions
- **File completion**: Options like `-i`, `-u`, `-t` provide intelligent file completion
- **Help integration**: All completions include help text for options

### Examples

```bash
dotfiler <TAB>                    # Lists: gui, setup, check_update, update
dotfiler setup -<TAB>             # Shows: -i, -s, -u, -U, -t, -d, -q, -D, -y, -n
dotfiler setup -i <TAB>           # File completion for tracking
dotfiler check_update --<TAB>     # Shows: --force, --debug, --help
```

## File Exclusions

Dotfiler uses exclusion patterns to prevent tracking certain files and directories. The exclusion system supports gitignore-style patterns.

### Default Exclusion File

By default, exclusions are read from `dotfiles_exclude` in your dotfiles directory:

```bash
# Example dotfiles_exclude file
.git/                    # Version control
.nounpack/              # Dotfiler system files
dotfiles_exclude       # Exclude the exclusion file itself
node_modules/           # Dependencies
.vscode/                # IDE files
*.swp                   # Temporary files
.DS_Store              # System files
.codecompanion/*       # Progress tracking files
```

**Important**: Copy `dotfiles_exclude` to your dotfiles root directory and ensure it includes `dotfiles_exclude` in its patterns to prevent tracking the exclusion file itself.

```bash
# Copy exclusion file to dotfiles root
cp .nounpack/scripts/dotfiles_exclude ~/.dotfiles/
```

### Custom Exclusion File

Override the exclusion file location using zstyle:

```bash
# Use custom exclusion file
zstyle ':dotfiles:exclude' path '/path/to/my-exclusions.txt'
```

### Pattern Types

- **Directory patterns**: End with `/` (e.g., `node_modules/`)
- **Path patterns**: Contain `/` (e.g., `.git/hooks/pre-commit`)
- **Name patterns**: No `/` (e.g., `*.swp`, `.DS_Store`)
- **Glob patterns**: Use standard shell wildcards

The exclusion system processes both directory names and their contents, so `node_modules/` excludes both the directory and all files within it.

## GUI Application

```bash
# Install dependencies and run
pip install -r .nounpack/scripts/requirements.txt
.nounpack/scripts/dotfiler gui
```

Features:
- **Add Mode**: Browse filesystem and track configuration files
- **Manage Mode**: View status of tracked files, handle conflicts
- **File Status**: Visual indicators for linked, broken, or conflicted files
- **Batch Operations**: Select multiple files for tracking or unlinking

Controls:
- `↑↓←→`: Navigate  
- `Space/Enter`: Select files
- `I`: Track selected files
- `F`: Show detailed file info
- `Q`: Quit

## Directory Structure

```
~/.dotfiles/
├── .nounpack/scripts/     # Dotfiler system (git subtree)
│   ├── dotfiler          # Main command
│   ├── setup.sh          # File management
│   ├── update.sh         # Git operations
│   ├── install/          # Active modules (customized)
│   └── example_install/  # Template modules
├── .bashrc              # Your tracked dotfiles
├── .vimrc
└── .config/
    └── nvim/init.lua
```

## Basic Workflows

```bash
# New machine setup
git clone <your-repo> ~/.dotfiles && cd ~/.dotfiles
chmod +x .nounpack/scripts/dotfiler .nounpack/scripts/*.sh
.nounpack/scripts/dotfiler setup -u

# Track new config file
.nounpack/scripts/dotfiler setup -i ~/.config/newsoftware/config.toml
git add -A && git commit -m "Add newsoftware config"

# Edit existing config (changes go directly to dotfiles via symlink)
vim ~/.vimrc
git add .vimrc && git commit -m "Update vim config"
```

## Troubleshooting

```bash
# Make scripts executable
chmod +x ~/.dotfiles/.nounpack/scripts/dotfiler ~/.dotfiles/.nounpack/scripts/*.sh

# Check git status  
cd ~/.dotfiles && git status

# Force update check
.nounpack/scripts/dotfiler check_update -f

# Debug symlink issues
.nounpack/scripts/dotfiler setup -u  # Recreate symlinks
```

---

This system provides automated dotfiles management with git integration, modular installations, and both CLI and GUI interfaces. The git subtree approach ensures your dotfiles repository is self-contained and works offline.
