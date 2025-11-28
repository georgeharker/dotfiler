#!/bin/zsh
# Package manager setup
# Module self-identification
module_filename="${(%):-%x}"

# Module identification
module_name="package-manager"
module_description="Package manager setup and fonts"
module_main_function="run_package_manager_module"

# Main function for this module
run_package_manager_module() {
    install_package_manager
    setup_fonts
}

install_package_manager() {
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        action "Installing Homebrew..."
        ensure_homebrew
    else
        action "Updating apt packages..."
        sudo apt-get update
        sudo apt-get install -y curl
    fi
}

setup_fonts() {
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package font-meslo-lg font-meslo-lg-dz font-meslo-lg-nerd-font
    else
        if [[ ! -n $(fc-list | grep 'Meslo.*NerdFont') ]] || force_install; then
            action "Installing Nerd Fonts..."
            pushd /tmp/
            curl -OL https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/Meslo.tar.xz
            mkdir -p ~/.local/share/fonts
            tar xvf Meslo.tar.xz -C ~/.local/share/fonts/
            pushd ~/.local/share/fonts
            fc-cache -fv
            popd  # Back to /tmp
            popd  # Back to original directory
        else
            info "Nerd Fonts already installed."
        fi
    fi
}
