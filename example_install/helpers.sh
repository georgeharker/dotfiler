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

force_install() {
    if [[ $FORCE_INSTALL -gt 0 ]]; then
        return 0
    fi
    return 1
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

## Profile-based installation filtering

# Default to 'full' if not specified
INSTALL_PROFILE="${INSTALL_PROFILE:-full}"

# Check if current profile matches any of the given profiles
# Returns 0 (success) if profile matches, 1 otherwise
# Usage: check_profile full work && install_something
check_profile() {
    local target_profiles="$@"

    for profile in $target_profiles; do
        if [[ "$INSTALL_PROFILE" == "$profile" ]]; then
            return 0
        fi
    done

    return 1
}

# Check if current profile does NOT match any of the given profiles
# Returns 0 (success) if profile doesn't match, 1 if it does
# Usage: check_profile_not embedded minimal && install_gui_app
check_profile_not() {
    ! check_profile "$@"
}

# Helper to display current profile (for debugging)
show_profile() {
    echo "Current install profile: $INSTALL_PROFILE"
}

## package based installs

ensure_homebrew() {
    if [[ "$DOTFILES_OS" == "Darwin" ]] && ! check_command brew; then
        action "Installing Homebrew dependency..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
}

package_installed() {
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        brew list "$1" >& /dev/null && return 0
    else
        dpkg -s "$1" &> /dev/null && return 0
    fi

    return 1
}

check_package() {
    if force_install; then
        return 1
    fi

    package_installed "$1"
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
                if ! check_package "$package"; then
                    if package_installed "$package" && force_install; then
                        brew reinstall --cask "$package"
                    else
                        brew install --cask "$package"
                    fi
                else
                    verbose "Package $package already installed"
                fi
            done
        else
            for package in "$@"; do
                if ! check_package "$package"; then
                    action "Installing package: $package"
                    if package_installed "$package" && force_install; then
                        brew reinstall "$package"
                    else
                        brew install "$package"
                    fi
                else
                    verbose "Package $package already installed"
                fi
            done
        fi
    else
        for package in "$@"; do
            if ! check_package "$package"; then
                action "Installing package: $package"
                if package_installed "$package" && force_install; then
                    sudo apt-get reinstall -y "$package"
                else
                    sudo apt-get install -y "$package"
                fi
            else
                verbose "Package $package already installed"
            fi
        done
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" &> /dev/null
}

check_command() {
    force_install && return 1
    command -v "$1" &> /dev/null
}

## git based installs

ensure_git() {
    if ! check_command git; then
        action "Installing git dependency..."
        install_package git 
    else
        verbose "git already installed"
    fi
    if ! check_command git-lfs; then
        action "Installing git-lfs dependency..."
        install_package git-lfs
        git-lfs install
    else
        verbose "git-lfs already installed"
    fi
}

git_directory_exists() {
    [[ -d "${1}" ]] && [[ -d "${1}/.git" ]]
}

check_git_directory() {
    if force_install; then
        return 1
    fi
    if git_directory_exists "$1"; then
        return 0
    else
        return 1
    fi
}

install_using_git() {
    ensure_git
    local package_name="$1"
    local repo="$2"
    local dest_dir="$3"
    local post_install="$4"
    if ! check_git_directory "${dest_dir}"; then
        mkdir -p "${dest_dir:h}"
        git_directory_exists "${dest_dir}" && rm -rf "${dest_dir}"
        git clone --depth 1 "${repo}" "${dest_dir}"
        [[ -n "${post_install}" ]] && "${post_install}"
        info "${package_name} installed from git"
    else
        verbose "${package_name} already installed"
    fi
}

## node based installs

activate_nvm() {
    if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
        export NVM_DIR="${HOME}/.local/share/nvm"
        source "${NVM_DIR}/nvm.sh"
        if ! nvm use node &> /dev/null; then
            nvm install node && source "${NVM_DIR}/nvm.sh"
        fi
    fi
}

uninstall_nodesource_js() {
    if [[ -f /etc/apt/sources.list.d/nodesource.list ]] || check_package nodejs; then
        activate_nvm
        if check_command nvm; then
            nvm use system &> /dev/null || return 0
        fi
        sudo rm /etc/apt/sources.list.d/nodesource.list
        local post_install_cmd=$(npm list -g -p | \
                                 tail -n +2 | \
                                 sed -e "s|^$(npm prefix -g)/lib/node_modules/||g" \
                                     -e "s/^npm$//g" -e "s/^tls-test$//g" | \
                                 xargs echo "sudo npm uninstall -g")
        if [[ ! "${post_install_cmd}" =~ " "* ]]; then
            add_final_instruction "Clean up old npm install:\n    ${post_install_cmd}"
            add_final_instruction "sudo apt-get remove nodejs npm"
        fi
    fi
}

uninstall_brew_nodejs() {
    if check_command npm; then
        activate_nvm
        if check_command nvm; then
            nvm use system &> /dev/null || return 0
        fi
        local post_install_cmd=$(npm list -g -p | \
                                 tail -n +2 | \
                                 sed -e "s|^$(npm prefix -g)/lib/node_modules/||g" \
                                     -e "s/^npm$//g" -e "s/^tls-test$//g" | \
                                 xargs echo "sudo npm uninstall -g")
        if [[ ! "${post_install_cmd}" =~ " "* ]]; then
            add_final_instruction "Clean up old npm install:\n    ${post_install_cmd}"
            add_final_instruction "sudo apt-get remove nodejs npm"
        fi
        # brew remove node
    fi
}

uninstall_system_nodejs() {
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        uninstall_brew_nodejs
    else
        uninstall_nodesource_js
    fi
}

# Smart dependency helpers - ensure prerequisites are met
ensure_nodejs() {
    export NVM_DIR="${HOME}/.local/share/nvm"
    mkdir -p "${NVM_DIR}"
    if [[ ! -s "${NVM_DIR}/nvm.sh" ]]; then
        action "Installing Node.js dependency..."
        PROFILE=/dev/null curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
    fi
    activate_nvm
}

npm_package_installed() {
    ensure_nodejs
    npm list -g --depth=0 "$1" &> /dev/null
}

check_npm_package() {
    if force_install; then
        return 1
    fi
    npm_package_installed "$1"
}

install_npm_package() {
    local package_name="$1"
    if ! check_npm_package "$package_name"; then
        action "Installing npm package: $package_name"
        if npm_package_installed "${package_name}"; then
            npm install -f -g "$package_name"
        else
            npm install -g "$package_name"
        fi
    else
        verbose "npm package $package_name already installed"
    fi
}

## python based installs

brew_python_version="3.14"
python_version="cpython@3.14.0"
if [[ "$DOTFILES_OS" == "Darwin" ]]; then
    # On OSX prefer homebrew installs to ensure library compatibility
    managed_python="--no-managed-python"
else
    managed_python="--managed-python"
fi

ensure_uv() {
    if ! check_command uv; then
        echo "Installing uv dependency..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi
    [[ -f "$HOME/.local/bin/env" ]] && source "$HOME/.local/bin/env"
    return 0
}

ensure_python3() {
    ensure_uv
    if ! check_command "python${brew_python_version}"; then
        echo "Installing Python3 dependency..."
        if [[ "$DOTFILES_OS" == "Darwin" ]]; then
            # On OSX prefer homebrew installs to ensure library compatibility
            install_package "python@${brew_python_version}"
            rehash
            python_version=`which "python${brew_python_version}"`
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

pip_packages_installed() {
    for package in "$@"; do
        uv pip show "${package%\[[a-zA-Z_]*\]}" &>/dev/null || return 1
    done
    return 0
}

check_pip_packages() {
    if force_install; then
        return 1
    fi
    pip_packages_installed "$@"
}

pip_install() {
    if ! check_pip_packages "$@"; then
        action "Installing python packages: $@"
        if force_install; then
            uv pip install --reinstall "$@"
        else
            uv pip install "$@"
        fi
    else
        verbose "python packages $@ already installed"
    fi
}

## cargo based

ensure_rust() {
    if ! (check_command cargo && check_command rustc); then
        action "Installing Rust dependency..."
        curl https://sh.rustup.rs -sSf | sh -s -- --no-modify-path --default-toolchain stable --profile minimal -y
        source ~/.cargo/env
        rustup install stable
        rustup default stable
    fi
}

ensure_deb_packages() {
    ensure_git
    if [[ ! -d ~/ext/debian-packages ]]; then
        if [[ "$DOTFILES_OS" == "Darwin" ]]; then
            action "Skipping deb package installation on macOS"
        else
            action "Cloning deb packages..."
            install_using_git debian-packages git@github.com:georgeharker/debian-packages.git ~/ext/debian-packages
        fi
    fi
    git -C ~/ext/debian-packages/ pull
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
        if ! check_package "${package_name}"; then
            if [[ -f ${package_path} ]]; then
                action "Installing deb package: ${package_name}"
                sudo dpkg -i ${package_path}
                return 0
            else
                error "Deb package not found: ${package_path}"
                return 1
            fi
        fi
        return 0
    fi
}

# Cargo checks are done via command for now
cargo_crate_installed() {
    cargo install --list | grep "$1"
}

check_cargo_crate() {
    if force_install; then
        return 1
    fi
    cargo_crate_installed "$1"
}

install_cargo_package() {
    local package_name="$1"
    if ! ( check_command cargo && check_cargo_crate "${package_name}" ); then
        if ! install_deb_package "${package_name}"; then
            action "Installing cargo package: ${package_name}"
            if cargo_crate_installed "${package_name}"; then
                cargo install -f "${package_name}"
            else
                cargo install "${package_name}"
            fi
        fi
    else
        verbose "Cargo package ${package_name} already installed"
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
