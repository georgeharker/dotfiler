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
    install_zsh_autosuggestions
    install_shell_tools
    install_onepassword
}

install_eza() {
    action "Installing eza..."
    ensure_rust
    
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package eza 
    else
        if ! command_exists eza; then
            cargo install eza
        fi
    fi
}

install_onepassword() {
    action "Installing onepassword..."
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package 1password-cli
    else
        if ! command -v op &> /dev/null; then
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
        fi
    fi
}

install_fzf() {
    action "Installing fzf..."
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package fzf
    else
        # Install fzf from git on Linux (system packages are often too old)
        if [[ ! -d ~/.local/share/fzf ]]; then
            mkdir -p ~/.local/share/
            git clone --depth 1 https://github.com/junegunn/fzf.git ~/.local/share/fzf
            ~/.local/share/fzf/install --no-update-rc --completion --key-bindings
        fi
    fi
    # Install fzf-git from git on Linux 
    if [[ ! -d ~/.local/share/fzf-git ]]; then
        mkdir -p ~/.local/share/
        git clone --depth 1 https://github.com/junegunn/fzf-git.sh.git ~/.local/share/fzf-git
    fi

    # fzf-tab
    if [[ ! -d ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/fzf-tab ]]; then
        mkdir -p ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/
        git clone https://github.com/Aloxaf/fzf-tab ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/fzf-tab
    fi
}

install_zsh_autosuggestions() {
    action "Installing zsh-autosuggestions..."
    if [[ ! -d ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions ]]; then
        mkdir -p ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/
        git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
    fi
}

install_zoxide() {
    action "Installing zoxide..."
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package zoxide
    else
        curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
    fi
}

install_shell_tools() {
    action "Installing shell tools..."
    install_package ripgrep bat fd
    bat cache --build
}
