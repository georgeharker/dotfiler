#!/bin/zsh
# Helper functions for install scripts

# Capture script name early before functions change context
script_name="${${(%):-%x}:A}"
script_dir="${script_name:h}/../scripts/"
script_dir=${script_dir:A}

# Pull in logging
source "${script_dir}/logging.sh"

# Detect operating system
detect_os() {
    if [[ `uname` == "Darwin" ]]; then
        export DOTFILES_OS="Darwin"
        info "Detected macOS"
    else
        export DOTFILES_OS="Linux"
        info "Detected Linux"
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
                action "Installing cask: $package"
                brew install --cask "$package"
            done
        else
            for package in "$@"; do
                action "Installing package: $package"
                brew install "$package"
            done
        fi
    else
        for package in "$@"; do
            action "Installing package: $package"
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
        action "Installing Homebrew dependency..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
}


ensure_git() {
    if ! command_exists git; then
        action "Installing git dependency..."
        install_package git 
    else
        info "git already installed"
    fi
    if !command_exists git-lfs; then
        action "Installing git-lfs dependency..."
        install_package git-lfs
        git-lfs install
    else
        info "git-lfs already installed"
    fi
}

# Smart dependency helpers - ensure prerequisites are met
ensure_nodejs() {
    if ! command_exists node && ! command_exists nodejs; then
        action "Installing Node.js dependency..."
        if [[ "$DOTFILES_OS" == "Darwin" ]]; then
            install_package nodejs npm
        else
            curl -fsSL https://deb.nodesource.com/setup_25.x | sudo bash -
            # Via nodesource npm will be installed by nodejs
            install_package nodejs
        fi
    fi
}

install_npm_package() {
    local command_name="$1"
    local package_name="$2"
    if ! command_exists "$command_name"; then
        action "Installing npm package: $package_name"
        sudo npm install -g "$package_name"
    else
        info "npm package $package_name already installed"
    fi
}

ensure_rust() {
    if ! command_exists cargo; then
        action "Installing Rust dependency..."
        curl https://sh.rustup.rs -sSf | sh -s -- --no-modify-path --default-toolchain stable --profile minimal -y
        source ~/.cargo/env
        rustup install stable
        rustup default stable
    fi
}

brew_python_version="3.14"
python_version="cpython@3.14.0"
if [[ "$DOTFILES_OS" == "Darwin" ]]; then
    # On OSX prefer homebrew installs to ensure library compatibility
    managed_python="--no-managed-python"
else
    managed_python="--managed-python"
fi

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
            # On OSX prefer homebrew installs to ensure library compatibility
            install_package "python@${brew_python_version}"
        fi
        uv python install "${managed_python}" --preview-features python-install-default --default "${python_version}"
    fi
}

ensure_global_python_venv() {
    if [ ! -f ~/.venv/bin/activate ]; then
        uv venv -p "${python_version}" --system-site-packages --seed ~/.venv
    fi
}

activate_global_python_venv() {
    if [ -f ~/.venv/bin/activate ]; then
        source ~/.venv/bin/activate
    fi
}

pip_install() {
    uv pip install "$@"
}

ensure_deb_packages() {
    if [[ ! -d ~/ext/debian-packages ]]; then
        if [[ "$DOTFILES_OS" == "Darwin" ]]; then
            action "Skipping deb package installation on macOS"
        else
            ensure_git
            action "Cloning deb packages..."
            mkdir -p ~/ext
            pushd ~/ext
            git clone git@github.com:georgeharker/debian-packages.git
            popd
        fi
    fi
}

install_deb_package() {
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        action "Skipping deb package installation on macOS"
        return 1
    else
        ensure_deb_packages
        local package_name="$1"
        local deb_arch=$(dpkg --print-architecture)
        local package_path="${HOME}/ext/debian-packages/${deb_arch}/${package_name}_${deb_arch}.deb"
        if [[ -f ${package_path} ]]; then
            action "Installing deb package: ${package_name}"
            sudo dpkg -i ${package_path}
            return 0
        else
            error "Deb package not found: ${package_path}"
            return 1
        fi
    fi
}

install_cargo_package() {
    local command_name="$1"
    local package_name="$2"
    if ! command_exists "${command_name}"; then
        if ! install_deb_package "${package_name}"; then
            action "Installing cargo package: ${package_name}"
            cargo install "${package_name}"
        fi
    else
        info "Cargo package ${package_name} already installed"
    fi
}

# Careful use of this allows reinstallation into venvs

activate_global_or_local_python_venv() {
    if [ ${VIRTUAL_ENV+x} ]; then
        action "Using existing virtual environment at $VIRTUAL_ENV"
        source ${VIRTUAL_ENV}/bin/activate
    else
        if [ -f ~/.venv/bin/activate ]; then
            source ~/.venv/bin/activate
        fi
    fi
}
