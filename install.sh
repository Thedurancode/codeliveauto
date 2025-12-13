#!/bin/bash

set -euo pipefail

# ========================
#       CONFIG / CONSTANTS
# ========================
SCRIPT_NAME=$(basename "$0")

NODE_MIN_VERSION=18
NODE_INSTALL_VERSION=22
CLAUDE_PACKAGE="@anthropic-ai/claude-code"

CONFIG_DIR="$HOME/.claude"
CONFIG_FILE="$CONFIG_DIR/settings.json"

API_BASE_URL="https://api.z.ai/api/anthropic"
API_TIMEOUT_MS=3000000

# These will be filled by interactive prompts
AUTO_API_KEY=""
CONTEXT7_API_KEY=""

# Automatically run CodeLive when connecting via Termius
ENABLE_TERMIUS_AUTOSTART=true

# Disable Ubuntu login noise
DISABLE_LOGIN_NOISE=true

# ========================
#       HELPERS
# ========================

log() {
  echo "[${SCRIPT_NAME}] $*"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

detect_package_manager() {
  if have_cmd apt-get; then
    echo "apt-get"
  elif have_cmd brew; then
    echo "brew"
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS without brew, install it
    echo "brew-install"
  else
    log "Unsupported OS. Please install on Ubuntu/Debian or macOS."
    exit 1
  fi
}

# ========================
#   DEPENDENCIES / NODE
# ========================

install_base_packages() {
  local PM
  PM=$(detect_package_manager)

  case "$PM" in
    "apt-get")
      log "Updating package index..."
      sudo "$PM" update -y
      log "Installing curl, ca-certificates, gnupg, build-essential..."
      sudo "$PM" install -y curl ca-certificates gnupg build-essential
      ;;
    "brew-install")
      log "Installing Homebrew..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      # Add brew to PATH for current session
      if [[ -x "/opt/homebrew/bin/brew" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      elif [[ -x "/usr/local/bin/brew" ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
      fi
      ;;
    "brew")
      log "Homebrew is already installed."
      log "Updating Homebrew..."
      brew update
      log "Installing curl, gnupg..."
      brew install curl gnupg
      ;;
  esac
}

install_node() {
  local PM
  PM=$(detect_package_manager)

  if have_cmd node; then
    local CURRENT_NODE
    CURRENT_NODE=$(node -v | sed 's/^v//; s/\..*//')
    if [ "$CURRENT_NODE" -ge "$NODE_MIN_VERSION" ]; then
      log "Node $(node -v) already >= $NODE_MIN_VERSION"
      return
    fi
  fi

  case "$PM" in
    "apt-get")
      log "Installing Node.js $NODE_INSTALL_VERSION.x..."
      curl -fsSL "https://deb.nodesource.com/setup_${NODE_INSTALL_VERSION}.x" | sudo -E bash -
      sudo "$PM" install -y nodejs
      ;;
    "brew"|"brew-install")
      log "Installing Node.js $NODE_INSTALL_VERSION.x..."
      # Ensure brew is in PATH
      if have_cmd brew; then
        brew install node
      else
        log "Homebrew not found in PATH. Please restart your terminal or run:"
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || eval "$(/usr/local/bin/brew shellenv)"'
        exit 1
      fi
      ;;
  esac

  if ! have_cmd node; then
    log "Node installation failed."
    exit 1
  fi

  log "Installed Node $(node -v)"
}

# ========================
#    PROMPT FOR KEYS
# ========================

prompt_for_keys() {
  # Required: CodeLive key (used as Z.AI API key)
  while [ -z "${AUTO_API_KEY:-}" ]; do
    echo
    read -r -s -p "Enter your CodeLive API key (required): " AUTO_API_KEY
    echo
    if [ -z "$AUTO_API_KEY" ]; then
      echo "CodeLive API key is required. Please try again."
    fi
  done

  # Optional: Context7 key
  echo
  read -r -s -p "Enter your Context7 API key (optional, press Enter to skip): " CONTEXT7_API_KEY || true
  echo

  if [ -n "$CONTEXT7_API_KEY" ]; then
    log "Context7 key provided (stored in config, not echoed)."
  else
    log "No Context7 key provided. Context7 MCP will be skipped."
  fi
}

# ========================
#          PATH FIX
# ========================

fix_path() {
  log "Ensuring ~/.local/bin and npm global bin are on PATH..."

  # Detect shell profile file
  local PROFILE=""
  if [[ -f "$HOME/.bashrc" ]]; then
    PROFILE="$HOME/.bashrc"
  elif [[ -f "$HOME/.zshrc" ]]; then
    PROFILE="$HOME/.zshrc"
  elif [[ -f "$HOME/.bash_profile" ]]; then
    PROFILE="$HOME/.bash_profile"
  elif [[ -f "$HOME/.profile" ]]; then
    PROFILE="$HOME/.profile"
  fi

  # Add ~/.local/bin to PATH
  if [ -n "$PROFILE" ]; then
    if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$PROFILE" 2>/dev/null; then
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$PROFILE"
    fi
  fi

  # Add npm global bin to PATH
  local NPM_BIN
  NPM_BIN=$(npm bin -g 2>/dev/null || true)
  if [ -n "$NPM_BIN" ]; then
    if [ -n "$PROFILE" ]; then
      if ! grep -q "export PATH=\"$NPM_BIN:\$PATH\"" "$PROFILE" 2>/dev/null; then
        echo "export PATH=\"$NPM_BIN:\$PATH\"" >> "$PROFILE"
      fi
    fi
    export PATH="$NPM_BIN:$PATH"
  fi

  export PATH="$HOME/.local/bin:$PATH"
  log "PATH updated: $PATH"
}

# ========================
#     INSTALL CLAUDE
# ========================

install_claude() {
  log "Installing Claude Code..."

  sudo npm install -g "$CLAUDE_PACKAGE"

  if ! have_cmd claude; then
    log "Claude installation failed."
    exit 1
  fi

  log "Claude installed successfully."
}

# ========================
#     CLAUDE CONFIG
# ========================

write_claude_config() {
  log "Writing Claude Config with MCP servers..."

  mkdir -p "$CONFIG_DIR"

  # Build optional Context7 block
  local CONTEXT7_BLOCK=""
  if [ -n "$CONTEXT7_API_KEY" ]; then
    CONTEXT7_BLOCK=$(cat <<EOC
    ,
    "context7": {
      "type": "http",
      "url": "https://mcp.context7.com/mcp",
      "headers": {
        "CONTEXT7_API_KEY": "$CONTEXT7_API_KEY"
      }
    }
EOC
)
  fi

  cat > "$CONFIG_FILE" <<EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "$API_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN": "$AUTO_API_KEY"
  },
  "timeout_ms": $API_TIMEOUT_MS,
  "trust_all_directories": true,
  "mcpServers": {
    "sequential-thinking": {
      "type": "stdio",
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-sequential-thinking"
      ],
      "env": {
        "DISABLE_THOUGHT_LOGGING": "true"
      }
    $CONTEXT7_BLOCK
  }
}
EOF

  chmod 600 "$CONFIG_FILE"

  log "Claude config created with MCP servers."
}

# ========================
#   CODELIVE WRAPPER CMD
# ========================

install_codelive_wrapper() {
  log "Creating codelive wrapper..."

  sudo tee /usr/local/bin/codelive >/dev/null <<'EOF'
#!/bin/bash

# ---------- CodeLive Banner ----------
cat <<'BANNER'

   ______          __      _      _           
  / ____/___  ____/ /___  | |    (_)___  ___  
 / /   / __ \/ __  / __ \ | |   / / __ \/ _ \ 
/ /___/ /_/ / /_/ / /_/ / | |__/ / / / /  __/ 
\____/\____/\__,_/\____/  |____/_/ /_/ \___/  

                Welcome to CodeLive
      Your personal AI-powered development cloud
                 Developer: Ed Duran

BANNER
# -------------------------------------

sleep 0.7
claude "$@"
EOF

  sudo chmod +x /usr/local/bin/codelive
  log "codelive command ready."
}

# ========================
#   TERMIUS AUTO-START
# ========================

setup_termius_autostart() {
  if [ "$ENABLE_TERMIUS_AUTOSTART" != "true" ]; then
    return
  fi

  local BASHRC="$HOME/.bashrc"
  local MARKER="# >>> codelive termius auto-start >>>"

  if [ -f "$BASHRC" ] && grep -q "$MARKER" "$BASHRC" 2>/dev/null; then
    log "Termius auto-start already enabled."
    return
  fi

  cat >> "$BASHRC" <<'EOF'

# >>> codelive termius auto-start >>>
if [[ -n "$SSH_CLIENT" ]] && [[ "$SSH_CLIENT" == *"Termius"* ]]; then
  if command -v codelive >/dev/null 2>&1; then
    codelive
  fi
fi
# <<< codelive termius auto-start <<<
EOF

  log "Termius auto-start enabled."
}

# ========================
#   REMOVE LOGIN NOISE
# ========================

disable_login_noise() {
  if [ "$DISABLE_LOGIN_NOISE" != "true" ]; then
    return
  fi

  log "Removing Ubuntu login banners and noise..."

  # Disable dynamic MOTD scripts
  if [ -d /etc/update-motd.d ]; then
    sudo chmod -x /etc/update-motd.d/* || true
  fi

  # Remove motd files
  sudo rm -f /etc/motd /var/run/motd.dynamic || true

  # Disable cloud-init motd if present
  sudo touch /etc/cloud/cloud-init.disabled 2>/dev/null || true

  # Disable MOTD + lastlog in sshd_config
  if [ -f /etc/ssh/sshd_config ]; then
    sudo sed -i 's/^#\?PrintLastLog .*/PrintLastLog no/' /etc/ssh/sshd_config
    sudo sed -i 's/^#\?PrintMotd .*/PrintMotd no/' /etc/ssh/sshd_config
    sudo systemctl restart ssh || sudo systemctl restart sshd || true
  fi

  log "Login noise disabled."
}

# ========================
#           MAIN
# ========================

main() {
  log "Starting FULL CodeLive Installer..."

  install_base_packages
  install_node
  prompt_for_keys
  fix_path
  install_claude
  write_claude_config
  install_codelive_wrapper
  setup_termius_autostart
  disable_login_noise

  log "Installation COMPLETE!"
  log "Run manually:  codelive"
  log "SSH via Termius → auto-launch CodeLive"
}

main "$@"
