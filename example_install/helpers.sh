#!/bin/zsh
# Helper functions for install scripts

# Detect operating system
detect_os() {
    if [[ `uname` == "Darwin" ]]; then
        export DOTFILES_OS="Darwin"
        echo "Detected macOS"
    else
        export DOTFILES_OS="Linux"
        echo "Detected Linux"
    fi
}

# Universal package installer
install_package() {
    local cask_mode=false
    
    # Check for --cask flag
    if [[ "$1" == "--cask" ]]; then
        cask_mode=true
        shift
    fi
    
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        if $cask_mode; then
            for package in "$@"; do
                echo "Installing cask: $package"
                brew install --cask "$package"
            done
        else
            for package in "$@"; do
                echo "Installing package: $package"
                brew install "$package"
            done
        fi
    else
        for package in "$@"; do
            echo "Installing package: $package"
            sudo apt-get install -y "$package"
        done
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Print section header
print_section() {
    echo ""
    echo "=== $1 ==="
    echo ""
}

# Print subsection header
print_subsection() {
    echo "--- $1 ---"
}

ensure_homebrew() {
    if [[ "$DOTFILES_OS" == "Darwin" ]] && ! command_exists brew; then
        echo "Installing Homebrew dependency..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
}

# Smart dependency helpers - ensure prerequisites are met
ensure_nodejs() {
    if ! command_exists node && ! command_exists nodejs; then
        echo "Installing Node.js dependency..."
        install_package nodejs npm
    fi
}

ensure_rust() {
    if ! command_exists cargo; then
        echo "Installing Rust dependency..."
        curl https://sh.rustup.rs -sSf | sh -s -- --no-modify-path --default-toolchain stable --profile default -y
        source ~/.cargo/env
        rustup install stable
        rustup default stable
    fi
}

brew_python_version="3.14"
python_version="cpython@3.14.0"

ensure_uv() {
    if ! command_exists uv; then
        echo "Installing uv dependency..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi
    source "$HOME/.local/bin/env"
}

ensure_python3() {
    ensure_uv
    if ! command_exists python3; then
        echo "Installing Python3 dependency..."
        if [[ "$DOTFILES_OS" == "Darwin" ]]; then
            # On OSX ensure python3 is available via homebrew also
            install_package "python@${brew_python_version}"
        fi
        uv python install --preview-features python-install-default --default "${python_version}"
    fi
}

ensure_global_python_venv() {
    if [ ! -f ~/.venv/bin/activate ]; then
        uv venv -p "${python_version}" --system-site-packages --seed ~/.venv
    fi
}
