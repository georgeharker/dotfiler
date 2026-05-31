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
    if os_is_osx; then
        brew install --cask opencode-desktop
    fi
}

install_gemini() {
    action "Installing gemini-cli Node.js packages..."
    install_npm_package @google/gemini-cli
}

install_llama() {
    action "Installing llama-swap..."
    if os_is_osx; then
        # Try brew first (llama-swap pulls in llama.cpp)
        brew tap mostlygeek/llama-swap 2>/dev/null || true
        install_package llama-swap
    install_package libomp
    elif ! check_command llama-swap; then
        local repo="mostlygeek/llama-swap"
        local version
        version=$(github_latest_version "${repo}")
        if [[ -n "${version}" ]]; then
            # llama-swap uses goreleaser-style asset names:
            #   llama-swap_<version>_<os>_<arch>.tar.gz
            local asset="llama-swap_${version}_$(goreleaser_os)_$(goreleaser_arch).tar.gz"
            local url="https://github.com/${repo}/releases/download/v${version}/${asset}"
            local tmp_dir
            tmp_dir=$(mktemp -d /tmp/llama-swap-XXXXXX)
            action "Downloading ${asset}..."
            if curl -sfL "${url}" -o "${tmp_dir}/${asset}"; then
                tar -xzf "${tmp_dir}/${asset}" -C "${tmp_dir}"
                mkdir -p "${HOME}/bin"
                cp "${tmp_dir}/llama-swap" "${HOME}/bin/"
                chmod +x "${HOME}/bin/llama-swap"
                info "llama-swap ${version} installed to ${HOME}/bin/"
            else
                error "Failed to download ${url}"
            fi
            rm -rf "${tmp_dir}"
        else
            error "Failed to look up latest llama-swap version"
        fi
        install_package libomp-dev
    else
        verbose "llama-swap already installed"
    fi


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

    LLAMA_FLAGS=
    if os_is_osx; then
        export CPATH="$(brew --prefix)/include:$(brew --prefix)/opt/libomp/include:$CPATH"
        export LIBRARY_PATH="$(brew --prefix)/lib:$(brew --prefix)/opt/libomp/lib:$LIBRARY_PATH"
    elif [[ -x /usr/local/cuda/bin/nvcc ]]; then
        export CUDACXX=/usr/local/cuda/bin/nvcc
        LLAMA_FLAGS="-DGGML_CUDA=ON"
    fi
    action "Building llama.cpp..."
    pushd "${llama_dir}"
    rm -rf build
    popd
    cmake -B "${llama_dir}/build" "$LLAMA_FLAGS" "${llama_dir}"
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
