#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config
# -----------------------------
REPO_SSH="git@github.com:starlenj/dotfiles.git"
DOTDIR="$HOME/dotfiles"

# Repo içindeki dosya isimleri (gerekirse değiştir)
REPO_ZSHRC_REL="zshrc"       # örn: ".zshrc" ise bunu değiştir
REPO_TMUX_REL="tmux.conf"    # örn: ".tmux.conf" ise bunu değiştir

# Neovim + LazyVim
REQUIRED_NVIM_VERSION="0.11.2"
NVIM_INSTALL_DIR="/opt/nvim"
NVIM_TARBALL_URL="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz"
NVIM_CONFIG_DIR="$HOME/.config/nvim"
LAZYVIM_REPO="https://github.com/LazyVim/starter"

# -----------------------------
# Helpers
# -----------------------------
log()  { printf "\n\033[1;32m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m!!\033[0m %s\n" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

backup_path() {
  local p="$1"
  if [[ -e "$p" || -L "$p" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    mv -f "$p" "${p}.bak.${ts}"
    warn "Backed up $p -> ${p}.bak.${ts}"
  fi
}

# version_lt A B  => A < B ?
version_lt() {
  [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$2" ]]
}

# -----------------------------
# Steps
# -----------------------------
ensure_apt_packages() {
  log "Installing required packages (apt)"
  sudo apt-get update -y
  sudo apt-get install -y \
    git curl wget unzip ca-certificates \
    zsh tmux
}

clone_or_pull_repo() {
  if [[ -d "$DOTDIR/.git" ]]; then
    log "Updating dotfiles repo: $DOTDIR"
    git -C "$DOTDIR" pull --ff-only
  else
    log "Cloning dotfiles repo to: $DOTDIR"
    git clone "$REPO_SSH" "$DOTDIR"
  fi
}

replace_configs() {
  local repo_zsh="$DOTDIR/$REPO_ZSHRC_REL"
  local repo_tmux="$DOTDIR/$REPO_TMUX_REL"

  if [[ ! -f "$repo_zsh" ]]; then
    warn "Repo zshrc not found at: $repo_zsh"
    warn "Update REPO_ZSHRC_REL in the script to match your repo."
    exit 1
  fi
  if [[ ! -f "$repo_tmux" ]]; then
    warn "Repo tmux.conf not found at: $repo_tmux"
    warn "Update REPO_TMUX_REL in the script to match your repo."
    exit 1
  fi

  log "Replacing ~/.zshrc and ~/.tmux.conf with repo versions"
  backup_path "$HOME/.zshrc"
  backup_path "$HOME/.tmux.conf"

  cp -f "$repo_zsh" "$HOME/.zshrc"
  cp -f "$repo_tmux" "$HOME/.tmux.conf"
}

# --- FIX: make zshrc portable (remove /home/<user> hardcodes) ---
patch_zshrc_paths() {
  local z="$HOME/.zshrc"
  [[ -f "$z" ]] || return 0

  log "Patching ~/.zshrc to be portable ($HOME-aware)"

  # 1) Any /home/<user>/.oh-my-zsh -> $HOME/.oh-my-zsh
  #    (handles /home/starlenj, /home/neate, etc.)
  sed -i -E 's|/home/[^/]+/\.oh-my-zsh|\$HOME/.oh-my-zsh|g' "$z"

  # 2) Force export ZSH=... to $HOME/.oh-my-zsh (handles quotes/no quotes)
  if grep -qE '^[[:space:]]*export[[:space:]]+ZSH=' "$z"; then
    sed -i -E 's|^[[:space:]]*export[[:space:]]+ZSH=.*$|export ZSH="$HOME/.oh-my-zsh"|' "$z"
  fi

  # 3) If ZSH not set at all, add it near top (safe default)
  if ! grep -qE '^[[:space:]]*export[[:space:]]+ZSH=' "$z"; then
    # Add at the top (line 1)
    sed -i '1iexport ZSH="$HOME/.oh-my-zsh"\n' "$z"
  fi

  # 4) If it sources oh-my-zsh.sh using absolute path, normalize to $ZSH
  sed -i -E 's|source[[:space:]]+["'\'']?\$HOME/\.oh-my-zsh/oh-my-zsh\.sh["'\'']?|source "$ZSH/oh-my-zsh.sh"|g' "$z"
  sed -i -E 's|source[[:space:]]+["'\'']?\$ZSH/oh-my-zsh\.sh["'\'']?|source "$ZSH/oh-my-zsh.sh"|g' "$z"
  sed -i -E 's|source[[:space:]]+["'\'']?/home/[^/]+/\.oh-my-zsh/oh-my-zsh\.sh["'\'']?|source "$ZSH/oh-my-zsh.sh"|g' "$z"
}

install_oh_my_zsh_and_plugins() {
  export RUNZSH=no
  export CHSH=no
  export KEEP_ZSHRC=yes

  if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    log "Installing Oh My Zsh"
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  else
    log "Oh My Zsh already installed"
  fi

  local ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

  log "Ensuring powerlevel10k is installed"
  if [[ ! -d "$ZSH_CUSTOM/themes/powerlevel10k" ]]; then
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
      "$ZSH_CUSTOM/themes/powerlevel10k"
  fi

  log "Ensuring zsh-autosuggestions is installed"
  if [[ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]]; then
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
      "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
  fi
}

install_tpm_and_tmux_plugins() {
  log "Installing TPM"
  local TPM_DIR="$HOME/.tmux/plugins/tpm"
  if [[ ! -d "$TPM_DIR" ]]; then
    git clone --depth=1 https://github.com/tmux-plugins/tpm "$TPM_DIR"
  fi

  log "Installing tmux plugins (best effort)"
  tmux start-server || true
  "$TPM_DIR/bin/install_plugins" || true
  "$TPM_DIR/bin/update_plugins" all || true
}

set_default_shell_zsh() {
  log "Setting zsh as default shell (best effort)"
  if [[ "${SHELL:-}" != "$(command -v zsh)" ]]; then
    chsh -s "$(command -v zsh)" "$USER" || true
  fi
}

install_or_update_neovim() {
  log "Ensuring Neovim >= $REQUIRED_NVIM_VERSION"

  if have nvim; then
    local current
    current="$(nvim --version | head -n1 | awk '{print $2}' | sed 's/^v//')"
    log "Current Neovim: $current"
    if ! version_lt "$current" "$REQUIRED_NVIM_VERSION"; then
      log "Neovim version is OK"
      return 0
    fi
    warn "Neovim is too old (< $REQUIRED_NVIM_VERSION); upgrading via official release"
  else
    warn "Neovim not found; installing via official release"
  fi

  sudo apt-get remove -y neovim 2>/dev/null || true

  local tmpdir
  tmpdir="$(mktemp -d)"

  log "Downloading Neovim from: $NVIM_TARBALL_URL"
  curl -fsSL "$NVIM_TARBALL_URL" -o "$tmpdir/nvim.tar.gz"

  log "Extracting"
  tar -xzf "$tmpdir/nvim.tar.gz" -C "$tmpdir"

  if [[ ! -d "$tmpdir/nvim-linux-x86_64" ]]; then
    rm -rf "$tmpdir"
    warn "Unexpected archive layout; cannot find nvim-linux-x86_64"
    exit 1
  fi

  log "Installing to $NVIM_INSTALL_DIR (sudo)"
  sudo rm -rf "$NVIM_INSTALL_DIR"
  sudo mv "$tmpdir/nvim-linux-x86_64" "$NVIM_INSTALL_DIR"

  rm -rf "$tmpdir"

  log "Creating symlink /usr/local/bin/nvim -> $NVIM_INSTALL_DIR/bin/nvim"
  sudo mkdir -p /usr/local/bin
  sudo ln -sfn "$NVIM_INSTALL_DIR/bin/nvim" /usr/local/bin/nvim

  # Also add PATH to .zshrc as fallback
  if ! grep -qF "$NVIM_INSTALL_DIR/bin" "$HOME/.zshrc"; then
    log "Adding Neovim PATH to ~/.zshrc"
    echo "" >> "$HOME/.zshrc"
    echo "# Neovim (installed by bootstrap)" >> "$HOME/.zshrc"
    echo "export PATH=\"$NVIM_INSTALL_DIR/bin:\$PATH\"" >> "$HOME/.zshrc"
  fi

  log "Neovim installed:"
  nvim --version | head -n1
}

install_lazyvim_last() {
  log "Installing LazyVim (last step)"

  if ! have nvim; then
    warn "nvim not found; skipping LazyVim install"
    return 0
  fi

  local current
  current="$(nvim --version | head -n1 | awk '{print $2}' | sed 's/^v//')"
  if version_lt "$current" "$REQUIRED_NVIM_VERSION"; then
    warn "Neovim still too old ($current). LazyVim requires >= $REQUIRED_NVIM_VERSION"
    return 1
  fi

  mkdir -p "$HOME/.config"

  if [[ -e "$NVIM_CONFIG_DIR" || -L "$NVIM_CONFIG_DIR" ]]; then
    backup_path "$NVIM_CONFIG_DIR"
  fi

  git clone "$LAZYVIM_REPO" "$NVIM_CONFIG_DIR"

  log "LazyVim installed to $NVIM_CONFIG_DIR"
  echo "Tip: first run: nvim  (plugins will auto-install)"
}

main() {
  ensure_apt_packages
  clone_or_pull_repo
  replace_configs

  # Fix: repo zshrc hardcode paths -> portable
  patch_zshrc_paths

  install_oh_my_zsh_and_plugins
  install_tpm_and_tmux_plugins
  set_default_shell_zsh

  install_or_update_neovim
  install_lazyvim_last

  log "Done."
  echo "Next:"
  echo "  - Yeni shell oturumu için: exec zsh -l"
  echo "  - p10k gerekirse: p10k configure"
  echo "  - tmux pluginleri gelmediyse: tmux -> prefix + I"
  echo "  - LazyVim: nvim"
}

main "$@"
