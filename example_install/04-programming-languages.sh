#!/bin/zsh
# Programming language environments

# Module identification
module_name="programming-languages"
module_description="Programming language environments (Python, Rust, Node.js)"
module_main_function="run_programming_languages_module"

# Main function for this module
run_programming_languages_module() {
    install_python_environment
    ensure_rust
    install_claude
    install_treesitter
    install_jupyter
}

install_python_environment() {
    # Ensure uv
    ensure_uv
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

install_claude() {
    echo "Installing claude-code Node.js packages..."
    # Ensure Node.js is available for npm installs
    ensure_nodejs
    
    sudo npm install -g @anthropic-ai/claude-code
    sudo npm install -g @zed-industries/claude-code-acp
}

install_treesitter() {
    echo "Installing tree-sitter Node.js packages..."
    # Ensure Node.js is available for npm installs
    ensure_nodejs
    
    sudo npm install -g tree-sitter-cli
}

install_jupyter() {
    echo "Installing jupyter packages..."
    install_package jupyter
    
    ensure_global_python_venv
    source ~/.venv/bin/activate

    echo "Installing jupyter Python packages..."
    pip3 install jupyter_client ipykernel cairosvg pnglatex nbformat

}

