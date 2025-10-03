#!/bin/zsh

# Capture script name early before functions change context
script_name="${${(%):-%x}:A}"
helper_script_dir="${script_name:h}"

source "${helper_script_dir}/helpers.sh"


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
# Global associative arrays for module data
declare -A module_functions
declare -A module_descriptions  
declare -A module_filenames

# Function to add final instructions from modules
add_final_instruction() {
    final_instructions+=("$1")
}
# Function called by modules to register themselves
register_module() {
    local filename="$1"
    
    if [[ -z "$filename" ]]; then
        echo "ERROR: register_module called without filename parameter" >&2
        return 1
    fi
    
    local basename=$(basename "$filename" .sh)
    
    module_filenames["$basename"]="$filename"
    module_functions["$basename"]="${module_main_function:-run_${basename//-/_}_module}"
    module_descriptions["$basename"]="${module_description:-$basename}"
}

# Load all install modules
for module in "$install_dir"/*.sh; do
    if [[ -f "$module" && "$module" != *"helpers.sh" ]]; then
        echo "Loading module: $(basename "$module")"
        source "$module"
        # Register the module after loading
        register_module "$module"
    fi
done

main() {
    echo "Starting modular dotfiles installation..."
    echo "Operating System: $DOTFILES_OS"
    echo ""

    # Execute modules in filename order (collected during loading)
    # Sort by actual filename, not just basename
    local sorted_modules=($(for key in "${(@k)module_filenames}"; do echo "$key:$(basename "${module_filenames[$key]}")"; done | sort -t: -k2 | cut -d: -f1))
    local module_count=1
    
    for module_basename in "${sorted_modules[@]}"; do
        local section_name="${module_descriptions[$module_basename]}"
        local main_function="${module_functions[$module_basename]}"
        
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

