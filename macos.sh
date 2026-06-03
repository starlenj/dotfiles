#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config
# -----------------------------
REPO_SSH="git@github.com:starlenj/dotfiles.git"
DOTDIR="$HOME/dotfiles"

REPO_ZSHRC_REL="zshrc"
REPO_TMUX_REL="tmux.conf"

# Neovim + LazyVim
REQUIRED_NVIM_VERSION="0.11.2"
NVIM_INSTALL_DIR="/usr/local/nvim"
NVIM_CONFIG_DIR="$HOME/.config/nvim"
LAZYVIM_REPO="https://github.com/LazyVim/starter"

# macOS arch detection
ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  NVIM_TARBALL_URL="https://github.com/neovim/neovim/releases/latest/download/nvim-macos-arm64.tar.gz"
  NVIM_EXTRACTED_DIR="nvim-macos-arm64"
else
  NVIM_TARBALL_URL="https://github.com/neovim/neovim/releases/latest/download/nvim-macos-x86_64.tar.gz"
  NVIM_EXTRACTED_DIR="nvim-macos-x86_64"
fi

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
ensure_homebrew_packages() {
  log "Checking Homebrew"
  if ! have brew; then
    log "Installing Homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Homebrew PATH (Apple Silicon)
    if [[ "$ARCH" == "arm64" ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
      if ! grep -qF 'brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
      fi
    fi
  else
    log "Homebrew already installed"
    brew update
  fi

  log "Installing required packages (brew)"
  brew install git curl wget unzip zsh tmux
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

  cp -f "$repo_zsh"  "$HOME/.zshrc"
  cp -f "$repo_tmux" "$HOME/.tmux.conf"
}

patch_zshrc_paths() {
  local z="$HOME/.zshrc"
  [[ -f "$z" ]] || return 0

  log "Patching ~/.zshrc to be portable (\$HOME-aware)"

  # /home/<user> ve /Users/<user> -> $HOME
  sed -i '' -E 's|/home/[^/]+/\.oh-my-zsh|\$HOME/.oh-my-zsh|g'  "$z"
  sed -i '' -E 's|/Users/[^/]+/\.oh-my-zsh|\$HOME/.oh-my-zsh|g' "$z"

  if grep -qE '^[[:space:]]*export[[:space:]]+ZSH=' "$z"; then
    sed -i '' -E 's|^[[:space:]]*export[[:space:]]+ZSH=.*$|export ZSH="$HOME/.oh-my-zsh"|' "$z"
  fi

  if ! grep -qE '^[[:space:]]*export[[:space:]]+ZSH=' "$z"; then
    local tmp; tmp="$(mktemp)"
    { echo 'export ZSH="$HOME/.oh-my-zsh"'; echo ''; cat "$z"; } > "$tmp"
    mv "$tmp" "$z"
  fi

  sed -i '' -E 's|source[[:space:]]+["'"'"']?\$HOME/\.oh-my-zsh/oh-my-zsh\.sh["'"'"']?|source "$ZSH/oh-my-zsh.sh"|g'          "$z"
  sed -i '' -E 's|source[[:space:]]+["'"'"']?\$ZSH/oh-my-zsh\.sh["'"'"']?|source "$ZSH/oh-my-zsh.sh"|g'                        "$z"
  sed -i '' -E 's|source[[:space:]]+["'"'"']?/home/[^/]+/\.oh-my-zsh/oh-my-zsh\.sh["'"'"']?|source "$ZSH/oh-my-zsh.sh"|g'     "$z"
  sed -i '' -E 's|source[[:space:]]+["'"'"']?/Users/[^/]+/\.oh-my-zsh/oh-my-zsh\.sh["'"'"']?|source "$ZSH/oh-my-zsh.sh"|g'    "$z"
}

install_oh_my_zsh_and_plugins() {
  export RUNZSH=no
  export CHSH=no
  export KEEP_ZSHRC=yes

  # --- Oh My Zsh ---
  if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    log "Installing Oh My Zsh"
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  else
    log "Oh My Zsh already installed"
  fi

  local ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

  # --- Powerlevel10k ---
  log "Ensuring powerlevel10k theme is installed"
  if [[ ! -d "$ZSH_CUSTOM/themes/powerlevel10k" ]]; then
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
      "$ZSH_CUSTOM/themes/powerlevel10k"
    log "powerlevel10k cloned"
  else
    log "powerlevel10k already present — pulling latest"
    git -C "$ZSH_CUSTOM/themes/powerlevel10k" pull --ff-only || true
  fi

  # ZSH_THEME'yi powerlevel10k olarak ayarla
  local z="$HOME/.zshrc"
  if grep -qE '^[[:space:]]*ZSH_THEME=' "$z"; then
    sed -i '' -E 's|^[[:space:]]*ZSH_THEME=.*$|ZSH_THEME="powerlevel10k/powerlevel10k"|' "$z"
    log "ZSH_THEME -> powerlevel10k/powerlevel10k"
  else
    echo '' >> "$z"
    echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> "$z"
    log "ZSH_THEME appended to ~/.zshrc"
  fi

  # p10k instant prompt (en üste ekle)
  if ! grep -qF 'p10k-instant-prompt' "$z"; then
    local tmp; tmp="$(mktemp)"
    cat > "$tmp" <<'BLOCK'
# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

BLOCK
    cat "$z" >> "$tmp"
    mv "$tmp" "$z"
    log "p10k instant prompt block added to top of ~/.zshrc"
  fi

  # p10k config source satırı
  if ! grep -qF 'p10k.zsh' "$z"; then
    echo '' >> "$z"
    echo '# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.' >> "$z"
    echo '[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh' >> "$z"
    log "p10k source line added to ~/.zshrc"
  fi

  # --- zsh-autosuggestions ---
  log "Ensuring zsh-autosuggestions is installed"
  if [[ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]]; then
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
      "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
  else
    git -C "$ZSH_CUSTOM/plugins/zsh-autosuggestions" pull --ff-only || true
  fi

  # --- zsh-syntax-highlighting ---
  log "Ensuring zsh-syntax-highlighting is installed"
  if [[ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]]; then
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
      "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
  else
    git -C "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" pull --ff-only || true
  fi
}

install_tpm_and_tmux_plugins() {
  log "Installing TPM (Tmux Plugin Manager)"
  local TPM_DIR="$HOME/.tmux/plugins/tpm"

  if [[ ! -d "$TPM_DIR" ]]; then
    git clone --depth=1 https://github.com/tmux-plugins/tpm "$TPM_DIR"
    log "TPM cloned to $TPM_DIR"
  else
    log "TPM already present — pulling latest"
    git -C "$TPM_DIR" pull --ff-only || true
  fi

  # ~/.tmux.conf'ta TPM source satırı yoksa ekle
  local tc="$HOME/.tmux.conf"
  if [[ -f "$tc" ]] && ! grep -qF 'tpm/tpm' "$tc"; then
    log "Adding TPM source lines to ~/.tmux.conf"
    cat >> "$tc" <<'TMUX'

# TPM - Tmux Plugin Manager
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'

# Initialize TPM (keep this line at the very bottom of tmux.conf)
run '~/.tmux/plugins/tpm/tpm'
TMUX
  fi

  log "Installing tmux plugins via TPM (best effort)"
  tmux start-server || true
  "$TPM_DIR/bin/install_plugins" || true
  "$TPM_DIR/bin/update_plugins" all || true
}

set_default_shell_zsh() {
  log "Setting zsh as default shell"
  local zsh_path
  zsh_path="$(command -v zsh)"

  # macOS: /etc/shells listesine ekle (gerekirse)
  if ! grep -qF "$zsh_path" /etc/shells; then
    log "Adding $zsh_path to /etc/shells"
    echo "$zsh_path" | sudo tee -a /etc/shells
  fi

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
    warn "Neovim is too old (< $REQUIRED_NVIM_VERSION); upgrading via official release"
  else
    warn "Neovim not found; installing via official release"
  fi

  brew uninstall neovim 2>/dev/null || true

  local tmpdir
  tmpdir="$(mktemp -d)"

  log "Downloading Neovim from: $NVIM_TARBALL_URL"
  curl -fsSL "$NVIM_TARBALL_URL" -o "$tmpdir/nvim.tar.gz"

  log "Extracting"
  tar -xzf "$tmpdir/nvim.tar.gz" -C "$tmpdir"
  xattr -cr "$tmpdir/$NVIM_EXTRACTED_DIR" 2>/dev/null || true

  if [[ ! -d "$tmpdir/$NVIM_EXTRACTED_DIR" ]]; then
    rm -rf "$tmpdir"
    warn "Unexpected archive layout; cannot find $NVIM_EXTRACTED_DIR"
    exit 1
  fi

  log "Installing to $NVIM_INSTALL_DIR (sudo)"
  sudo rm -rf "$NVIM_INSTALL_DIR"
  sudo mv "$tmpdir/$NVIM_EXTRACTED_DIR" "$NVIM_INSTALL_DIR"
  rm -rf "$tmpdir"

  log "Creating symlink /usr/local/bin/nvim -> $NVIM_INSTALL_DIR/bin/nvim"
  sudo mkdir -p /usr/local/bin
  sudo ln -sfn "$NVIM_INSTALL_DIR/bin/nvim" /usr/local/bin/nvim

  if ! grep -qF "$NVIM_INSTALL_DIR/bin" "$HOME/.zshrc"; then
    log "Adding Neovim PATH to ~/.zshrc"
    {
      echo ""
      echo "# Neovim (installed by bootstrap)"
      echo "export PATH=\"$NVIM_INSTALL_DIR/bin:\$PATH\""
    } >> "$HOME/.zshrc"
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

# -----------------------------
# Main
# -----------------------------
main() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    warn "Bu script macOS için tasarlanmıştır. Çıkılıyor."
    exit 1
  fi

  ensure_homebrew_packages
  clone_or_pull_repo
  replace_configs
  patch_zshrc_paths
  install_oh_my_zsh_and_plugins
  install_tpm_and_tmux_plugins
  set_default_shell_zsh
  install_or_update_neovim
  install_lazyvim_last

  log "✅ Done!"
  echo ""
  echo "Next steps:"
  echo "  1. Yeni shell oturumu başlat  : exec zsh -l"
  echo "  2. p10k wizard (otomatik gelir, gelmezse): p10k configure"
  echo "  3. tmux pluginleri gelmediyse : tmux aç -> prefix + I"
  echo "  4. LazyVim başlat             : nvim"
}

main "$@"
