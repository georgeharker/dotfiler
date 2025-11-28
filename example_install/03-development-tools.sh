#!/bin/zsh
# Core development tools

# Module identification
module_name="development-tools"
module_description="Core development tools and utilities"
module_main_function="run_development_tools_module"

# Main function for this module
run_development_tools_module() {
    ensure_git
    install_git_delta
    install_development_tools
    install_github_cli
}

install_git_delta() {
    action "Installing git-delta..."
    ensure_rust
    
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package git-delta
    else
        install_cargo_package git-delta
    fi
}

install_development_tools() {
    action "Installing development tools..."
    # Common tools for both platforms
    install_package cmake autoconf automake pkg-config gettext bison unzip
    
    # Language and core tools
    install_package python3 jq

    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package bash
        install_package ninja
        install_package lua luarocks
        install_package gnu-sed
    else
        install_package ninja-build
        # xsel is Linux-only (X11 clipboard utility)
        install_package xsel
        
        # Linux-specific packages
        install_package python3-pip
        install_package libevent-2.1-7 libevent-dev
        install_package libncurses6 libncurses-dev
        install_package curl build-essential

        install_package lua5.1 luarocks
        
        # git-delta eza will be installed via cargo in rust section
    fi
}

install_github_cli() {
    action "Installing github cli..."
    if ! check_command gh || force_install; then
        if [[ "$DOTFILES_OS" == "Darwin" ]]; then
            install_package gh
        else
            (type -p wget >/dev/null || (sudo apt update && sudo apt install wget -y)) \
            && sudo mkdir -p -m 755 /etc/apt/keyrings \
            && out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            && cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
            && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
            && sudo mkdir -p -m 755 /etc/apt/sources.list.d \
            && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
            && sudo apt update \
            && sudo apt install gh -y
        fi
    else
        info "GitHub CLI already installed"
    fi
}
