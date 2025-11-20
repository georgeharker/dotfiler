#!/bin/zsh

# Capture script name early before functions change context
script_name="${${(%):-%x}:A}"
script_dir="${script_name:h}"

source "${script_dir}/logging.sh"

# Simple script directory finder (no zstyle - used internally to avoid circular deps)
find_script_directory_simple() {
    local script_path="${(%):-%x}:A"
    echo "${script_path:h}"
}

# Function to clean up all variables and functions introduced by helpers
# This should be called at the end of scripts to clean up the environment
function cleanup_helpers(){
    # Unset all functions defined in this file
    unset -f find_script_directory_simple 2>/dev/null
    unset -f resolve_dotfiles_path 2>/dev/null
    unset -f find_dotfiles_script_directory 2>/dev/null
    unset -f find_dotfiles_directory 2>/dev/null
    unset -f find_dotfiles_install_directory 2>/dev/null
    unset -f find_dotfiles_exclude_file 2>/dev/null
    unset -f is_script_sourced 2>/dev/null
    unset -f cleanup_helpers 2>/dev/null

    cleanup_logging
}

# Helper function to resolve paths relative to dotfiles directory
resolve_dotfiles_path() {
    local path="$1"
    
    # Return as-is if absolute path
    if [[ "$path" = /* ]]; then
        echo "${path:A}"
        return 0
    fi
    
    # Resolve relative to dotfiles directory
    local dotfiles_dir=$(find_dotfiles_directory)
    echo "${dotfiles_dir}/${path}"
    return 0
}

find_dotfiles_script_directory() {
    local script_dir
    
    if zstyle -s ':dotfiles:scripts' path script_dir; then
        echo "$(resolve_dotfiles_path "$script_dir")"
        return 0
    fi
    
    local script_path="${(%):-%x}:A"
    script_dir="${script_path:h}"
    echo "${script_dir}"
    return 0
}

# Function to find dotfiles directory reliably
find_dotfiles_directory() {
    local dotfiles_dir
    
    # 1. Check zstyle override first (highest priority)
    if zstyle -s ':dotfiles:directory' path dotfiles_dir; then
        echo "${dotfiles_dir:A}"
        return 0
    fi
    
    # 2. Get script dir with symlink resolution via :A modifier
    local script_dir=$(find_script_directory_simple)
    
    # 3. Try git root detection from script location
    local git_root
    if git_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null); then
        echo "$git_root"
        return 0
    fi
    
    # 4. Ultimate fallback
    echo "${HOME}/.dotfiles"
}

# Function to find dotfiles directory reliably
find_dotfiles_install_directory() {
    local install_dir
    
    if zstyle -s ':dotfiles:install' path install_dir; then
        echo "$(resolve_dotfiles_path "$install_dir")"
        return 0
    fi

    local dotfiles_dir=$(find_dotfiles_directory)
    
    local install_dir="${dotfiles_dir}/.nounpack/install"
    echo "${install_dir}"
    return 0
}


# Function to find dotfiles exclude file
find_dotfiles_exclude_file() {
    local exclude_path
    
    # Check zstyle override first
    if zstyle -s ':dotfiles:exclude' path exclude_path; then
        echo "$(resolve_dotfiles_path "$exclude_path")"
        return 0
    fi
    
    # Default to dotfiles_exclude in dotfiles directory
    local dotfiles_dir=$(find_dotfiles_directory)
    echo "${dotfiles_dir}/dotfiles_exclude"
    return 0
}

# Function to detect if script was sourced or executed
is_script_sourced() {
    # Method 1: Check zsh-specific indicators first (most reliable for zsh)
    if [[ -n "${ZSH_EVAL_CONTEXT:-}" ]]; then
        case "$ZSH_EVAL_CONTEXT" in
            *:file) return 1 ;;  # Executed
            *:file:*) return 0 ;; # Sourced
        esac
    fi
    # Method 4: Fallback - assume executed if we can't determine
    return 1  # Executed directly
}
