#!/bin/zsh
#
# Zsh completions for dotfiler
# Source this file in your .zshrc to enable tab completion

# Ensure completion system is loaded
# Only load if not already loaded (avoid conflicts)
if ! command -v compdef >/dev/null 2>&1; then
    autoload -U compinit
    compinit
fi

# Main completion function for dotfiler
_dotfiler() {
    local state line
    typeset -A opt_args

    # Define the main command structure
    _arguments -C \
        '(- *)'{-h,--help}'[Show help message]' \
        '1: :_dotfiler_commands' \
        '*:: :->args' && return 0

    # Handle subcommand arguments
    case $state in
        args)
            case $words[1] in
                gui)
                    _dotfiler_gui_args
                    ;;
                setup)
                    _dotfiler_setup_args
                    ;;
                check-updates)
                    _dotfiler_check_update_args
                    ;;
                update)
                    _dotfiler_update_args
                    ;;
               install)
                   _dotfiler_install_args
                   ;;
               install-module)
                   _dotfiler_install_module_args
                   ;;
            esac
            ;;
    esac
}

# Complete main commands
_dotfiler_commands() {
    local commands
    commands=(
        'gui:Launch the graphical user interface'
        'setup:Run dotfile setup and management operations'
        'check-updates:Check for updates to dotfiles repository'
        'update:Update dotfiles from remote repository'
       'install:Run modular installation system (all modules)'
       'install-module:Run specific installation module'
    )
    _describe 'dotfiler commands' commands
}

# Complete GUI command arguments
_dotfiler_gui_args() {
    _arguments \
        '(- *)--help[Show help message]' \
        '--dotfiles-dir[Specify dotfiles directory]:directory:_directories' \
        '--setup-script[Specify setup script path]:file:_files'
}

# Complete setup command arguments
_dotfiler_setup_args() {
    _arguments \
        '(- *)--help[Show help message]' \
        '(-i --ingest)'{-i,--ingest}'[Track and ingest files]:file:_files' \
        '(-s --setup)'{-s,--setup}'[Run complete setup process]' \
        '(-u --unpack)'{-u,--unpack}'[Unpack and link files (respects exclusions)]:file:_files' \
        '(-U --force-unpack)'{-U,--force-unpack}'[Force unpack files (ignore exclusions)]:file:_files' \
        '(-t --untrack)'{-t,--untrack}'[Remove files from tracking]:file:_files' \
        '(-d --diff)'{-d,--diff}'[Show differences for tracked files]' \
        '(-q --quiet)'{-q,--quiet}'[Run in quiet mode (suppress output)]' \
        '(-D --dry-run)'{-D,--dry-run}'[Show what would be done without making changes]' \
        '(-y --yes)'{-y,--yes}'[Answer yes to all prompts]' \
        '(-n --no)'{-n,--no}'[Answer no to all prompts]'
}

# Complete check_update command arguments
_dotfiler_check_update_args() {
    _arguments \
        '(- *)--help[Show help message]' \
        '(-f --force)'{-f,--force}'[Force update check even if timestamp is recent]' \
        '(-d --debug)'{-d,--debug}'[Enable debug output for troubleshooting]'
}

# Complete update command arguments
_dotfiler_update_args() {
    _arguments \
        '(- *)--help[Show help message]' \
        '(-q --quiet)'{-q,--quiet}'[Run update quietly without output]' \
        '(-c --commit-hash)'{-c,--commit-hash}'[Update to specific commit hash]:hash:' \
        '(-r --range)'{-r,--range}'[Show changes in specific range]:range:' \
        '(-D --dry-run)'{-D,--dry-run}'[Show what would be updated without making changes]'
}

# Complete install command arguments
_dotfiler_install_args() {
    _arguments \
        '(- *)--help[Show help message]'
}

# Complete install-module command arguments
_dotfiler_install_module_args() {
    _arguments \
        '(- *)--help[Show help message]' \
        '1: :_dotfiler_modules' \
        '2: :_dotfiler_module_functions'
}

# Complete available installation modules
_dotfiler_modules() {
    local modules
    
    # Use the same approach as install scripts - find script directory and source module_helpers
    local script_dir
    
    # Try to find dotfiler command location
    script_dir="${${${(%):-%x}:A}:h}"
    
    # Try to source module_helpers.sh and get modules
    if [[ -n "$script_dir" && -f "$script_dir/module_helpers.sh" ]]; then
        # Source in a subshell to avoid polluting completion environment
        local module_list
        module_list=$(
            source "$script_dir/module_helpers.sh" 2>/dev/null && 
            list_available_modules 2>/dev/null | 
            tail -n +2 | 
            sed 's/^[[:space:]]*//' | 
            awk '{desc=""; for(i=2;i<=NF;i++) desc=desc $i " "; gsub(/ $/, "", desc); print $1":"desc}'
        )
        
        if [[ -n "$module_list" ]]; then
            local -a module_array
            module_array=(${(f)module_list})
            _describe 'installation modules' module_array
            return
        fi
    fi
    
    # Fallback to common module names if directory parsing fails
    modules=(
        'package-manager:Package manager setup and fonts'
        'development-tools:Core development tools and utilities'
        'editors-terminals:Editors, terminals, and shell enhancements'
        'programming-languages:Language runtimes and tools'
        'applications:End-user applications'
        'post-install:Final configuration and cleanup'
    )
    _describe 'installation modules' modules
}

# Complete module functions (simplified - would need module context)
_dotfiler_module_functions() {
    # This is a simplified implementation - in practice would need to parse the specific module
    local functions
    functions=(
        'install_development_tools:Install core development tools'
        'install_github_cli:Install GitHub CLI'
        'install_package_manager:Set up package manager'
        'setup_fonts:Install and configure fonts'
    )
    _describe 'module functions' functions
}

# File completion for dotfiles (helps with -i, -u, -t options)
_dotfiles_files() {
    local dotfiles_dir
    
    # Try to get dotfiles directory from various sources
    if (( $+commands[dotfiler] )); then
        # Try to use dotfiler to find the directory
        dotfiles_dir=$(dotfiler setup --help 2>/dev/null | grep -o '/[^[:space:]]*\.dotfiles' | head -1)
    fi
    
    # Fallback to common locations
    if [[ -z "$dotfiles_dir" ]]; then
        if [[ -d ~/.dotfiles ]]; then
            dotfiles_dir=~/.dotfiles
        elif [[ -d ~/.config/dotfiles ]]; then
            dotfiles_dir=~/.config/dotfiles
        fi
    fi
    
    if [[ -n "$dotfiles_dir" && -d "$dotfiles_dir" ]]; then
        _files -W "$dotfiles_dir"
    else
        _files
    fi
}

# Register the completion function
compdef _dotfiler dotfiler

# Also provide completion for the script name when called directly
compdef _dotfiler .nounpack/scripts/dotfiler 2>/dev/null
compdef _dotfiler ~/.dotfiles/.nounpack/scripts/dotfiler 2>/dev/null

# Completion hints
zstyle ':completion:*:dotfiler:*' group-name ''
zstyle ':completion:*:dotfiler:*' verbose yes
zstyle ':completion:*:dotfiler:*:descriptions' format '%B%d%b'

# Enable completion caching for better performance
zstyle ':completion:*:dotfiler:*' use-cache yes
zstyle ':completion:*:dotfiler:*' cache-path ~/.zcompcache/dotfiler

