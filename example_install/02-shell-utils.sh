#!/bin/zsh
# Shell utilities 

# Module identification
module_name="shell-utils"
module_description="Shell environment tools"
module_main_function="run_shell_utils_module"

# Main function for this module
run_shell_utils_module() {
    install_eza
    install_fzf
    install_zoxide
    install_antidote
    install_shell_tools
    install_onepassword
}

install_eza() {
    action "Installing eza..."
    if ! check_command eza; then
        if [[ "$DOTFILES_OS" == "Darwin" ]]; then
            install_package eza 
        else
            install_cargo_package eza
        fi
    else
        info "eza already installed"
    fi
}

install_onepassword() {
    action "Installing onepassword..."
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package 1password-cli
    else
        if ! check_command op; then
            action "Installing 1Password CLI..."
            curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
            sudo gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg && \
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" | \
            sudo tee /etc/apt/sources.list.d/1password.list && \
            sudo mkdir -p /etc/debsig/policies/AC2D62742012EA22/ && \
            curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol | \
            sudo tee /etc/debsig/policies/AC2D62742012EA22/1password.pol && \
            sudo mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22 && \
            curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
            sudo gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg && \
            sudo apt update && sudo apt install 1password-cli
        else
            info "1Password CLI already installed"
        fi
    fi
}

install_fzf() {
    action "Installing fzf..."
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package fzf
    else
        # Install fzf from git on Linux (system packages are often too old)
        function fzf_post_install() { ~/.local/share/fzf/install --no-update-rc --completion --key-bindings }
        install_using_git fzf https://github.com/junegunn/fzf.git ~/.local/share/fzf fzf_post_install
        unset -f fzf_post_install
    fi
    # Install fzf-git from git on Linux 
    install_using_git fzf-git https://github.com/junegunn/fzf-git.sh.git ~/.local/share/fzf-git
}


install_antidote() {
    action "Installing antidote..."
    install_using_git antidote https://github.com/mattmc3/antidote.git ${XDG_DATA_HOME:-${HOME}/.local/share}/antidote
}


install_zoxide() {
    action "Installing zoxide..."
    if ! check_command zoxide; then
        if [[ "$DOTFILES_OS" == "Darwin" ]]; then
            install_package zoxide
        else
            curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
        fi
    else
        info "zoxide already installed"
    fi
}

install_shell_tools() {
    action "Installing shell tools..."
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package ripgrep bat fd broot dust bottom procs dua-cli
    else
        install_cargo_package ripgrep
        install_cargo_package bat
        install_cargo_package fd-find
        install_cargo_package broot
        install_cargo_package du-dust
        install_cargo_package dua-cli
        install_cargo_package bottom
        install_cargo_package procs
    fi
    bat cache --build
}

# Legacy - non antidote install, prefer antidote installers
#
install_zsh_plugins() {
    install_fzf_tab
    install_zsh_autosuggestions
}

install_ohmyzsh() {
    action "Install ohmyzsh..."
    # Oh-my-zsh
    if [[ ! -d ~/.oh-my-zsh ]] || force_install; then
        sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    else
        warn "warning: need to install ohmyzsh"
        warn '  sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'
    fi
}

install_fzf_tab() {
    action "Installing fzf-tab..."
    install_fzf
    # fzf-tab
    install_using_git fzf-tab https://github.com/Aloxaf/fzf-tab ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/fzf-tab
}

install_zsh_autosuggestions() {
    action "Installing zsh-autosuggestions..."
    install_using_git zsh-autosuggestions https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
}

