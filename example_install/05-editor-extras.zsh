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
            local dev_dir
            dev_dir="$(get_dev_dir)"
            mkdir -p "${dev_dir}"
            curl -L https://github.com/quarto-dev/quarto-cli/releases/download/v1.9.36/quarto-1.9.36-linux-arm64.pkg -o "${dev_dir}/quarto.deb"
            sudo dpkg -i "${dev_dir}/quarto.deb"
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

