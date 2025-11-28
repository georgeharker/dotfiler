#!/bin/zsh
# Script to run individual installation modules

# Capture script name early before functions change context
script_name="${${(%):-%x}:A}"
helper_script_dir="${script_name:h}"

# Load module management helpers (which includes main helpers)
source "${helper_script_dir}/module_helpers.sh"

# Get install directory using helper
install_dir=$(find_dotfiles_install_directory)

# Parse opts
zmodload zsh/zutil
zparseopts -D -E - f=force -force=force \
                   h=help -help=help

FORCE_INSTALL=$(( ${#force[@]} > 0 ))

# Global array for final instructions (same as install.sh)
final_instructions=()

# Function to add final instructions from modules
add_final_instruction() {
    final_instructions+=("$1")
}

if [[ $# -eq 0 || ${#help[@]} -gt 0 ]]; then
    echo "Usage: $0 <module_name> [function_name]"
    echo ""
    echo "  -f, --force   : Force reinstallation of all components"
    echo "  -h, --help    : Show this help message"
    echo "  module_name   : Name of the module to run"
    echo "  function_name : Optional specific function to run (defaults to main module function)"
    echo ""
    echo "Examples:"
    echo "  $0 development-tools                    # Run all development tools"
    echo "  $0 development-tools install_github_cli # Run only GitHub CLI installation"
    echo ""
    list_available_modules "$install_dir"
    exit 1
fi

# Display accumulated final instructions
if [[ ${#final_instructions[@]} -gt 0 ]]; then
    echo ""
    echo "=== Next Steps ==="
    local step_num=1
    for instruction in "${final_instructions[@]}"; do
        echo "$step_num. $instruction"
        ((step_num++))
    done
else
    echo ""
    echo "=== Module Complete ==="
fi
# Source helpers
source "$install_dir/helpers.sh"
detect_os

module_name="$1"
target_function="$2"

# Find the module file by name
module_file=$(find_module_by_name "$module_name" "$install_dir")
if [[ $? -ne 0 ]]; then
    echo "Module '$module_name' not found."
    echo ""
    list_available_modules "$install_dir"
    exit 1
fi

echo "Running module: $(basename "$module_file")"
source "$module_file"

# Determine which function to run
if [[ -n "$target_function" ]]; then
    # User specified a specific function
    if declare -f "$target_function" > /dev/null; then
        echo "Running function: $target_function"
        "$target_function"
    else
        echo "Error: Function '$target_function' not found in module '$module_name'."
        echo ""
        list_module_functions "$module_file" "$module_name"
        exit 1
    fi
else
    # Run the module's main function (default behavior)
    main_function="run_${module_name//-/_}_module"
    if declare -f "$main_function" > /dev/null; then
        echo "Running main function: $main_function"
        "$main_function"
    else
        echo "Error: Module main function '$main_function' not found."
        echo ""
        list_module_functions "$module_file" "$module_name"
        exit 1
    fi
fi
