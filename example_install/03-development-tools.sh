#!/bin/zsh
# Core development tools

# Module identification
module_name="development-tools"
module_description="Core development tools and utilities"
module_main_function="run_development_tools_module"

# Main function for this module
run_development_tools_module() {
    install_git
    install_git_delta
    install_development_tools
    install_github_cli
}

install_git() {
    install_package git git-lfs
}

install_git_delta() {
    action "Installing git-delta..."
    ensure_rust
    
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package git-delta
    else
        if ! command_exists git-delta; then
            cargo install git-delta
        fi
    fi
}

install_development_tools() {
    action "Installing development tools..."
    # Common tools for both platforms
    install_package cmake autoconf automake pkg-config gettext bison unzip
    
    # Language and core tools
    install_package python3 nodejs npm ripgrep bat fd

    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package bash
        install_package ninja
        install_package lua luarocks
    else
        install_package ninja-build
        # xsel is Linux-only (X11 clipboard utility)
        install_package xsel
        
        # Linux-specific packages
        sudo apt-get install -y python3-pip
        sudo apt-get install -y libevent-2.1-7 libevent-dev
        sudo apt-get install -y libncurses6 libncurses-dev
        sudo apt-get install -y curl build-essential

        sudo apt-get install -y lua5.1 luarocks
        
        # git-delta eza will be installed via cargo in rust section
    fi

    install_shell_tools
}

install_github_cli() {
    action "Installing github cli..."
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        brew install gh
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
}
