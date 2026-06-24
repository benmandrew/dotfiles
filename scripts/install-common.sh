#!/bin/bash

log() {
    if [[ "$*" == *"skipping"* ]]; then
        printf "\033[1;33m[install]\033[0m %s\n" "$*"
    else
        printf "\033[1;32m[install]\033[0m %s\n" "$*"
    fi
}

err() {
    printf "\033[1;31m[install]\033[0m ERROR: %s\n" "$*" >&2
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Missing required command: $1"
        exit 1
    fi
}

version_gte() {
    local current="$1" required="$2"
    local cur_major cur_minor cur_patch req_major req_minor req_patch
    IFS=. read -r cur_major cur_minor cur_patch <<<"${current}"
    IFS=. read -r req_major req_minor req_patch <<<"${required}"
    cur_major="${cur_major:-0}"
    cur_minor="${cur_minor:-0}"
    cur_patch="${cur_patch:-0}"
    req_major="${req_major:-0}"
    req_minor="${req_minor:-0}"
    req_patch="${req_patch:-0}"
    if ((cur_major > req_major)); then return 0; fi
    if ((cur_major < req_major)); then return 1; fi
    if ((cur_minor > req_minor)); then return 0; fi
    if ((cur_minor < req_minor)); then return 1; fi
    ((cur_patch >= req_patch))
}

load_cargo_env() {
    if [[ -f "${HOME}/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "${HOME}/.cargo/env"
    fi
}

install_oh_my_zsh() {
    if [[ -d "${HOME}/.oh-my-zsh" ]]; then
        log "Oh My Zsh already installed; skipping"
        return
    fi
    log "Installing Oh My Zsh"
    local script_path
    script_path="$(mktemp)"
    curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o "${script_path}"
    RUNZSH=no CHSH=no sh "${script_path}"
    rm -f "${script_path}"
}

install_rust() {
    load_cargo_env
    if command -v cargo >/dev/null 2>&1 && command -v rustup >/dev/null 2>&1; then
        log "Rust already installed; skipping"
        return
    fi
    log "Installing Rust"
    local script_path
    script_path="$(mktemp)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "${script_path}"
    sh "${script_path}" -y
    rm -f "${script_path}"

    load_cargo_env
}

install_rust_analyzer() {
    load_cargo_env
    if command -v rust-analyzer >/dev/null 2>&1; then
        log "rust-analyzer already installed; skipping"
        return
    fi
    require_cmd rustup
    log "Installing rust-analyzer"
    rustup component add rust-analyzer
}

install_clangd() {
    if command -v clangd >/dev/null 2>&1; then
        log "clangd already installed; skipping"
        return
    fi
    log "Installing clangd"
    local os_name
    os_name="$(uname -s)"
    if [[ "${os_name}" == "Darwin" ]]; then
        brew install llvm
    else
        sudo apt install -y clangd
    fi
}

install_cmake() {
    local required_version="4.3.2"
    if command -v cmake >/dev/null 2>&1; then
        local cmake_output current_version
        cmake_output="$(cmake --version)"
        current_version="$(awk 'NR==1{print $3}' <<<"${cmake_output}")"
        if version_gte "${current_version}" "${required_version}"; then
            log "cmake ${current_version} already satisfies >= ${required_version}; skipping"
            return
        fi
        log "cmake ${current_version} < ${required_version}; installing from GitHub"
    else
        log "Installing cmake ${required_version}"
    fi
    local os_name
    os_name="$(uname -s)"
    if [[ "${os_name}" == "Darwin" ]]; then
        if brew list --formula cmake >/dev/null 2>&1; then
            brew upgrade cmake
        else
            brew install cmake
        fi
        return
    fi
    local os_arch cmake_arch
    os_arch="$(uname -m)"
    if [[ "${os_arch}" == "aarch64" ]]; then
        cmake_arch="linux-aarch64"
    else
        cmake_arch="linux-x86_64"
    fi
    local installer="cmake-${required_version}-${cmake_arch}.sh"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    curl -fsSL "https://github.com/Kitware/CMake/releases/download/v${required_version}/${installer}" \
        -o "${tmp_dir}/${installer}"
    chmod +x "${tmp_dir}/${installer}"
    sudo sh "${tmp_dir}/${installer}" --prefix=/usr/local --skip-license
}

install_pyright() {
    if command -v pyright >/dev/null 2>&1; then
        log "pyright already installed; skipping"
        return
    fi
    require_cmd npm
    log "Installing pyright"
    npm install -g pyright
}

install_eza() {
    if command -v eza >/dev/null 2>&1; then
        log "eza already installed; skipping"
        return
    fi
    load_cargo_env
    require_cmd cargo
    log "Installing eza"
    cargo install eza
}

install_fd() {
    if command -v fd >/dev/null 2>&1; then
        log "fd already installed; skipping"
        return
    fi
    load_cargo_env
    require_cmd cargo
    log "Installing fd"
    cargo install fd-find
}

install_zoxide() {
    if command -v zoxide >/dev/null 2>&1; then
        log "zoxide already installed; skipping"
        return
    fi
    log "Installing zoxide"
    local script_path
    script_path="$(mktemp)"
    curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh -o "${script_path}"
    sh "${script_path}"
    rm -f "${script_path}"
}

install_fzf() {
    if command -v fzf >/dev/null 2>&1; then
        log "fzf already installed; skipping"
        return
    fi
    log "Installing fzf"
    if [[ ! -d "${HOME}/.fzf" ]]; then
        git clone --depth 1 https://github.com/junegunn/fzf.git "${HOME}/.fzf"
    else
        log "fzf already cloned; skipping"
    fi
    "${HOME}/.fzf/install" --bin --no-update-rc --no-bash --no-fish
}

install_starship() {
    if command -v starship >/dev/null 2>&1; then
        log "Starship already installed; skipping"
        return
    fi
    log "Installing Starship"
    local script_path
    script_path="$(mktemp)"
    curl -sS https://starship.rs/install.sh -o "${script_path}"
    sh "${script_path}" -y
    rm -f "${script_path}"
}

install_claude_code() {
    if command -v claude >/dev/null 2>&1; then
        log "Claude Code already installed; skipping"
        return
    fi
    log "Installing Claude Code"
    local script_path
    script_path="$(mktemp)"
    curl -fsSL https://claude.ai/install.sh -o "${script_path}"
    bash "${script_path}"
    rm -f "${script_path}"
}

install_rtk() {
    if command -v rtk >/dev/null 2>&1; then
        log "rtk already installed; skipping"
        return
    fi
    log "Installing rtk"
    local script_path
    script_path="$(mktemp)"
    curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh -o "${script_path}"
    sh "${script_path}"
    rm -f "${script_path}"
}

install_uv() {
    if command -v uv >/dev/null 2>&1; then
        log "uv already installed; skipping"
        return
    fi
    log "Installing uv"
    local script_path
    script_path="$(mktemp)"
    curl -LsSf https://astral.sh/uv/install.sh -o "${script_path}"
    sh "${script_path}"
    rm -f "${script_path}"
    export PATH="${HOME}/.local/bin:${PATH}"
}

install_token_savior() {
    require_cmd uvx
    local mcp_list
    mcp_list="$(claude mcp list 2>/dev/null)" || true
    if echo "${mcp_list}" | grep -q "token-savior"; then
        log "token-savior MCP server already registered; skipping"
        return
    fi
    log "Registering token-savior MCP server"
    claude mcp add -s user token-savior -- uvx --python 3.11 --from "token-savior-recall[mcp]" token-savior
}

install_token_optimizer_mcp() {
    require_cmd npx
    local mcp_list
    mcp_list="$(claude mcp list 2>/dev/null)" || true
    if echo "${mcp_list}" | grep -q "token-optimizer-mcp"; then
        log "token-optimizer-mcp MCP server already registered; skipping"
        return
    fi
    log "Registering token-optimizer-mcp MCP server"
    claude mcp add -s user token-optimizer-mcp -- npx -y @ooples/token-optimizer-mcp
}

install_ccusage() {
    require_cmd npm
    if ! command -v ccusage >/dev/null 2>&1; then
        log "Installing ccusage"
        npm install -g ccusage
    else
        log "ccusage already installed; skipping"
    fi
    local mcp_list
    mcp_list="$(claude mcp list 2>/dev/null)" || true
    if echo "${mcp_list}" | grep -q "ccusage"; then
        log "ccusage MCP server already registered; skipping"
        return
    fi
    log "Registering ccusage MCP server"
    claude mcp add -s user ccusage -- npx @ccusage/mcp@latest
}

install_tmux_from_source() {
    local required_major=3 required_minor=3
    if command -v tmux >/dev/null 2>&1; then
        local current_version
        local tmux_v_output tmux_v_word
        tmux_v_output="$(tmux -V)"
        tmux_v_word="$(awk '{print $2}' <<<"${tmux_v_output}")"
        current_version="${tmux_v_word%%[[:alpha:]]*}"
        local current_major current_minor
        current_major="$(echo "${current_version}" | cut -d. -f1)"
        current_minor="$(echo "${current_version}" | cut -d. -f2)"
        if ((current_major > required_major)) || ((current_major == required_major && current_minor >= required_minor)); then
            log "tmux ${current_version} already satisfies >= ${required_major}.${required_minor}; skipping"
            return
        fi
        log "tmux ${current_version} < ${required_major}.${required_minor}; building from source"
    else
        log "Installing tmux from source"
    fi
    local build_version="3.6b"
    local tarball="tmux-${build_version}.tar.gz"
    local build_dir
    build_dir="$(mktemp -d)"
    trap 'rm -rf "${build_dir}"; trap - RETURN' RETURN
    curl -fsSL "https://github.com/tmux/tmux/releases/download/${build_version}/${tarball}" \
        -o "${build_dir}/${tarball}"
    tar -C "${build_dir}" -xzf "${build_dir}/${tarball}"
    local cpu_count
    cpu_count="$(nproc)"
    (cd "${build_dir}/tmux-${build_version}" && ./configure && make -j"${cpu_count}" && sudo make install)
}

install_tmux_plugins() {
    require_cmd git
    local tpm_dir="${HOME}/.tmux/plugins/tpm"
    local catppuccin_dir="${HOME}/.config/tmux/plugins/catppuccin"
    if [[ -d "${tpm_dir}" ]]; then
        log "tmux plugin manager (tpm) already installed; skipping"
    else
        log "Installing tmux plugin manager (tpm)"
        mkdir -p "${HOME}/.tmux/plugins"
        git clone https://github.com/tmux-plugins/tpm "${tpm_dir}"
    fi
    if [[ -d "${catppuccin_dir}" ]]; then
        log "tmux catppuccin theme already installed; skipping"
    else
        log "Installing tmux catppuccin theme"
        mkdir -p "${HOME}/.config/tmux/plugins"
        git clone https://github.com/catppuccin/tmux.git "${catppuccin_dir}"
    fi
}

install_wezterm() {
    if command -v wezterm >/dev/null 2>&1; then
        log "WezTerm already installed; skipping"
        return
    fi
    log "Installing WezTerm"
    local os_name
    os_name="$(uname -s)"
    if [[ "${os_name}" == "Darwin" ]]; then
        brew install --cask wezterm
        return
    fi
    local os_arch
    os_arch="$(uname -m)"
    if [[ "${os_arch}" != "x86_64" ]]; then
        log "WezTerm: no official binary for ${os_arch}; skipping"
        return
    fi
    local ubuntu_version
    ubuntu_version="$(grep -m1 '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    curl -fsSL https://api.github.com/repos/wez/wezterm/releases/latest \
        -o "${tmp_dir}/release.json"
    local tag
    tag="$(grep -m1 '"tag_name"' "${tmp_dir}/release.json" | cut -d'"' -f4)"
    local deb="wezterm-${tag}.Ubuntu${ubuntu_version}.deb"
    curl -fsSL "https://github.com/wez/wezterm/releases/download/${tag}/${deb}" \
        -o "${tmp_dir}/${deb}"
    sudo dpkg -i "${tmp_dir}/${deb}"
    sudo apt-get install -f -y
}

install_mcp_manim() {
    require_cmd docker
    local mcp_list
    mcp_list="$(claude mcp list 2>/dev/null)" || true
    if echo "${mcp_list}" | grep -q "mcp-manim"; then
        log "mcp-manim MCP server already registered; skipping"
        return
    fi
    local gist_dir="${HOME}/.local/share/mcp-servers/manim"
    if [[ ! -d "${gist_dir}" ]]; then
        log "Cloning manim MCP gist"
        mkdir -p "${HOME}/.local/share/mcp-servers"
        git clone https://gist.github.com/AndrewAltimit/c437c9fbc9a72271969127fcbf935561 "${gist_dir}"
    fi
    log "Building manim MCP Docker image"
    docker compose -f "${gist_dir}/docker-compose.yml" build
    log "Registering mcp-manim MCP server"
    claude mcp add -s user mcp-manim -- docker run -i --rm manim-manim-mcp python3 /app/mcp_manim_tool.py --mode stdio
}

install_mcp_latex() {
    require_cmd docker
    local mcp_list
    mcp_list="$(claude mcp list 2>/dev/null)" || true
    if echo "${mcp_list}" | grep -q "mcp-latex"; then
        log "mcp-latex MCP server already registered; skipping"
        return
    fi
    local gist_dir="${HOME}/.local/share/mcp-servers/latex"
    if [[ ! -d "${gist_dir}" ]]; then
        log "Cloning latex MCP gist"
        mkdir -p "${HOME}/.local/share/mcp-servers"
        git clone https://gist.github.com/AndrewAltimit/99324d135251d8e80e0f130da8184d07 "${gist_dir}"
    fi
    log "Building latex MCP Docker image"
    docker compose -f "${gist_dir}/docker-compose.yml" build
    log "Registering mcp-latex MCP server"
    claude mcp add -s user mcp-latex -- docker run -i --rm latex-mcp-latex-server python3 /workspace/mcp_latex_tool.py
}

install_git_mcp() {
    require_cmd npx
    local mcp_list
    mcp_list="$(claude mcp list 2>/dev/null)" || true
    if echo "${mcp_list}" | grep -q "git-mcp"; then
        log "git-mcp MCP server already registered; skipping"
        return
    fi
    log "Registering git-mcp MCP server"
    claude mcp add -s user git-mcp -- npx mcp-remote https://gitmcp.io/docs
}

print_chezmoi_init_hint() {
    log "You can initialize chezmoi with: chezmoi init --apply git@github.com:benmandrew/dotfiles.git"
}
