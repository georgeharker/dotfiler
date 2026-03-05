#!/bin/zsh
# Specific applications

# Module identification
module_name="applications"
module_description="Specific applications and tools"
module_main_function="run_applications_module"

# Main function for this module
run_applications_module() {
    # Tailscale: skip for embedded systems and work environments
    check_profile_not work && install_tailscale
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
        verbose "Tailscale already installed"
    fi
}

install_network_utils() {
    action "Installing network utils..."
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package iproute2mac
    else
        verbose "iproute2 already available on Linux systems"
    fi
}

install_karabiner() {
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        action "Installing Karabiner-Elements..."
        install_package karabiner-elements
    fi
}

install_terminal_notifier() {
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        action "Installing terminal-notifier..."
        install_package terminal-notifier
    fi
}
