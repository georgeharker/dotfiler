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

    install_basic_python_packages
}

install_basic_python_packages() {
    action "Installing Python packages..."

    activate_global_or_local_python_venv
    pip_install mypy pynvim neovim
    pip_install 'python-lsp-server[all]' pylsp-mypy
    pip_install flake8 flake8-bugbear flake8-comprehensions flake8-builtins flake8-import-order
    
    deactivate
}

install_claude() {
    action "Installing claude-code Node.js packages..."
    # Ensure Node.js is available for npm installs
    ensure_nodejs
    
    sudo npm install -g @anthropic-ai/claude-code
    sudo npm install -g @zed-industries/claude-code-acp
}

install_treesitter() {
    action "Installing tree-sitter Node.js packages..."
    # Ensure Node.js is available for npm installs
    ensure_nodejs
    
    sudo npm install -g tree-sitter-cli
}

install_jupyter() {
    action "Installing jupyter packages..."
    install_package jupyter
    
    ensure_global_python_venv
    activate_global_or_local_python_venv

    action "Installing jupyter Python packages..."
    pip_install jupyter_client ipykernel cairosvg pnglatex nbformat

    deactivate
}

install_pytorch() {
    action "Installing PyTorch..."

    ensure_global_python_venv
    activate_global_or_local_python_venv

    pip_install torch torchvision torchaudio torchcodec
    
    deactivate
}

install_datascience() {
    action "Installing PyTorch..."

    ensure_global_python_venv
    activate_global_or_local_python_venv

    pip_install matplotlib pandas numpy scipy
    
    deactivate
}

install_opsdk() {
    action "Installing onepassword sdk..."

    ensure_global_python_venv
    activate_global_or_local_python_venv

    pip_install onepassword-sdk
    
    deactivate
}
