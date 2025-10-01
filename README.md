# Dotfiles Management System

A comprehensive shell-based dotfiles management system with automatic updates, git integration, and flexible configuration options.

## Quick Start

```bash
# 1. Fork/clone this repository
git clone https://github.com/your-username/dotfiles.git ~/.dotfiles
cd ~/.dotfiles

# 2. Make scripts executable
chmod +x *.sh

# 3. Add dotfiles to track
./setup.sh -i ~/.bashrc ~/.vimrc ~/.gitconfig

# 4. Create symlinks
./setup.sh -u

# 5. Set up automatic updates (optional)
echo 'source ~/.dotfiles/check_update.sh' >> ~/.zshrc
```

## Table of Contents

- [Installation](#installation)
- [Core Scripts](#core-scripts)
- [Basic Usage](#basic-usage)
- [Advanced Configuration](#advanced-configuration)
- [Automatic Updates](#automatic-updates)
- [Directory Structure](#directory-structure)
- [Configuration Options](#configuration-options)
- [TUI Application](#tui-application)
- [Troubleshooting](#troubleshooting)

## Installation

### 1. Clone the Repository

```bash
# Standard location (recommended)
git clone <your-dotfiles-repo> ~/.dotfiles
cd ~/.dotfiles

# Or use a custom location (see Configuration for zstyle setup)
git clone <your-dotfiles-repo> ~/my-config
```

### 2. Make Scripts Executable

```bash
chmod +x setup.sh update.sh check_update.sh
```

### 3. Configure Shell Integration

Add to your shell configuration file (`.zshrc`, `.bashrc`, etc.):

```bash
# Basic setup - automatic update checking
[[ -f ~/.dotfiles/check_update.sh ]] && source ~/.dotfiles/check_update.sh

# Optional: Configure custom dotfiles location
zstyle ':dotfiles:directory' path '/path/to/your/dotfiles'

# Optional: Configure update behavior
zstyle ':dotfiles:update' mode 'auto'           # auto, prompt, reminder, disabled
zstyle ':dotfiles:update' frequency 86400      # Check every 24 hours (in seconds)
zstyle ':dotfiles:update' verbose 'default'    # default, silent
```

## Core Scripts

### `setup.sh` - Main Management Script

The primary script for managing your dotfiles:

```bash
# Track new files (copy to dotfiles directory)
./setup.sh -i ~/.bashrc ~/.vimrc ~/.config/nvim/init.lua

# Create symlinks for all tracked files
./setup.sh -u

# Create symlinks for specific files only
./setup.sh -u .bashrc .vimrc

# Force unpack files that are normally excluded
./setup.sh -U setup.sh  # Use with caution

# Remove files from tracking
./setup.sh -t .old-config

# Copy dotfiles from home to repository (setup mode)
./setup.sh -s
```

### `update.sh` - Update from Git

Handles git updates and automatically manages file changes:

```bash
# Update from default remote/branch
./update.sh

# Quiet mode
./update.sh -q

# Update from specific commit
./update.sh -c abc1234

# Update from specific range
./update.sh -r HEAD~5..HEAD
```

**What it does:**
- Fetches latest changes from git
- Identifies added, modified, and deleted files
- Automatically creates symlinks for new/changed files
- Removes broken symlinks for deleted files
- Uses smart exclusions (won't symlink management scripts)

### `check_update.sh` - Automatic Update Checker

Provides automatic update notifications and can be sourced in your shell:

```bash
# Manual check
./check_update.sh

# Force check (ignore timestamp)
./check_update.sh -f

# Source in shell for automatic checking
source check_update.sh
```

## Basic Usage

### Setting Up Your First Dotfiles

1. **Track existing configuration files:**
   ```bash
   ./setup.sh -i ~/.bashrc ~/.vimrc ~/.gitconfig
   ```

2. **Create symlinks:**
   ```bash
   ./setup.sh -u
   ```

3. **Commit to git:**
   ```bash
   git add -A
   git commit -m "Add initial dotfiles"
   git push
   ```

### Adding New Files

```bash
# Track a new configuration file
./setup.sh -i ~/.config/alacritty/alacritty.yml

# Create the symlink
./setup.sh -u .config/alacritty/alacritty.yml

# Commit the change
git add -A && git commit -m "Add alacritty config"
```

### Updating an Existing File

When you modify a tracked file:

```bash
# If the file is properly symlinked, changes are automatic
vim ~/.vimrc  # This directly edits ~/.dotfiles/.vimrc

# If you need to re-ingest (file is not symlinked):
./setup.sh -i ~/.vimrc  # Will prompt to update if different
```

### Removing Files

```bash
# Remove from tracking and clean up symlinks
./setup.sh -t .old-config
```

## Advanced Configuration

### Custom Dotfiles Directory

By default, scripts assume `~/.dotfiles`. To use a different location:

```bash
# In your shell configuration (.zshrc, .bashrc):
zstyle ':dotfiles:directory' path '/path/to/your/dotfiles'
```

This affects all three scripts (`setup.sh`, `update.sh`, `check_update.sh`).

### Update Behavior Configuration

```bash
# Update mode options:
zstyle ':dotfiles:update' mode 'auto'        # Automatic updates
zstyle ':dotfiles:update' mode 'prompt'     # Ask before updating (default)
zstyle ':dotfiles:update' mode 'reminder'   # Just show reminder message
zstyle ':dotfiles:update' mode 'disabled'   # No automatic checking

# Update frequency (in seconds):
zstyle ':dotfiles:update' frequency 3600    # Check every hour
zstyle ':dotfiles:update' frequency 86400   # Check daily (default)
zstyle ':dotfiles:update' frequency 604800  # Check weekly

# Verbosity:
zstyle ':dotfiles:update' verbose 'default' # Normal output
zstyle ':dotfiles:update' verbose 'silent'  # Quiet mode
```

## Automatic Updates

### Basic Setup

Add to your `.zshrc` or `.bashrc`:

```bash
# Enable automatic update checking
[[ -f ~/.dotfiles/check_update.sh ]] && source ~/.dotfiles/check_update.sh
```

### Update Modes

- **prompt** (default): Ask before updating
- **auto**: Update automatically without prompting
- **reminder**: Show reminder message only
- **disabled**: No automatic checking

### Manual Force Update

```bash
# Force update check regardless of timing
./check_update.sh -f

# Or run update directly
./update.sh
```

## Directory Structure

```
~/.dotfiles/
├── setup.sh              # Main management script
├── update.sh              # Git update handler  
├── check_update.sh        # Automatic update checker
├── .gitignore             # Git ignore patterns
├── README.md              # This file
├── .nounpack/             # Files excluded from symlinking
│   └── dotfiler/          # TUI application (Python)
│       ├── dotfile_manager.py
│       ├── requirements.txt
│       └── ...
├── .bashrc               # Your tracked dotfiles
├── .vimrc
├── .gitconfig
└── .config/
    ├── nvim/
    │   └── init.lua
    └── alacritty/
        └── alacritty.yml
```

### Special Directories

- **`.nounpack/`**: Files here are never symlinked to home directory
- **`.git/`**: Git repository data (excluded from symlinking)
- **Management scripts**: `setup.sh`, `update.sh`, etc. (excluded from symlinking)

## Configuration Options

### Exclusions

Files automatically excluded from symlinking:
- Management scripts (`setup.sh`, `update.sh`, `check_update.sh`)
- Git directory (`.git/`)
- No-unpack directory (`.nounpack/`)
- Temporary files (`*.swp`, `*.swo`, `.DS_Store`)

### Override Exclusions

```bash
# Force symlink normally excluded files (use with caution)
./setup.sh -U some-script.sh
```

### Git Integration

The system integrates with git automatically:
- `setup.sh -i` stages new files
- `update.sh` pulls changes and manages symlinks
- Remote and branch detection is automatic

## TUI Application

A Python-based graphical interface is available in `.nounpack/dotfiler/`:

```bash
cd ~/.dotfiles/.nounpack/dotfiler
pip install -r requirements.txt
python dotfile_manager.py
```

**Features:**
 
 ### Installing the TUI Application
 
 The Python-based TUI (Terminal User Interface) provides a visual way to manage your dotfiles and is located in `.nounpack/dotfiler/` to keep it separate from your actual configuration files.
 
 #### Prerequisites
 
 ```bash
 # Python 3.8+ required
 python3 --version
 
 # Recommended: Create a virtual environment
 cd ~/.dotfiles/.nounpack/dotfiler
 python3 -m venv venv
 source venv/bin/activate  # On Windows: venv\Scripts\activate
 ```
 
 #### Installation
 
 ```bash
 cd ~/.dotfiles/.nounpack/dotfiler
 
 # Install dependencies
 pip install -r requirements.txt
 
 # Or install in development mode
 pip install -e .
 ```
 
 #### Running the Application
 
 ```bash
 # From the dotfiler directory
 cd ~/.dotfiles/.nounpack/dotfiler
 python dotfile_manager.py
 
 # Or if installed with pip install -e .
 dotfile-manager
 
 # Or use the runner script
 python run.py
 ```
 
 ### TUI Application Features
 
 #### **Add Mode - Browse and Track Files**
 - **File Browser**: Navigate your file system starting from home directory  
 - **Visual Indicators**: See which files are already tracked vs untracked
 - **Batch Selection**: Select multiple files and directories at once
 - **Smart Filtering**: Focus on configuration files and ignore temp files
 - **Integration**: Uses `setup.sh -i` behind the scenes for tracking
 
 ```
 ┌─ Add Files ──────────────────────────────────────┐
 │ 📁 /home/user/                                   │
 │   📁 .config/                                    │
 │     📄 .bashrc                     [TRACKED]     │
 │     📄 .vimrc                      [TRACKED]     │
 │     📄 .gitconfig                  [UNTRACKED]   │
 │     📁 nvim/                                     │
 │       📄 init.lua                  [UNTRACKED]   │
 │                                                  │
 │ [I] Ingest Selected  [Space] Select  [Q] Quit    │
 └──────────────────────────────────────────────────┘
 ```
 
 #### **Manage Mode - View and Organize**
 - **Status Overview**: See the state of all tracked files at a glance
 - **Link Status**: Identify broken, missing, or incorrect symlinks  
 - **File Operations**: Remove tracking, view conflicts, bulk operations
 - **Detailed Info**: Press `F` to see detailed file analysis
 - **Bulk Actions**: Unpack all files or perform maintenance
 
 ```
 ┌─ Manage Tracked Files ───────────────────────────┐
 │ 📄 .bashrc                         ✅ LINKED     │  
 │ 📄 .vimrc                          ✅ LINKED     │
 │ 📄 .gitconfig                      ⚠️  CONFLICT  │
 │ 📁 .config/nvim/init.lua           ❌ BROKEN     │
 │                                                  │
 │ [F] Info  [D] Delete  [U] Unpack All  [Q] Quit  │
 └──────────────────────────────────────────────────┘
 ```
 
 #### **File Status Indicators**
 
 - **✅ LINKED**: File is properly symlinked from home to dotfiles
 - **⚠️ CONFLICT**: Regular file exists where symlink should be  
 - **❌ BROKEN**: Symlink is broken or points to wrong location
 - **📝 MODIFIED**: Tracked file has uncommitted changes
 - **🔄 UNLINKED**: File is tracked but not symlinked to home
 
 #### **Info Dialog (Press F)**
 
 Get detailed diagnostics about problematic files:
 
 ```
 ┌─ File Info: .gitconfig ──────────────────────────┐
 │ 📊 Status: File Conflict                         │
 │                                                  │
 │ 📋 Details:                                      │
 │   • Regular file exists at: ~/.gitconfig         │  
 │   • Should be symlink to: ~/.dotfiles/.gitconfig │
 │   • Last modified: 2 hours ago                   │
 │                                                  │
 │ 🔍 Differences:                                  │
 │ --- ~/.dotfiles/.gitconfig                       │
 │ +++ ~/.gitconfig                                 │
 │ @@ -1,3 +1,4 @@                                  │
 │  [user]                                          │
 │      name = John Doe                             │
 │ +    email = john@newcompany.com                 │
 │                                                  │
 │ 💡 Suggested Action:                             │
 │   Re-ingest file to update tracked version       │
 │                                                  │
 │ [Enter] Close  [R] Re-ingest  [I] Ignore         │
 └──────────────────────────────────────────────────┘
 ```
 
 ### TUI Application Controls
 
 #### **Global Controls**
 - `Q` or `Ctrl+C`: Quit application
 - `Esc`: Cancel current operation or close dialogs
 - `Tab`: Switch between Add and Manage modes
 - `?` or `F1`: Show help screen
 
 #### **Add Mode Controls**  
 - `↑↓←→`: Navigate directory tree
 - `Space` or `Enter`: Toggle file/directory selection
 - `I`: Ingest selected files (calls `setup.sh -i`)
 - `R`: Refresh directory view
 - `H`: Toggle hidden files visibility
 - Mouse click: Select/deselect items
 
 #### **Manage Mode Controls**
 - `↑↓`: Navigate file list  
 - `F`: Show detailed file information
 - `D`: Delete/untrack selected file  
 - `U`: Unpack all tracked files (calls `setup.sh -u`)
 - `R`: Refresh file status
 - `Enter`: Quick action based on file status
 
 ### Integration with Shell Scripts
 
 The TUI application works seamlessly with the shell scripts:
 
 - **File Tracking**: Uses `setup.sh -i <file>` to add files
 - **File Removal**: Uses `setup.sh -t <file>` to untrack files  
 - **Unpacking**: Uses `setup.sh -u` to create symlinks
 - **Git Operations**: Respects the shell script git workflow
 - **Configuration**: Uses same zstyle settings for dotfiles directory
 
 ### Why .nounpack/dotfiler/?
 
 The Python TUI application is placed in `.nounpack/dotfiler/` for several important reasons:
 
 1. **Separation of Concerns**: Keeps the application code separate from your actual configuration files
 2. **No Symlinking**: Files in `.nounpack/` are automatically excluded from being symlinked to your home directory
 3. **Clean Home Directory**: Prevents Python files, virtual environments, and dependencies from cluttering your home directory
 4. **Portability**: The shell scripts work independently; the TUI is an optional enhancement
 5. **Development**: Easy to work on the TUI application without affecting your dotfiles workflow
 
 ### TUI vs Shell Scripts
 
 | Feature | Shell Scripts | TUI Application |
 |---------|---------------|----------------|
 | **Speed** | ⚡ Very fast | 🐌 Slower startup |
 | **Dependencies** | 📦 None (just zsh) | 🐍 Python + packages |
 | **Automation** | ✅ Perfect for scripts | ❌ Interactive only |
 | **Visual Feedback** | 📝 Text output | 🎨 Rich interface |
 | **Batch Operations** | ⚙️ Command-line args | 🖱️ Point and click |
 | **Learning Curve** | 📚 Need to learn commands | 🎯 Intuitive interface |
 | **Remote Use** | ✅ Works over SSH | ❌ Needs terminal UI |
 
 **Recommendation**: Start with shell scripts for automation and daily use, add the TUI for occasional visual management and file discovery.

## Troubleshooting

### Common Issues

**1. Scripts not executable:**
```bash
chmod +x ~/.dotfiles/*.sh
```

**2. Custom dotfiles directory not recognized:**
```bash
# Add to shell config:
zstyle ':dotfiles:directory' path '/your/custom/path'
```

**3. Updates not working:**
```bash
# Check git configuration
cd ~/.dotfiles
git remote -v
git status

# Force update check
./check_update.sh -f
```

**4. Symlinks not created:**
```bash
# Check file permissions
ls -la ~/.dotfiles/

# Try force unpack
./setup.sh -u
```

**5. Files being excluded unexpectedly:**
```bash
# Check if file is in exclusion list
./setup.sh -U filename  # Force unpack to test
```

### Debug Mode

For troubleshooting, you can examine what the scripts are doing:

```bash
# Verbose mode
./update.sh  # (not -q)
./setup.sh -u  # (not -q)

# Check git status
cd ~/.dotfiles
git log --oneline -10
git status
```

### Getting Help

```bash
# View usage information
./setup.sh
./update.sh --help  # (or just run without args)
./check_update.sh --help
```

## Example Workflows

### New Machine Setup

```bash
# 1. Clone your dotfiles
git clone <your-repo> ~/.dotfiles
cd ~/.dotfiles
chmod +x *.sh

# 2. Create all symlinks
./setup.sh -u

# 3. Set up automatic updates
echo 'source ~/.dotfiles/check_update.sh' >> ~/.zshrc
```

### Adding a New Config File

```bash
# 1. Create your config
vim ~/.config/newsoftware/config.toml

# 2. Track it
./setup.sh -i ~/.config/newsoftware/config.toml

# 3. Commit
git add -A && git commit -m "Add newsoftware config"
```

### Updating Existing Config

```bash
# Edit the symlinked file (changes go directly to dotfiles)
vim ~/.vimrc  # This is actually ~/.dotfiles/.vimrc

# Commit changes
cd ~/.dotfiles
git add .vimrc && git commit -m "Update vim configuration"
```

### Cleaning Up Old Files

```bash
# Remove from tracking
./setup.sh -t .old-config

# Commit the removal
git add -A && git commit -m "Remove old config"
```

This dotfiles management system provides a robust, automated way to manage your configuration files across multiple machines while maintaining git history and providing flexible update mechanisms.
