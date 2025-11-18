#!/bin/zsh
# Dotfiler Installation Module
# This module symlinks the dotfiler command into the user's ~/bin directory

# Module identification
module_name="dotfiler-install"
module_description="Install dotfiler command to ~/bin"
module_main_function="run_dotfiler_install_module"

# Main function for this module
run_dotfiler_install_module() {
    install_dotfiler_command
}

install_dotfiler_command() {
    action "Installing dotfiler command..."
    
    # Get the directory where the dotfiler script is located
    local script_dir=$(find_dotfiles_script_directory)
    local dotfiler_script="$(realpath "$script_dir/dotfiler")"
    
    # Check if dotfiler script exists
    if [[ ! -f "$dotfiler_script" ]]; then
        action "Error: dotfiler script not found at $dotfiler_script"
        return 1
    fi
    
    # Create ~/bin directory if it doesn't exist
    local bin_dir="$HOME/bin"
    if [[ ! -d "$bin_dir" ]]; then
        action "Creating ~/bin directory..."
        mkdir -p "$bin_dir"
    fi
    
    # Remove existing symlink if it exists
    local target_link="$bin_dir/dotfiler"
    if [[ -L "$target_link" ]]; then
        action "Removing existing dotfiler symlink..."
        rm "$target_link"
    elif [[ -f "$target_link" ]]; then
        action "Warning: $target_link exists but is not a symlink"
        action "Backing up existing file to $target_link.backup"
        mv "$target_link" "$target_link.backup"
    fi
    
    # Create the symlink
    action "Creating symlink from $dotfiler_script to $target_link"
    ln -s "$dotfiler_script" "$target_link"
    
    # Verify the symlink was created successfully
    if [[ -L "$target_link" && -x "$target_link" ]]; then
        info "✓ dotfiler command successfully installed to ~/bin/dotfiler"
        
        # Check if ~/bin is in PATH
        if [[ ":$PATH:" == *":$bin_dir:"* ]]; then
            info "✓ ~/bin is already in your PATH"
        else
            warn "⚠ ~/bin is not in your PATH"
            add_final_instruction "Add ~/bin to your PATH by adding 'export PATH=\"\$HOME/bin:\$PATH\"' to your shell profile"
        fi
    else
        error "✗ Failed to create dotfiler symlink"
        return 1
    fi
}
