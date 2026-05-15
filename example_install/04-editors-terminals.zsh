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
    install_package libutempter-dev
    if ! install_deb_package tmux; then
        action "Building custom tmux..."
        local dev_dir
        dev_dir="$(get_ext_dev_dir)"
        local tmux_deb_dir="${dev_dir}/tmux-deb"
        local tmux_src_dir="${tmux_deb_dir}/tmux-3.5"
        local debian_dir="${tmux_src_dir}/debian"
        mkdir -p "${tmux_deb_dir}"
        mkdir -p "${dev_dir}/deb"

        sudo dpkg -r tmux || echo "No local tmux installed"
        if [[ ! -f "${tmux_deb_dir}/tmux_3.5a-1_arm64.deb" ]] || force_install; then
            info "Building tmux from source..."
            sudo apt-get install -y libutempter-dev git-buildpackage
            pushd "${tmux_deb_dir}"
            if ! git_directory_exists "${tmux_src_dir}"; then
                git clone https://github.com/tmux/tmux.git "${tmux_src_dir}"
            fi
            cd "${tmux_src_dir}"
            if ! git_directory_exists "${debian_dir}"; then
                git clone git@github.com:georgeharker/tmux-deb.git "${debian_dir}"
            fi
            gbp export-orig --upstream-tree=BRANCH --upstream-branch=master
            debuild -us -uc
            popd
        fi
        sudo dpkg -i "${tmux_deb_dir}/tmux_3.5a-1_arm64.deb"
        cp "${tmux_deb_dir}/tmux_3.5a-1_arm64.deb" "${dev_dir}/deb/"
    fi
}

install_custom_neovim() {
    if ! install_deb_package neovim; then
        action "Building custom neovim..."
        local dev_dir
        dev_dir="$(get_ext_dev_dir)"
        local nvim_deb_dir="${dev_dir}/neovim-deb"
        local nvim_src_dir="${nvim_deb_dir}/neovim-0.12"
        mkdir -p "${nvim_deb_dir}"
        mkdir -p "${dev_dir}/deb"

        sudo dpkg -r neovim || echo "No local neovim installed"
        if [[ ! -f "${nvim_deb_dir}/nvim-linux-arm64.deb" ]] || force_install; then
            info "Building neovim from source..."
            if ! git_directory_exists "${nvim_src_dir}"; then
                git clone git@github.com:neovim/neovim.git "${nvim_src_dir}"
            fi
            cd "${nvim_src_dir}"
            git checkout v0.12.2
            make clean
            make distclean
            make CMAKE_BUILD_TYPE=RelWithDebInfo CMAKE_INSTALL_PREFIX=/usr/local/ CMAKE_EXTRA_FLAGS="-DCPACK_PACKAGING_INSTALL_PREFIX=/usr/local"
            cd build/
            cpack -g DEB
            cp nvim-linux-arm64.deb "${nvim_deb_dir}/"
        fi
        sudo dpkg -i "${nvim_deb_dir}/nvim-linux-arm64.deb"
        cp "${nvim_deb_dir}/nvim-linux-arm64.deb" "${dev_dir}/deb/"
    fi
}

install_ohmyposh() {
    action "Install ohmyposh..."
    # Oh-my-posh
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package jandedobbeleer/oh-my-posh/oh-my-posh
    else
        mkdir -p ~/bin
        if ! check_command oh-my-posh; then
            curl -s https://ohmyposh.dev/install.sh | bash -s -- -d ~/bin
        else
            verbose "oh-my-posh already installed"
        fi
    fi
}

install_tpm() {
    action "Install tpm..."
    # TPM (Tmux Plugin Manager)
    install_using_git tpm https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
}

install_shell_enhancements() {
    # Oh-my-posh
    install_ohmyposh

    # TPM (Tmux Plugin Manager)
    install_tpm
}
