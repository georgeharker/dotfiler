#!/bin/zsh

# Capture script name early before functions change context
script_name="${${(%):-%x}:A}"
helper_script_dir="${script_name:h}"

# Load module management helpers (which includes main helpers)
source "${helper_script_dir}/module_helpers.sh"


# Dotfiles Installation Script (Modular Version)
# This script uses modular components from install/ directory

set -e  # Exit on any error

# Get the directory where this script is located
script_dir=$(find_dotfiles_script_directory)
install_dir=$(find_dotfiles_install_directory)

# Source helper functions
source "$install_dir/helpers.sh"

# Detect operating system
detect_os
# Global array for final instructions
final_instructions=()

# Function to add final instructions from modules
add_final_instruction() {
    final_instructions+=("$1")
}

# Load all install modules using helper
echo "Loading installation modules..."
load_install_modules "$install_dir"

main() {
    echo "Starting modular dotfiles installation..."
    echo "Operating System: $DOTFILES_OS"
    echo ""

    # Execute modules in filename order (collected during loading)
    # Sort by actual filename, not just basename
    local sorted_modules=($(get_sorted_modules))
    local module_count=1
    
    for module_basename in "${sorted_modules[@]}"; do
        local section_name="${dotfiles_module_descriptions[$module_basename]}"
        local main_function="${dotfiles_module_functions[$module_basename]}"
        
        # Execute the module
        print_section "$module_count. $section_name"
        
        if declare -f "$main_function" > /dev/null; then
            "$main_function"
        else
            echo "Warning: Function '$main_function' not found in $module_basename"
        fi
        
        ((module_count++))
    done

    echo ""
    echo "=== Installation Complete ==="
    echo ""
    
    # Display accumulated final instructions
    if [[ ${#final_instructions[@]} -gt 0 ]]; then
        echo "Next steps:"
        local step_num=1
        for instruction in "${final_instructions[@]}"; do
            echo "$step_num. $instruction"
            ((step_num++))
        done
    else
        echo "No additional steps required."
    fi
}

# Run the installation if script is executed directly
if ! is_script_sourced; then
    main "$@"
fi

