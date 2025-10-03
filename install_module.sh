#!/bin/zsh
# Script to run individual installation modules

script_dir="${${${(%):-%x}:A}:h}"
install_dir="$script_dir/install"

# Function to list available modules
list_modules() {
    echo "Available modules:"
    for module_file in "$install_dir"/[0-9]*.sh; do
        if [[ -f "$module_file" ]]; then
            # Source the module to get its name and description
            source "$module_file"
            if [[ -n "$module_name" ]]; then
                printf "  %-20s %s\n" "$module_name" "$module_description"
            fi
            # Reset variables for next iteration
            unset module_name module_description
        fi
    done
}

# Function to list available functions in a module
list_module_functions() {
    local module_file="$1"
    local module_name="$2"
    
    echo "Available functions in module '$module_name':"
    
    # Source the module and extract function names
    source "$module_file"
    
    # List all functions that start with 'install_' or the main function
    declare -F | grep -E "(install_|run_${module_name//-/_}_module)" | while read -r line; do
        func_name=$(echo "$line" | awk '{print $3}')
        printf "  %s\n" "$func_name"
    done
}

# Function to find module file by name
find_module_by_name() {
    local target_name="$1"
    for module_file in "$install_dir"/[0-9]*.sh; do
        if [[ -f "$module_file" ]]; then
            source "$module_file"
            if [[ "$module_name" == "$target_name" ]]; then
                echo "$module_file"
                return 0
            fi
            # Reset variables
            unset module_name module_description
        fi
    done
    return 1
}

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <module_name> [function_name]"
    echo ""
    echo "  module_name   : Name of the module to run"
    echo "  function_name : Optional specific function to run (defaults to main module function)"
    echo ""
    echo "Examples:"
    echo "  $0 development-tools                    # Run all development tools"
    echo "  $0 development-tools install_github_cli # Run only GitHub CLI installation"
    echo ""
    list_modules
    exit 1
fi

# Source helpers
source "$install_dir/helpers.sh"
detect_os

module_name="$1"
target_function="$2"

# Find the module file by name
module_file=$(find_module_by_name "$module_name")
if [[ $? -ne 0 ]]; then
    echo "Module '$module_name' not found."
    echo ""
    list_modules
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
