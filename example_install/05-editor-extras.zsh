#!/bin/zsh
# Programming language environments

# Module identification
module_name="editor-extras"
module_description="Editor support"
module_main_function="run_programming_languages_module"

# Main function for this module
run_editor_extras_module() {
    install_treesitter
    install_prettier
    install_quarto
    install_harper
    install_shfmt
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
            mkdir -p ~/ext
            curl -L https://github.com/quarto-dev/quarto-cli/releases/download/v1.8.26/quarto-1.8.26-linux-arm64.deb -o ~/ext/quarto.deb
            sudo dpkg -i ~/ext/quarto.deb
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
