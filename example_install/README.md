# Modular Install System

This directory contains the modular installation system for dotfiles. Each script handles a specific category of installations and can be run independently or as part of the main installation process.

## Structure

- `helpers.sh` - Common helper functions used by all modules
- `01-package-manager.sh` - Package manager setup (Homebrew/APT) and fonts
- `02-development-tools.sh` - Core development tools (fzf, ripgrep, etc.)
- `03-editors-terminals.sh` - Editors, terminals, and shell enhancements
- `04-programming-languages.sh` - Language-specific environments (Python, Rust, Node.js)
- `05-applications.sh` - Specific applications (1Password, etc.)
- `06-post-install.sh` - Post-installation configuration

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

To see all available modules:
```bash
./install_module.sh
```

## Architecture Detection

The system automatically detects whether it's running on macOS or Linux and adjusts installation methods accordingly:

- **macOS**: Uses Homebrew for package management
- **Linux**: Uses APT for package management, builds some tools from source

## Helper Functions

- `detect_os()` - Sets DOTFILES_OS environment variable
- `install_package()` - Universal package installer (handles brew/apt differences)
- `command_exists()` - Check if a command is available
- `print_section()` / `print_subsection()` - Formatted output helpers

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
