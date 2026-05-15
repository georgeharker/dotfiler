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
    install_llama
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
        # Try brew first (llama-swap pulls in llama.cpp)
        brew tap mostlygeek/llama-swap 2>/dev/null || true
        install_package llama-swap
    else
        install_package llama-cpp 2>/dev/null || true
    fi

    install_package libomp

    # Build from source as fallback / to get latest binaries
    local dev_dir
    dev_dir="$(get_ext_dev_dir)"
    local llama_dir="${dev_dir}/llama.cpp"

    ensure_git
    mkdir -p "${dev_dir}"

    if ! git_directory_exists "${llama_dir}"; then
        action "Cloning llama.cpp..."
        git clone https://github.com/ggml-org/llama.cpp.git "${llama_dir}"
    else
        action "Updating llama.cpp..."
        git -C "${llama_dir}" pull
    fi

    action "Building llama.cpp..."
    cmake -B "${llama_dir}/build" "${llama_dir}"
    cmake --build "${llama_dir}/build" --config Release

    mkdir -p "${HOME}/bin"
    action "Copying llama.cpp binaries to ~/bin..."
    cp "${llama_dir}/build/bin/llama-"* "${HOME}/bin/"
}

install_basic_memory() {
    action "Installing basic-memory..."

    ensure_global_python_venv
    activate_global_or_local_python_venv

    pip_install basic-memory

    deactivate
}
