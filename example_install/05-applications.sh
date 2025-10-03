#!/bin/zsh
# Specific applications

# Module identification
module_name="applications"
module_description="Specific applications and tools"
module_main_function="run_applications_module"

# Main function for this module
run_applications_module() {
    install_git_delta
    install_onepassword
}

install_git_delta() {
    echo "Installing git-delta..."
    ensure_rust
    
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package git-delta
    else
        if ! command_exists git-delta; then
            cargo install git-delta
        fi
    fi
}

install_onepassword() {
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        install_package 1password-cli
    else
        if ! command -v op &> /dev/null; then
            echo "Installing 1Password CLI..."
            curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
            sudo gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg && \
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" | \
            sudo tee /etc/apt/sources.list.d/1password.list && \
            sudo mkdir -p /etc/debsig/policies/AC2D62742012EA22/ && \
            curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol | \
            sudo tee /etc/debsig/policies/AC2D62742012EA22/1password.pol && \
            sudo mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22 && \
            curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
            sudo gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg && \
            sudo apt update && sudo apt install 1password-cli
        fi
    fi
}
