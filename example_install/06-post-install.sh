#!/bin/zsh
# Post-installation configuration

# Module identification
module_name="post-install"
module_description="Post-installation configuration and setup"
module_main_function="run_post_install_module"

# Main function for this module
run_post_install_module() {
    configure_neovim
    configure_system
    
    # Add final instructions
    add_final_instruction "Run 'bat cache --build' to build bat cache"
    add_final_instruction "Run 'claude setup-token' to configure Claude CLI" 
    add_final_instruction "Restart your shell or run 'source ~/.zshrc'"
    add_final_instruction "Configure your terminal to use the installed Nerd Font"
    
    if [[ "$DOTFILES_OS" != "Darwin" ]]; then
        add_final_instruction "Enable X11Forwarding in /etc/ssh/sshd_config if needed"
    fi
}

configure_neovim() {
    echo "Configuring Neovim..."
    nvim --headless -c 'Lazy install' -c ":q"
}

configure_system() {
    if [[ "$DOTFILES_OS" != "Darwin" ]]; then
        echo "Note: Enable X11Forwarding in /etc/ssh/sshd_config"
        echo "Note: Create ~/ext directory for extensions"
        mkdir -p ~/ext
    fi

    rehash
}
