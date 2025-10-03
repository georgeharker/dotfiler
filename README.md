# Dotfiler

A comprehensive dotfiles management system with automatic updates, git integration, modular installation, and both command-line and GUI interfaces.

## Quick Start

```bash
# Add as git subtree to your dotfiles repository
git subtree add --prefix=.nounpack/scripts \
    https://github.com/your-username/dotfiler.git main --squash
chmod +x .nounpack/scripts/dotfiler

# Track and link dotfiles
.nounpack/scripts/dotfiler setup -i ~/.bashrc ~/.vimrc ~/.gitconfig
.nounpack/scripts/dotfiler setup -u

# Enable automatic updates (optional)
echo 'source ~/.dotfiles/.nounpack/scripts/check_update.sh' >> ~/.zshrc
```

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
# Copy templates and customize
cp -r .nounpack/scripts/example_install/ .nounpack/scripts/install/
vim .nounpack/scripts/install/02-development-tools.sh

# Run installation  
.nounpack/scripts/install.sh                        # All modules
.nounpack/scripts/install_module.sh development-tools  # Specific module
```

Available modules:
- `install/helpers.sh` - Common functions for all modules
- `install/01-package-manager.sh` - Package managers and fonts
- `install/02-development-tools.sh` - Development tools (git, fzf, ripgrep)  
- `install/03-editors-terminals.sh` - Editors and shell enhancements
- `install/04-programming-languages.sh` - Language runtimes and tools
- `install/05-applications.sh` - End-user applications
- `install/06-post-install.sh` - Final configuration and cleanup

**Note**: Copy templates from `example_install/` to `install/` before customizing.

## Configuration Options (zstyle)

```bash
# Directory and update settings
zstyle ':dotfiles:directory' path '/path/to/dotfiles'
zstyle ':dotfiles:scripts' directory '/path/to/scripts'     # Custom script location
zstyle ':dotfiles:install' directory '/path/to/install'     # Custom install modules location
zstyle ':dotfiles:update' mode 'auto|prompt|reminder|disabled'
zstyle ':dotfiles:update' frequency 86400  # seconds

# Shell integration - add to .zshrc/.bashrc
[[ -f ~/.dotfiles/.nounpack/scripts/check_update.sh ]] && source ~/.dotfiles/.nounpack/scripts/check_update.sh
```

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
