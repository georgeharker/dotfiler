#!/bin/zsh
# Programming language environments

# Module identification
module_name="programming-languages"
module_description="Programming language environments (Python, Rust, Node.js)"
module_main_function="run_programming_languages_module"

# Main function for this module
run_programming_languages_module() {
    install_python_environment
    install_rust_environment
    install_claude
    install_tree_sitter
}

install_python_environment() {
    # Ensure Python3 is available
    ensure_python3
    
    # Python virtual environment
    ensure_global_python_venv
    source ~/.venv/bin/activate

    echo "Installing Python packages..."
    pip3 install mypy pynvim neovim
    pip3 install 'python-lsp-server[all]' pylsp-mypy
    pip3 install flake8 flake8-bugbear flake8-comprehensions flake8-builtins flake8-import-order
}

install_rust_environment() {
    echo "Installing Rust..."
    if ! command -v cargo &> /dev/null; then
        curl https://sh.rustup.rs -sSf | sh -s -- --no-modify-path --default-toolchain stable --profile default -y
        source ~/.cargo/env
        rustup install stable
        rustup default stable
    fi
}

install_node_environment() {
    echo "Installing claude-code Node.js packages..."
    # Ensure Node.js is available for npm installs
    ensure_nodejs
    
    sudo npm install -g @anthropic-ai/claude-code
    sudo npm install -g @zed-industries/claude-code-acp
}

install_node_environment() {
    echo "Installing tree-sitter Node.js packages..."
    # Ensure Node.js is available for npm installs
    ensure_nodejs
    
    sudo npm install -g tree-sitter-cli
}
