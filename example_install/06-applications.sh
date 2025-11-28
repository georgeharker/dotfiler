#!/bin/zsh
# Specific applications

# Module identification
module_name="applications"
module_description="Specific applications and tools"
module_main_function="run_applications_module"

# Main function for this module
run_applications_module() {
    install_tailscale
    install_network_utils
}

install_tailscale() {
    action "Installing Tailscale..."
    if ! check_command tailscale; then
        if [[ "$DOTFILES_OS" == "Darwin" ]]; then
            install_package --cask tailscale-app
        else
            curl -fsSL https://tailscale.com/install.sh | sh
        fi
    else
        info "Tailscale already installed"
    fi
}

install_network_utils() {
    action "Installing network utils..."
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package iproute2mac
    else
        info "iproute2 already available on Linux systems"
    fi
}

