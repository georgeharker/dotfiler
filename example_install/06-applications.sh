#!/bin/zsh
# Specific applications

# Module identification
module_name="applications"
module_description="Specific applications and tools"
module_main_function="run_applications_module"

# Main function for this module
run_applications_module() {
    install_tailscale
}

install_tailscale() {
    action "Installing Tailscale..."
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package --cask tailscale-app
    else
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
}
