#!/bin/zsh
# Programming language environments

# Module identification
module_name="ai"
module_description="AI helpers"
module_main_function="run_ai_module"

# Main function for this module
run_ai_module() {
    ensure_nodejs
    install_claude
    install_copilot
    install_gemini
    install_opencode
    install_jupyter
    install_opsdk
    install_basic_memory
}

install_claude() {
    action "Installing claude-code packages..."
    if !check_command claude; then
        curl -fsSL https://claude.ai/install.sh | bash
    fi
    install_npm_package @agentclientprotocol/claude-agent-acp
}

install_copilot() {
    action "Installing copilot Node.js packages..."
    install_npm_package @github/copilot
}

install_opencode() {
    action "Installing opencode Node.js packages..."
    install_npm_package opencode-ai
    install_npm_package @tarquinen/opencode-dcp@latest
    install_npm_package @ai-sdk/openai-compatible
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        brew install --cask opencode-desktop
    fi
}

install_gemini() {
    action "Installing gemini-cli Node.js packages..."
    install_npm_package @google/gemini-cli
}

install_llama() {
    action "Installing llama.cpp..."
    if [[ "$DOTFILES_OS" == "Darwin" ]]; then
        brew tap mostlygeek/llama-swap
        brew install llama-swap
    fi
    # or build locally
    install_package llama-cpp
}

install_basic_memory() {
    action "Installing basic-memory..."

    ensure_global_python_venv
    activate_global_or_local_python_venv

    pip_install basic-memory

    deactivate
}
