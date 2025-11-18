#!/bin/zsh
# Editors and terminal applications

# Module identification
module_name="editors-terminals"
module_description="Editors, terminals, and shell enhancements"
module_main_function="run_editors_terminals_module"

# Main function for this module
run_editors_terminals_module() {
    install_terminal_apps
    install_shell_enhancements
}

install_terminal_apps() {
    action "Install terminal apps..."
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package tmux neovim
        install_package --cask ghostty
        install_package viu
    else
        install_custom_tmux
        install_custom_neovim
    fi
}

install_custom_tmux() {
    action "Building custom tmux..."
    mkdir -p ~/ext
    mkdir -p ~/ext/deb
    
    sudo dpkg -r tmux || echo "No local tmux installed"
    if [[ ! -f ~/ext/tmux-deb/tmux_3.5a-1_arm64.deb ]]; then
        info "Building tmux from source..."
        sudo apt-get install -y libutempter-dev git-buildpackage
        pushd ~/ext/
        mkdir -p tmux-deb
        cd tmux-deb
        if [[ ! -d tmux-3.5 ]]; then
            git clone https://github.com/tmux/tmux.git tmux-3.5
        fi
        cd tmux-3.5
        if [[ ! -d debian ]]; then
            git clone git@github.com:georgeharker/tmux-deb.git debian
        fi
        gbp export-orig --upstream-tree=BRANCH --upstream-branch=master
        debuild -us -uc
        popd
    fi
    sudo dpkg -i ~/ext/tmux-deb/tmux_3.5a-1_arm64.deb
    cp ~/ext/tmux-deb/tmux_3.5a-1_arm64.deb ~/ext/deb/
}

install_custom_neovim() {
    action "Building custom neovim..."
    sudo dpkg -r neovim || echo "No local neovim installed"
    if [[ ! -f ~/ext/neovim-deb/nvim-linux-arm64.deb ]]; then
        info "Building neovim from source..."
        pushd ~/ext/
        mkdir -p neovim-deb
        cd neovim-deb
        if [[ ! -d neovim-0.11 ]]; then
            git clone git@github.com:neovim/neovim.git neovim-0.11
        fi
        cd neovim-0.11
        git checkout v0.11.3
        make clean
        make distclean
        make CMAKE_BUILD_TYPE=RelWithDebInfo CMAKE_INSTALL_PREFIX=/usr/local/ CMAKE_EXTRA_FLAGS="-DCPACK_PACKAGING_INSTALL_PREFIX=/usr/local"
        cd build/
        cpack -g DEB
        cp nvim-linux-arm64.deb ~/ext/neovim-deb/
        popd
    fi
    sudo dpkg -i ~/ext/neovim-deb/nvim-linux-arm64.deb
    cp ~/ext/neovim-deb/nvim-linux-arm64.deb ~/ext/deb/
}

install_ohmyposh() {
    action "Install ohmyposh..."
    # Oh-my-posh
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package jandedobbeleer/oh-my-posh/oh-my-posh
    else
        mkdir -p ~/bin
        if ! command -v oh-my-posh &> /dev/null; then
            curl -s https://ohmyposh.dev/install.sh | bash -s -- -d ~/bin
        fi
    fi
}

install_ohmyzsh() {
    action "Install ohmyzsh..."
    # Oh-my-zsh
    if [[ ! -d ~/.oh-my-zsh ]]; then
        sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    else
        warn "warning: need to install ohmyzsh"
        warn '  sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'
    fi
}

install_tpm() {
    action "Install tpm..."
    # TPM (Tmux Plugin Manager)
    if [[ ! -d ~/.tmux/plugins/tpm ]]; then
        git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
    fi
}

install_shell_enhancements() {
    # Oh-my-posh
    install_ohmyposh

    # Oh-my-zsh
    install_ohmyzsh

    # TPM (Tmux Plugin Manager)
    install_tpm
}
