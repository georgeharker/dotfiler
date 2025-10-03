#!/bin/zsh
# Core development tools

# Module identification
module_name="development-tools"
module_description="Core development tools and utilities"
module_main_function="run_development_tools_module"

# Main function for this module
run_development_tools_module() {
    install_development_tools
    install_github_cli
}

install_development_tools() {
    # Common tools for both platforms
    install_package cmake autoconf automake pkg-config gettext bison ninja-build unzip
    
    # Language and core tools
    install_package python3 lua luarocks nodejs npm ripgrep bat
    
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package bash fzf
    else
        # xsel is Linux-only (X11 clipboard utility)
        install_package xsel
        
        # Linux-specific packages
        sudo apt-get install -y python3-pip
        sudo apt-get install -y libevent-2.1-7 libevent-dev
        sudo apt-get install -y libncurses6 libncurses-dev
        sudo apt-get install -y curl build-essential
        
        # Install fzf from git on Linux (system packages are often too old)
        if [[ ! -d ~/.fzf ]]; then
            git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
            ~/.fzf/install --bin --no-update-rc
        fi
        
        # git-delta will be installed via cargo in rust section
    fi
}

install_github_cli() {
    install_package gh
}
