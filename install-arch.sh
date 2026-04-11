
#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config
# -----------------------------
REPO_SSH="git@github.com:starlenj/dotfiles.git"
DOTDIR="$HOME/dotfiles"

# Repo içindeki dosya isimleri
REPO_ZSHRC_REL="zshrc"       # örn: ".zshrc" ise değiştir
REPO_TMUX_REL="tmux.conf"    # örn: ".tmux.conf" ise değiştir

# Neovim + LazyVim
REQUIRED_NVIM_VERSION="0.11.2"
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

version_lt() {
  [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$2" ]]
}

# -----------------------------
# Steps
# -----------------------------
ensure_pacman_packages() {
  log "Installing required packages (pacman)"
  sudo pacman -Syu --noconfirm

  sudo pacman -S --needed --noconfirm \
    git curl wget unzip ca-certificates \
    zsh tmux neovim base-devel \
    tar gzip
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

patch_zshrc_paths() {
  local z="$HOME/.zshrc"
  [[ -f "$z" ]] || return 0

  log "Patching ~/.zshrc to be portable ($HOME-aware)"

  sed -i -E 's|/home/[^/]+/\.oh-my-zsh|\$HOME/.oh-my-zsh|g' "$z"

  if grep -qE '^[[:space:]]*export[[:space:]]+ZSH=' "$z"; then
    sed -i -E 's|^[[:space:]]*export[[:space:]]+ZSH=.*$|export ZSH="$HOME/.oh-my-zsh"|' "$z"
  fi

  if ! grep -qE '^[[:space:]]*export[[:space:]]+ZSH=' "$z"; then
    sed -i '1iexport ZSH="$HOME/.oh-my-zsh"\n' "$z"
  fi

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
  local zsh_path
  zsh_path="$(command -v zsh)"

  if [[ "${SHELL:-}" != "$zsh_path" ]]; then
    chsh -s "$zsh_path" "$USER" || true
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

    warn "Neovim is too old (< $REQUIRED_NVIM_VERSION); upgrading via pacman"
    sudo pacman -S --needed --noconfirm neovim
  else
    warn "Neovim not found; installing via pacman"
    sudo pacman -S --needed --noconfirm neovim
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
  ensure_pacman_packages
  clone_or_pull_repo
  replace_configs
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
