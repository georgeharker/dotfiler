#!/bin/zsh
#
# Module loading and management helpers for dotfiler installation system
# This file contains functions for discovering, loading, and managing installation modules
#

# Always load main helpers to ensure all path functions are available
script_dir="${${(%):-%x}:A:h}"
source "$script_dir/helpers.sh"

# Global associative arrays for module data
declare -gA dotfiles_module_functions
declare -gA dotfiles_module_descriptions  
declare -gA dotfiles_module_filenames
declare -gA dotfiles_module_names

# Function called by modules to register themselves
register_module() {
    local filename="$1"
    
    if [[ -z "$filename" ]]; then
        echo "ERROR: register_module called without filename parameter" >&2
        return 1
    fi
    
    local basename=$(basename "$filename" .sh)
    
    dotfiles_module_filenames["$basename"]="$filename"
    dotfiles_module_functions["$basename"]="${module_main_function:-run_${basename//-/_}_module}"
    dotfiles_module_descriptions["$basename"]="${module_description:-$basename}"
    dotfiles_module_names["$basename"]="${module_name:-$basename}"
}

# Load all install modules from a directory
load_install_modules() {
    local install_dir="$1"
    
    if [[ -z "$install_dir" ]]; then
        install_dir=$(find_dotfiles_install_directory)
    fi
    
    if [[ ! -d "$install_dir" ]]; then
        warn "Install directory not found: $install_dir"
        return 1
    fi
    
    # Clear existing module data
    dotfiles_module_functions=()
    dotfiles_module_descriptions=()
    dotfiles_module_filenames=()
    dotfiles_module_names=()
    
    # Load all install modules
    for module in "$install_dir"/*.sh; do
        if [[ -f "$module" && "$module" != *"helpers.sh" ]]; then
            # Reset module variables before sourcing
            unset module_name module_description module_main_function
            
            source "$module"
            
            # Register the module after loading
            register_module "$module"
        fi
    done
}

# List available modules (for user display)
list_available_modules() {
    local install_dir="${1:-$(find_dotfiles_install_directory)}"
    
    # Load modules if not already loaded
    if [[ ${#dotfiles_module_names[@]} -eq 0 ]]; then
        load_install_modules "$install_dir"
    fi
    
    if [[ ${#dotfiles_module_names[@]} -eq 0 ]]; then
        warn "No modules found in $install_dir"
        return 1
    fi
    
    echo "Available modules:"
    
    # Sort by filename for consistent order
    local sorted_modules=($(for key in "${(@k)dotfiles_module_filenames}"; do echo "$key:$(basename "${dotfiles_module_filenames[$key]}")"; done | sort -t: -k2 | cut -d: -f1))
    
    for module_basename in "${sorted_modules[@]}"; do
        local module_name="${dotfiles_module_names[$module_basename]}"
        local module_desc="${dotfiles_module_descriptions[$module_basename]}"
        printf "  %-20s %s\n" "$module_name" "$module_desc"
    done
}

# Find module file by name
find_module_by_name() {
    local target_name="$1"
    local install_dir="${2:-$(find_dotfiles_install_directory)}"
    
    # Load modules if not already loaded
    if [[ ${#dotfiles_module_names[@]} -eq 0 ]]; then
        load_install_modules "$install_dir"
    fi
    
    # Search through loaded modules
    for module_basename in "${(@k)dotfiles_module_names}"; do
        if [[ "${dotfiles_module_names[$module_basename]}" == "$target_name" ]]; then
            echo "${dotfiles_module_filenames[$module_basename]}"
            return 0
        fi
    done
    
    return 1
}

# Get sorted list of module basenames (for iteration)
get_sorted_modules() {
    # Load modules if not already loaded
    if [[ ${#dotfiles_module_names[@]} -eq 0 ]]; then
        load_install_modules
    fi
    
    # Sort by filename for consistent order
    for key in "${(@k)dotfiles_module_filenames}"; do 
        echo "$key:$(basename "${dotfiles_module_filenames[$key]}")"
    done | sort -t: -k2 | cut -d: -f1
}

# Helper function to extract functions from a module using subshell approach
_extract_module_functions() {
    local module_file="$1"
    local format="${2:-raw}"
    
    # Use subshell to avoid namespace pollution while getting accurate function list
    (
        source "$module_file" 2>/dev/null || return 1
typeset -f + | grep -E "^(install_[a-zA-Z0-9]*|ensure_[a-zA-Z0-9]*|setup_[a-zA-Z0-9]*|run_${module_name//-/_}_module)" | \
        while read -r func_name; do
            if [[ "$format" == "completion" ]]; then
                echo "$func_name:Module function"
            else
                echo "$func_name"
            fi
        done
    )
}

# Function to list available functions in a module (for user display)
list_module_functions() {
    local module_file="$1"
    local module_name="$2"
    
    echo "Available functions in module '$module_name':"
    
    local functions
    functions=$(_extract_module_functions "$module_file" "raw")
    
    if [[ -n "$functions" ]]; then
        echo "$functions" | while read -r func_name; do
            printf "  %s\n" "$func_name"
        done
    else
        echo "  No functions found"
    fi
}

# Function to get available functions in a module for tab completion
get_module_functions() {
    local module_name="$1"
    local install_dir="${2:-$(find_dotfiles_install_directory)}"
    
    # Find the module file
    local module_file
    module_file=$(find_module_by_name "$module_name" "$install_dir")
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    # Use the unified helper with completion format
    _extract_module_functions "$module_file" "completion"
}

# Clean up module helper variables and functions
cleanup_module_helpers() {
    unset dotfiles_module_functions dotfiles_module_descriptions dotfiles_module_filenames dotfiles_module_names 2>/dev/null
    unset -f register_module load_install_modules list_available_modules find_module_by_name get_sorted_modules _extract_module_functions list_module_functions get_module_functions cleanup_module_helpers 2>/dev/null
}

