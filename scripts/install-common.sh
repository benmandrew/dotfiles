#!/bin/bash

UPGRADE=""
_MCP_LIST_LOADED=false
MCP_LIST=""

get_mcp_list() {
    if [[ "${_MCP_LIST_LOADED}" != "true" ]]; then
        local claude_json="${HOME}/.claude.json"
        if [[ -f "${claude_json}" ]] && command -v python3 >/dev/null 2>&1; then
            MCP_LIST="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print('\n'.join(d.get('mcpServers', {}).keys()))
" "${claude_json}" 2>/dev/null)" || true
        else
            MCP_LIST="$(claude mcp list 2>/dev/null)" || true
        fi
        _MCP_LIST_LOADED=true
    fi
}

log() {
    if [[ "$*" == *"skipping"* ]]; then
        printf "\033[1;33m[install]\033[0m %s\n" "$*"
    elif [[ "$*" == *"pgrading"* ]]; then
        printf "\033[1;36m[install]\033[0m %s\n" "$*"
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

parse_args() {
    for arg in "$@"; do
        case "${arg}" in
            --upgrade) UPGRADE=true ;;
            *)
                err "Unknown argument: ${arg}. Usage: $0 [--upgrade]"
                exit 1
                ;;
        esac
    done
}

npm_install_g() {
    local npm_prefix
    npm_prefix="$(npm prefix -g 2>/dev/null)"
    if [[ -w "${npm_prefix}" ]]; then
        npm install -g "$@"
    else
        sudo npm install -g "$@"
    fi
}

# Wrapper around curl for GitHub API calls; adds auth header when GITHUB_TOKEN is set
# to avoid unauthenticated rate limits (60 req/hr) on shared CI runner IPs.
github_api_curl() {
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$@"
    else
        curl -fsSL "$@"
    fi
}

github_latest_tag() {
    local repo="$1"
    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "${tmp}"; trap - RETURN' RETURN
    github_api_curl "https://api.github.com/repos/${repo}/releases/latest" -o "${tmp}"
    local tag_line tag
    tag_line="$(grep -m1 '"tag_name"' "${tmp}" || true)"
    tag="${tag_line#*\"tag_name\": \"}"
    tag="${tag%%\"*}"
    echo "${tag}"
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

safe_git() {
    local dir="$1"
    shift
    git -c "safe.directory=${dir}" -C "${dir}" "$@"
}

ensure_user_owns() {
    local dir="$1"
    if [[ -d "${dir}" ]] && [[ ! -O "${dir}" ]]; then
        local user group
        user="$(id -un)"
        group="$(id -gn)"
        sudo chown -R "${user}:${group}" "${dir}"
    fi
}

load_cargo_env() {
    if [[ -f "${HOME}/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "${HOME}/.cargo/env"
    fi
}

install_zinit() {
    local zinit_home="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"
    if [[ -d "${zinit_home}/.git" ]]; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "zinit already installed; skipping"
            return
        fi
        log "Upgrading zinit"
        ensure_user_owns "${zinit_home}"
        safe_git "${zinit_home}" fetch origin
        safe_git "${zinit_home}" reset --hard origin/main
        return
    fi
    log "Installing zinit"
    mkdir -p "$(dirname "${zinit_home}")"
    git clone https://github.com/zdharma-continuum/zinit.git "${zinit_home}"
}

install_rust() {
    load_cargo_env
    if command -v cargo >/dev/null 2>&1 && command -v rustup >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "Rust already installed; skipping"
            return
        fi
        log "Upgrading Rust"
        rustup update
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
        if [[ -z "${UPGRADE:-}" ]]; then
            log "rust-analyzer already installed; skipping"
            return
        fi
        log "Upgrading rust-analyzer"
    else
        log "Installing rust-analyzer"
    fi
    require_cmd rustup
    rustup component add rust-analyzer
}

install_clangd() {
    if command -v clangd >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "clangd already installed; skipping"
            return
        fi
        log "Upgrading clangd"
        local os_name
        os_name="$(uname -s)"
        if [[ "${os_name}" == "Darwin" ]]; then
            brew upgrade llvm
        else
            sudo apt install -y clangd
        fi
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
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Darwin" ]]; then
        if [[ -z "${UPGRADE:-}" ]] && command -v cmake >/dev/null 2>&1; then
            local cmake_output current_version
            cmake_output="$(cmake --version)"
            current_version="$(awk 'NR==1{print $3}' <<<"${cmake_output}")"
            if version_gte "${current_version}" "${required_version}"; then
                log "cmake ${current_version} already satisfies >= ${required_version}; skipping"
                return
            fi
            log "cmake ${current_version} < ${required_version}; upgrading"
        elif [[ -n "${UPGRADE:-}" ]]; then
            log "Upgrading cmake"
        else
            log "Installing cmake"
        fi
        if brew list --formula cmake >/dev/null 2>&1; then
            brew upgrade cmake
        else
            brew install cmake
        fi
        return
    fi

    # Linux: binary download
    local install_version
    if [[ -n "${UPGRADE:-}" ]]; then
        local latest_tag
        latest_tag="$(github_latest_tag Kitware/CMake)"
        install_version="${latest_tag#v}"
        log "Upgrading cmake to ${install_version}"
    else
        install_version="${required_version}"
        if command -v cmake >/dev/null 2>&1; then
            local cmake_output current_version
            cmake_output="$(cmake --version)"
            current_version="$(awk 'NR==1{print $3}' <<<"${cmake_output}")"
            if version_gte "${current_version}" "${required_version}"; then
                log "cmake ${current_version} already satisfies >= ${required_version}; skipping"
                return
            fi
            log "cmake ${current_version} < ${required_version}; installing ${install_version}"
        else
            log "Installing cmake ${install_version}"
        fi
    fi

    local os_arch cmake_arch
    os_arch="$(uname -m)"
    if [[ "${os_arch}" == "aarch64" ]]; then
        cmake_arch="linux-aarch64"
    else
        cmake_arch="linux-x86_64"
    fi
    local installer="cmake-${install_version}-${cmake_arch}.sh"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    curl -fsSL "https://github.com/Kitware/CMake/releases/download/v${install_version}/${installer}" \
        -o "${tmp_dir}/${installer}"
    chmod +x "${tmp_dir}/${installer}"
    sudo sh "${tmp_dir}/${installer}" --prefix=/usr/local --skip-license
}

install_cargo_tool() {
    local cmd="$1" crate="${2:-$1}"
    if command -v "${cmd}" >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "${cmd} already installed; skipping"
            return
        fi
        log "Upgrading ${cmd}"
    else
        log "Installing ${cmd}"
    fi
    load_cargo_env
    require_cmd cargo
    cargo install "${crate}"
}

install_pyright() {
    if command -v pyright >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "pyright already installed; skipping"
            return
        fi
        log "Upgrading pyright"
    else
        log "Installing pyright"
    fi
    require_cmd npm
    npm_install_g pyright
}

install_eza() { install_cargo_tool eza; }
install_fd() { install_cargo_tool fd fd-find; }
install_bat() { install_cargo_tool bat; }

install_gh() {
    if command -v gh >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "GitHub CLI already installed; skipping"
            return
        fi
        log "Upgrading GitHub CLI"
        local os_name
        os_name="$(uname -s)"
        if [[ "${os_name}" == "Darwin" ]]; then
            brew upgrade gh
        else
            sudo apt install -y gh
        fi
        return
    fi
    log "Installing GitHub CLI"
    local os_name
    os_name="$(uname -s)"
    if [[ "${os_name}" == "Darwin" ]]; then
        brew install gh
        return
    fi
    sudo mkdir -p -m 755 /etc/apt/keyrings
    local tmp
    tmp="$(mktemp)"
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "${tmp}"
    sudo install -m 644 "${tmp}" /etc/apt/keyrings/githubcli-archive-keyring.gpg
    rm -f "${tmp}"
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    local arch
    arch="$(dpkg --print-architecture)"
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" |
        sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt update
    sudo apt install -y gh
}

install_zoxide() { install_cargo_tool zoxide; }

install_fzf() {
    if command -v fzf >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "fzf already installed; skipping"
            return
        fi
        log "Upgrading fzf"
        if [[ -d "${HOME}/.fzf" ]]; then
            ensure_user_owns "${HOME}/.fzf"
            safe_git "${HOME}/.fzf" pull
            "${HOME}/.fzf/install" --bin --no-update-rc --no-bash --no-fish
        fi
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

enable_nix_flakes() {
    local nix_conf="${HOME}/.config/nix/nix.conf"
    if [[ -f "${nix_conf}" ]] && grep -qE '^[[:space:]]*extra-experimental-features.*\bflakes\b|^[[:space:]]*experimental-features.*\bflakes\b' "${nix_conf}"; then
        return
    fi
    log "Enabling Nix flakes"
    mkdir -p "$(dirname "${nix_conf}")"
    echo "extra-experimental-features = nix-command flakes" >>"${nix_conf}"
}

install_nix() {
    if command -v nix >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "Nix already installed; skipping"
            enable_nix_flakes
            return
        fi
        log "Upgrading Nix"
        sudo -i nix upgrade-nix
        enable_nix_flakes
        return
    fi
    log "Installing Nix"
    local script_path
    script_path="$(mktemp)"
    curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install -o "${script_path}"
    sh "${script_path}" --daemon --yes
    rm -f "${script_path}"

    # shellcheck disable=SC1091
    [[ -f /etc/bashrc ]] && source /etc/bashrc
    # shellcheck disable=SC1091
    [[ -f "/etc/profile.d/nix.sh" ]] && source /etc/profile.d/nix.sh

    enable_nix_flakes
}

install_direnv() {
    if command -v direnv >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "direnv already installed; skipping"
            return
        fi
        log "Upgrading direnv"
    else
        log "Installing direnv"
    fi
    mkdir -p "${HOME}/.local/bin"
    local script_path
    script_path="$(mktemp)"
    curl -fsSL https://direnv.net/install.sh -o "${script_path}"
    bin_path="${HOME}/.local/bin" bash "${script_path}"
    rm -f "${script_path}"
}

_nix_profile_has() {
    local list
    list="$(nix profile list 2>/dev/null)"
    grep -qE "^Flake attribute:[[:space:]]+legacyPackages\.[^.]+\.$1\$" <<<"${list}"
}

install_modern_bash() {
    # nix-direnv requires bash >= 4.4; macOS ships bash 3.2 (GPLv2-only) as /bin/bash.
    local os_name
    os_name="$(uname -s)"
    if [[ "${os_name}" != "Darwin" ]]; then
        return
    fi
    require_cmd nix
    if _nix_profile_has bash; then
        if [[ -n "${UPGRADE:-}" ]]; then
            log "Upgrading bash"
            nix profile upgrade bash
        else
            log "Modern bash already installed; skipping"
        fi
        return
    fi
    log "Installing modern bash (nix-direnv requires >= 4.4)"
    nix profile install nixpkgs#bash
}

install_nix_direnv() {
    require_cmd nix
    install_modern_bash
    local direnvrc="${HOME}/.config/direnv/direnvrc"
    # shellcheck disable=SC2016
    local source_line='source $HOME/.nix-profile/share/nix-direnv/direnvrc'
    if _nix_profile_has nix-direnv; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "nix-direnv already installed; skipping"
        else
            log "Upgrading nix-direnv"
            nix profile upgrade nix-direnv
        fi
    else
        log "Installing nix-direnv"
        nix profile install nixpkgs#nix-direnv
    fi
    if [[ -f "${direnvrc}" ]] && grep -qF "nix-direnv/direnvrc" "${direnvrc}"; then
        return
    fi
    log "Wiring nix-direnv into direnvrc"
    mkdir -p "$(dirname "${direnvrc}")"
    echo "${source_line}" >>"${direnvrc}"
}

install_starship() {
    if command -v starship >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "Starship already installed; skipping"
            return
        fi
        log "Upgrading Starship"
    else
        log "Installing Starship"
    fi
    local script_path
    script_path="$(mktemp)"
    curl -sS https://starship.rs/install.sh -o "${script_path}"
    sh "${script_path}" -y
    rm -f "${script_path}"
}

install_claude_code() {
    if command -v claude >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "Claude Code already installed; skipping"
            return
        fi
        log "Upgrading Claude Code"
        npm_install_g @anthropic-ai/claude-code
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
        if [[ -z "${UPGRADE:-}" ]]; then
            log "rtk already installed; skipping"
            return
        fi
        log "Upgrading rtk"
    else
        log "Installing rtk"
    fi
    local script_path
    script_path="$(mktemp)"
    curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh -o "${script_path}"
    sh "${script_path}"
    rm -f "${script_path}"
}

install_uv() {
    if command -v uv >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "uv already installed; skipping"
            return
        fi
        log "Upgrading uv"
        uv self update
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
    get_mcp_list
    if echo "${MCP_LIST}" | grep -q "token-savior"; then
        log "token-savior MCP server already registered; skipping"
        return
    fi
    log "Registering token-savior MCP server"
    claude mcp add -s user token-savior -- uvx --python 3.11 --from "token-savior-recall[mcp]" token-savior
}

install_token_optimizer_mcp() {
    require_cmd npx
    get_mcp_list
    if echo "${MCP_LIST}" | grep -q "token-optimizer-mcp"; then
        log "token-optimizer-mcp MCP server already registered; skipping"
        return
    fi
    log "Registering token-optimizer-mcp MCP server"
    claude mcp add -s user token-optimizer-mcp -- npx -y @ooples/token-optimizer-mcp
}

install_ccusage() {
    require_cmd npm
    if command -v ccusage >/dev/null 2>&1; then
        if [[ -n "${UPGRADE:-}" ]]; then
            log "Upgrading ccusage"
            npm_install_g ccusage
        else
            log "ccusage already installed; skipping"
        fi
    else
        log "Installing ccusage"
        npm_install_g ccusage
    fi
    get_mcp_list
    if echo "${MCP_LIST}" | grep -q "ccusage"; then
        log "ccusage MCP server already registered; skipping"
        return
    fi
    log "Registering ccusage MCP server"
    claude mcp add -s user ccusage -- npx @ccusage/mcp@latest
}

install_tmux_from_source() {
    local required_major=3 required_minor=3
    local build_version

    if [[ -n "${UPGRADE:-}" ]]; then
        build_version="$(github_latest_tag tmux/tmux)"
        if command -v tmux >/dev/null 2>&1; then
            log "Upgrading tmux to ${build_version}"
        else
            log "Installing tmux ${build_version}"
        fi
    else
        build_version="3.6b"
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
    fi

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
    if [[ -d "${tpm_dir}" ]]; then
        if [[ -n "${UPGRADE:-}" ]]; then
            log "Upgrading tmux plugin manager (tpm)"
            ensure_user_owns "${tpm_dir}"
            safe_git "${tpm_dir}" fetch origin
            safe_git "${tpm_dir}" reset --hard origin/master
        else
            log "tmux plugin manager (tpm) already installed; skipping"
        fi
    else
        log "Installing tmux plugin manager (tpm)"
        mkdir -p "${HOME}/.tmux/plugins"
        git clone https://github.com/tmux-plugins/tpm "${tpm_dir}"
    fi
}

install_wezterm() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Linux" ]] && [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        log "WezTerm: no display session detected; skipping on headless Linux"
        return
    fi

    if command -v wezterm >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "WezTerm already installed; skipping"
            return
        fi
        log "Upgrading WezTerm"
        if [[ "${os_name}" == "Darwin" ]]; then
            brew upgrade --cask wezterm@nightly
            return
        fi
        # Linux: fall through to re-download latest
    else
        log "Installing WezTerm"
        if [[ "${os_name}" == "Darwin" ]]; then
            brew install --cask wezterm@nightly
            return
        fi
    fi

    # Linux binary download (install or upgrade via latest GitHub release)
    local os_arch
    os_arch="$(uname -m)"
    if [[ "${os_arch}" != "x86_64" ]]; then
        log "WezTerm: no official binary for ${os_arch}; skipping"
        return
    fi
    local ubuntu_version version_id_line
    version_id_line="$(grep -m1 '^VERSION_ID=' /etc/os-release || true)"
    ubuntu_version="${version_id_line#VERSION_ID=}"
    ubuntu_version="${ubuntu_version//\"/}"
    # WezTerm only publishes 20.04 and 22.04 packages; 22.04 works on newer Ubuntu
    if [[ "${ubuntu_version}" != "20.04" && "${ubuntu_version}" != "22.04" ]]; then
        ubuntu_version="22.04"
    fi
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    github_api_curl https://api.github.com/repos/wez/wezterm/releases/latest \
        -o "${tmp_dir}/release.json"
    local tag tag_line
    tag_line="$(grep -m1 '"tag_name"' "${tmp_dir}/release.json" || true)"
    tag="${tag_line#*\"tag_name\": \"}"
    tag="${tag%%\"*}"
    local deb="wezterm-${tag}.Ubuntu${ubuntu_version}.deb"
    curl -fsSL "https://github.com/wez/wezterm/releases/download/${tag}/${deb}" \
        -o "${tmp_dir}/${deb}"
    sudo apt-get install -y "${tmp_dir}/${deb}"
}

install_nerd_font() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Linux" ]] && [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        log "CodeNewRoman Nerd Font: no display session detected; skipping on headless Linux"
        return
    fi

    if [[ "${os_name}" == "Darwin" ]]; then
        if brew list --cask font-code-new-roman-nerd-font >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "CodeNewRoman Nerd Font already installed; skipping"
                return
            fi
            log "Upgrading CodeNewRoman Nerd Font"
            brew upgrade --cask font-code-new-roman-nerd-font
            return
        fi
        log "Installing CodeNewRoman Nerd Font"
        brew install --cask font-code-new-roman-nerd-font
        return
    fi

    # Linux: no cask equivalent; download the patched font from nerd-fonts releases
    require_cmd unzip
    local font_dir="${HOME}/.local/share/fonts/CodeNewRomanNerdFont"
    if [[ -d "${font_dir}" ]]; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "CodeNewRoman Nerd Font already installed; skipping"
            return
        fi
        log "Upgrading CodeNewRoman Nerd Font"
    else
        log "Installing CodeNewRoman Nerd Font"
    fi
    local tag
    tag="$(github_latest_tag ryanoasis/nerd-fonts)"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    curl -fsSL "https://github.com/ryanoasis/nerd-fonts/releases/download/${tag}/CodeNewRoman.zip" \
        -o "${tmp_dir}/CodeNewRoman.zip"
    mkdir -p "${font_dir}"
    unzip -oq "${tmp_dir}/CodeNewRoman.zip" -d "${font_dir}"
    fc-cache -f "${font_dir}" >/dev/null 2>&1 || true
}

install_mcp_manim() {
    require_cmd docker
    local gist_dir="${HOME}/.local/share/mcp-servers/manim"
    get_mcp_list
    if echo "${MCP_LIST}" | grep -q "mcp-manim"; then
        if [[ -n "${UPGRADE:-}" ]]; then
            log "Upgrading mcp-manim"
            if [[ -d "${gist_dir}" ]]; then
                ensure_user_owns "${gist_dir}"
                safe_git "${gist_dir}" pull
            fi
            docker compose -f "${gist_dir}/docker-compose.yml" build
            return
        fi
        log "mcp-manim MCP server already registered; skipping"
        return
    fi
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
    local gist_dir="${HOME}/.local/share/mcp-servers/latex"
    get_mcp_list
    if echo "${MCP_LIST}" | grep -q "mcp-latex"; then
        if [[ -n "${UPGRADE:-}" ]]; then
            log "Upgrading mcp-latex"
            if [[ -d "${gist_dir}" ]]; then
                ensure_user_owns "${gist_dir}"
                safe_git "${gist_dir}" pull
            fi
            docker compose -f "${gist_dir}/docker-compose.yml" build
            return
        fi
        log "mcp-latex MCP server already registered; skipping"
        return
    fi
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

install_tailscale() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Darwin" ]]; then
        if brew list --cask tailscale >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "Tailscale already installed; skipping"
                return
            fi
            log "Upgrading Tailscale"
            brew upgrade --cask tailscale
            return
        fi
        log "Installing Tailscale"
        brew install --cask tailscale
        return
    fi

    if command -v tailscale >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "Tailscale already installed; skipping"
            return
        fi
        log "Upgrading Tailscale"
    else
        log "Installing Tailscale"
    fi
    local script_path
    script_path="$(mktemp)"
    curl -fsSL https://tailscale.com/install.sh -o "${script_path}"
    sh "${script_path}"
    rm -f "${script_path}"
}

install_mullvad() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Linux" ]] && [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        log "Mullvad: no display session detected; skipping on headless Linux"
        return
    fi

    if [[ "${os_name}" == "Darwin" ]]; then
        if brew list --cask mullvadvpn >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "Mullvad already installed; skipping"
                return
            fi
            log "Upgrading Mullvad"
            brew upgrade --cask mullvadvpn
            return
        fi
        log "Installing Mullvad"
        brew install --cask mullvadvpn
        return
    fi

    if command -v mullvad >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "Mullvad already installed; skipping"
            return
        fi
        log "Upgrading Mullvad"
        sudo apt install -y mullvad-vpn
        return
    fi
    log "Installing Mullvad"
    sudo mkdir -p -m 755 /etc/apt/keyrings
    local mullvad_keyring
    mullvad_keyring="$(curl -fsSL https://repository.mullvad.net/deb/stable/mullvad-keyring.asc)"
    echo "${mullvad_keyring}" | sudo gpg --dearmor -o /usr/share/keyrings/mullvad-keyring.gpg
    local arch codename_line codename
    arch="$(dpkg --print-architecture)"
    codename_line="$(grep -m1 '^VERSION_CODENAME=' /etc/os-release || true)"
    codename="${codename_line#VERSION_CODENAME=}"
    codename="${codename//\"/}"
    echo "deb [signed-by=/usr/share/keyrings/mullvad-keyring.gpg arch=${arch}] https://repository.mullvad.net/deb/stable ${codename} main" |
        sudo tee /etc/apt/sources.list.d/mullvad.list >/dev/null
    sudo apt update
    sudo apt install -y mullvad-vpn
}

install_git_mcp() {
    require_cmd npx
    get_mcp_list
    if echo "${MCP_LIST}" | grep -q "git-mcp"; then
        log "git-mcp MCP server already registered; skipping"
        return
    fi
    log "Registering git-mcp MCP server"
    claude mcp add -s user git-mcp -- npx mcp-remote https://gitmcp.io/docs
}

install_lua_ls() {
    local os_name
    os_name="$(uname -s)"

    if command -v lua-language-server >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "lua-language-server already installed; skipping"
            return
        fi
        log "Upgrading lua-language-server"
        if [[ "${os_name}" == "Darwin" ]]; then
            brew upgrade lua-language-server
            return
        fi
        # Linux: fall through to re-download latest
    else
        log "Installing lua-language-server"
        if [[ "${os_name}" == "Darwin" ]]; then
            brew install lua-language-server
            return
        fi
    fi

    # Linux binary download (install or upgrade via latest GitHub release)
    local os_arch lua_arch
    os_arch="$(uname -m)"
    if [[ "${os_arch}" == "aarch64" ]]; then
        lua_arch="linux-arm64"
    else
        lua_arch="linux-x64"
    fi
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    github_api_curl https://api.github.com/repos/LuaLS/lua-language-server/releases/latest \
        -o "${tmp_dir}/release.json"
    local tag tag_line
    tag_line="$(grep -m1 '"tag_name"' "${tmp_dir}/release.json" || true)"
    tag="${tag_line#*\"tag_name\": \"}"
    tag="${tag%%\"*}"
    local archive="lua-language-server-${tag}-${lua_arch}.tar.gz"
    local install_dir="${HOME}/.local/opt/lua-language-server"
    mkdir -p "${install_dir}"
    curl -fsSL "https://github.com/LuaLS/lua-language-server/releases/download/${tag}/${archive}" \
        -o "${tmp_dir}/${archive}"
    tar -xzf "${tmp_dir}/${archive}" -C "${install_dir}"
    ln -sf "${install_dir}/bin/lua-language-server" "${HOME}/.local/bin/lua-language-server"
}

_opam_sandboxing_works() {
    bwrap --bind / / --dev-bind /dev /dev --proc /proc true 2>/dev/null
}

install_opam() {
    local os_name
    os_name="$(uname -s)"

    if command -v opam >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "opam already installed; skipping"
        else
            log "Upgrading opam"
            if [[ "${os_name}" == "Darwin" ]]; then
                brew upgrade opam
            fi
            # Linux: fall through to re-download latest
        fi
    else
        log "Installing opam"
        if [[ "${os_name}" == "Darwin" ]]; then
            brew install opam
        else
            # Linux: download latest binary from GitHub releases
            local os_arch opam_arch
            os_arch="$(uname -m)"
            if [[ "${os_arch}" == "aarch64" ]]; then
                opam_arch="arm64"
            else
                opam_arch="x86_64"
            fi
            local tag version binary install_dir
            tag="$(github_latest_tag ocaml/opam)"
            version="${tag#v}"
            binary="opam-${version}-${opam_arch}-linux"
            install_dir="${HOME}/.local/bin"
            mkdir -p "${install_dir}"
            curl -fsSL "https://github.com/ocaml/opam/releases/download/${tag}/${binary}" \
                -o "${install_dir}/opam"
            chmod +x "${install_dir}/opam"
        fi
    fi

    # Initialise opam root (idempotent: skip if ~/.opam already exists)
    if [[ -d "${HOME}/.opam" ]]; then
        log "opam already initialised; skipping opam init"
        return
    fi
    local init_flags=(--bare --yes --no-setup)
    if ! _opam_sandboxing_works; then
        log "bwrap sandboxing unavailable (container/VM); initialising opam with --disable-sandboxing"
        init_flags+=(--disable-sandboxing)
    fi
    opam init "${init_flags[@]}"
}

print_chezmoi_init_hint() {
    log "You can initialize chezmoi with: chezmoi init --apply git@github.com:benmandrew/dotfiles.git"
}
