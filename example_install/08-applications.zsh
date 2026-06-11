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
    install_gnome_apps
}

install_tailscale() {
    action "Installing Tailscale..."
    if ! check_command tailscale; then
        if os_is_osx; then
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
    if os_is_osx; then
        install_package iproute2mac
    else
        verbose "iproute2 already available on Linux systems"
    fi
}

install_karabiner() {
    if os_is_osx; then
        action "Installing Karabiner-Elements..."
        install_package karabiner-elements
    fi
}

install_gnome_apps() {
    if os_is_debian; then
        action "Installing gnome apps..."
        install_package ptyxis
        install_package neovim-qt
        install_package gnome-shell-extension-manager
    fi
}


install_terminal_notifier() {
    if os_is_osx; then
        action "Installing terminal-notifier..."
        install_package terminal-notifier
    fi
}
