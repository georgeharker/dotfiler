#!/bin/zsh
# Programming language environments

# Module identification
module_name="editor-extras"
module_description="Editor support"
module_main_function="run_editor_extras_module"

# Main function for this module
run_editor_extras_module() {
    install_treesitter
    install_prettier
    install_quarto
    install_harper
    install_shfmt
    install_shuck
}

install_treesitter() {
    action "Installing tree-sitter Node.js packages..."
    install_npm_package tree-sitter-cli
}

install_prettier() {
    action "Installing prettier..."
    install_npm_package prettier
    install_npm_package @fsouza/prettierd
}

install_quarto() {
    if os_is_mac; then
        action "Installing Quarto..."
        install_package quarto
    else
        if ! check_command quarto; then
            action "Installing Quarto..."
            local version
            version="$(github_latest_version quarto-dev/quarto-cli)"
            if [[ -z "${version}" ]]; then
                error "Failed to determine latest Quarto version"
                return 1
            fi
            local deb_arch
            deb_arch="$(dpkg --print-architecture)"
            install_deb_from_url "https://github.com/quarto-dev/quarto-cli/releases/download/v${version}/quarto-${version}-linux-${deb_arch}.deb"
        fi
    fi
}

install_harper() {
    action "Installing Harper lsp..."
    install_cargo_package harper-ls
}

install_shfmt() {
    action "Installing shfmt..."
    install_package shfmt
}

install_shuck() {
    action "Installing shuck..."
    install_cargo_package "shuck-cli"
}

