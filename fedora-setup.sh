#!/usr/bin/env bash
#
# Fedora Post-Installation Setup Script
# 
# This script automates the setup of a fresh Fedora installation with:
# - Fish shell with Starship prompt
# - Font collection (FiraCode Nerd Font, Noto, DejaVu, Liberation, Inter)
# - RPM Fusion repositories (free, nonfree, and tainted)
# - Essential system tools and applications
# - Performance optimizations
# - Third-party applications (Chrome, 1Password, Zed, etc.)
# - Desktop environment detection (GNOME/KDE)
#
# Usage: ./fedora-setup.sh
#
# Author: Georgiy Timchenko
# License: MIT
# Repository: https://github.com/gtimchenko/fedora-setup

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

readonly SCRIPT_VERSION="1.3.0"
readonly LOG_FILE="$HOME/fedora-setup-$(date +%Y%m%d-%H%M%S).log"
readonly APPS_DIR="$HOME/Applications"
readonly PACKAGES_DIR="$HOME/packages"
readonly FONT_DIR="$HOME/.local/share/fonts"

# Font configuration
readonly FONT_NAME="FiraCode Nerd Font Mono"
readonly FONT_ZIP_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.zip"

# DNF configuration
readonly DNF_MAX_PARALLEL=10

# Desktop environment detection
DESKTOP_ENV=""

# Temporary files to clean up on exit
TEMP_FILES=()

# Background process keeping the sudo timestamp fresh
SUDO_KEEPALIVE_PID=""

cleanup() {
    for f in "${TEMP_FILES[@]}"; do
        rm -rf "$f" 2>/dev/null || true
    done
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ============================================================================
# Utility Functions
# ============================================================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2
}

log_success() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ✓ $*" | tee -a "$LOG_FILE"
}

# Colored output on the terminal, plain text in the log file
log_colored() {
    local color="$1"
    shift
    local msg
    msg="[$(date +'%Y-%m-%d %H:%M:%S')] $*"
    printf '\033[%sm%s\033[0m\n' "$color" "$msg"
    echo "$msg" >> "$LOG_FILE"
}

log_warning() {
    log_colored "1;33" "⚠ $*"
}

log_critical() {
    log_colored "1;31" "✗ $*"
}

log_section() {
    echo "" | tee -a "$LOG_FILE"
    echo "========================================" | tee -a "$LOG_FILE"
    echo "$*" | tee -a "$LOG_FILE"
    echo "========================================" | tee -a "$LOG_FILE"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_fedora() {
    if [[ ! -f /etc/fedora-release ]]; then
        log_error "This script is designed for Fedora. Exiting."
        exit 1
    fi
}

check_not_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "Do not run this script as root or via sudo; run it as your regular user. Exiting."
        exit 1
    fi
}

# Ask for the sudo password once and keep the timestamp fresh until the script exits
start_sudo_keepalive() {
    if ! sudo -v; then
        log_error "sudo access is required. Exiting."
        exit 1
    fi
    while true; do
        sudo -n true 2>/dev/null || exit
        sleep 60
        kill -0 "$$" 2>/dev/null || exit
    done &
    SUDO_KEEPALIVE_PID=$!
}

initial_system_update() {
    log_section "Performing initial system update"
    
    log "Cleaning DNF cache..."
    sudo dnf clean all >> "$LOG_FILE" 2>&1 || true
    
    log "Refreshing package metadata..."
    sudo dnf makecache >> "$LOG_FILE" 2>&1 || true
    
    echo ""
    log "Updating system packages (this may take a while)..."
    echo ""
    
    # Perform system update
    if sudo dnf -y upgrade --refresh; then
        echo "Initial system update completed successfully" >> "$LOG_FILE"
        echo ""
        log_success "System updated successfully"
    else
        echo "Initial system update completed with some errors" >> "$LOG_FILE"
        echo ""
        log_warning "Some packages failed to update (continuing anyway)"
    fi
    
    # Check if reboot is required
    echo ""
    log "Checking if reboot is required..."
    
    local needs_reboot=false

    # dnf5 needs-restarting (dnf5-plugins) checks kernel, glibc, systemd and other core packages.
    # Run it as root: root's metadata cache is fresh after the upgrade above. Exit code 1 is
    # returned both for "reboot required" and for errors, so the output is checked too.
    local nr_output=""
    local nr_status=0
    nr_output="$(sudo dnf needs-restarting -r 2>&1)" || nr_status=$?
    echo "$nr_output" >> "$LOG_FILE"

    if [[ $nr_status -eq 0 ]]; then
        log_success "No reboot required by dnf needs-restarting"
    elif [[ "$nr_output" == *"Reboot is required"* ]]; then
        log_warning "Reboot required according to dnf needs-restarting"
        needs_reboot=true
    else
        log_warning "dnf needs-restarting failed, falling back to kernel version check"
        # Fallback: compare the running kernel with the newest installed one
        local latest_kernel
        latest_kernel="$(rpm -q --last kernel-core 2>/dev/null | awk 'NR == 1 {sub(/^kernel-core-/, "", $1); print $1}' || true)"
        if [[ -n "$latest_kernel" ]] && [[ "$(uname -r)" != "$latest_kernel" ]]; then
            log_warning "Kernel has been updated"
            needs_reboot=true
        fi
    fi

    if [[ "$needs_reboot" == "true" ]]; then
        echo ""
        echo ""
        log_critical "╔════════════════════════════════════════════════════════════════╗"
        log_critical "║                                                                ║"
        log_critical "║               ⚠️  REBOOT REQUIRED  ⚠️                           ║"
        log_critical "║                                                                ║"
        log_critical "║  Critical system packages have been updated.                  ║"
        log_critical "║  Please reboot your system and run this script again.         ║"
        log_critical "║                                                                ║"
        log_critical "║  Run: sudo reboot                                             ║"
        log_critical "║                                                                ║"
        log_critical "╚════════════════════════════════════════════════════════════════╝"
        echo ""
        exit 0
    else
        log_success "No reboot required, continuing with setup..."
    fi
}

detect_desktop_environment() {
    log_section "Detecting desktop environment"
    
    # Check various environment variables and running processes
    if [[ "${XDG_CURRENT_DESKTOP:-}" == *"KDE"* ]] || [[ "${DESKTOP_SESSION:-}" == *"plasma"* ]]; then
        DESKTOP_ENV="KDE"
    elif [[ "${XDG_CURRENT_DESKTOP:-}" == *"GNOME"* ]] || [[ "${DESKTOP_SESSION:-}" == *"gnome"* ]]; then
        DESKTOP_ENV="GNOME"
    elif pgrep -x "plasmashell" >/dev/null 2>&1; then
        DESKTOP_ENV="KDE"
    elif pgrep -x "gnome-shell" >/dev/null 2>&1; then
        DESKTOP_ENV="GNOME"
    else
        DESKTOP_ENV="UNKNOWN"
    fi
    
    log_success "Desktop environment detected: $DESKTOP_ENV"
}

# ============================================================================
# Installation Functions
# ============================================================================

install_basic_packages() {
    log_section "Installing basic packages"
    
    if sudo dnf -y install --skip-unavailable git unzip jq dnf5-plugins 7zip 7zip-standalone 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Basic packages installed"
    else
        log_error "Failed to install some basic packages (continuing anyway)"
    fi
}

install_nerd_font() {
    log_section "Installing FiraCode Nerd Font"
    
    if fc-list ":family=$FONT_NAME" | grep -q .; then
        log_success "FiraCode Nerd Font already installed"
        return 0
    fi
    
    mkdir -p "$FONT_DIR"
    local temp_zip="$FONT_DIR/FiraCode.zip"
    
    log "Downloading FiraCode Nerd Font..."
    if curl -fsSL -o "$temp_zip" "$FONT_ZIP_URL"; then
        if unzip -oq "$temp_zip" -d "$FONT_DIR"; then
            fc-cache -f >/dev/null || true
            log_success "FiraCode Nerd Font installed successfully"
        else
            log_error "Failed to extract FiraCode Nerd Font"
        fi
    else
        log_error "Failed to download FiraCode Nerd Font"
    fi
    rm -f "$temp_zip"
}

install_system_fonts() {
    log_section "Installing system fonts"
    
    # Base recommended fonts
    log "Installing base recommended fonts..."
    if sudo dnf -y install --skip-unavailable \
        google-noto-sans-fonts \
        google-noto-sans-mono-fonts \
        google-noto-emoji-fonts \
        dejavu-sans-fonts \
        dejavu-sans-mono-fonts \
        liberation-fonts \
        rsms-inter-fonts \
        terminus-fonts 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Base fonts installed"
    else
        log_error "Some base fonts failed to install (continuing anyway)"
    fi

    log "Updating font cache..."
    sudo fc-cache -f >/dev/null 2>&1 || true
    log_success "Font cache updated"
}

setup_fish() {
    log_section "Setting up Fish shell with Starship"

    local fish_conf_dir="$HOME/.config/fish"
    local fish_conf="$fish_conf_dir/config.fish"

    mkdir -p "$fish_conf_dir"

    # Create or update config.fish
    if [[ ! -f "$fish_conf" ]]; then
        log "Creating Fish configuration..."
        cat > "$fish_conf" <<'FISHEOF'
# Disable greeting
set -g fish_greeting

# Transient prompt — show minimal prompt for previous commands
function starship_transient_prompt_func
    starship module character
end

# Starship prompt with transient prompt enabled
if command -q starship
    starship init fish | source
    enable_transience
end

# Modern CLI replacements
if command -q eza
    alias ls='eza --icons --group-directories-first'
    alias ll='eza -l --icons --group-directories-first --git'
    alias la='eza -la --icons --group-directories-first --git'
    alias lt='eza -T --icons --group-directories-first --level=2'
else
    alias ll='ls -lah'
    alias la='ls -A'
end

if command -q bat
    alias cat='bat --style=auto'
    set -gx MANPAGER "sh -c 'col -bx | bat -l man -p'"
end

# Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# Git abbreviations
abbr -a ga 'git add'
abbr -a gc 'git commit'
abbr -a gp 'git push'
abbr -a gl 'git pull'
abbr -a gs 'git status'
abbr -a gd 'git diff'
abbr -a gco 'git checkout'
abbr -a gb 'git branch'
abbr -a glog 'git log --oneline --graph --decorate'

# Colored man pages
set -gx LESS_TERMCAP_mb \e'[1;31m'
set -gx LESS_TERMCAP_md \e'[1;34m'
set -gx LESS_TERMCAP_me \e'[0m'
set -gx LESS_TERMCAP_se \e'[0m'
set -gx LESS_TERMCAP_so \e'[1;33m'
set -gx LESS_TERMCAP_ue \e'[0m'
set -gx LESS_TERMCAP_us \e'[1;32m'
FISHEOF
        log_success "Fish configuration created"
    else
        # Ensure starship init is present
        if ! grep -q 'starship init fish' "$fish_conf"; then
            cat >> "$fish_conf" <<'FISHEOF'

# Starship prompt with transient prompt enabled
if command -q starship
    starship init fish | source
    enable_transience
end
FISHEOF
            log_success "Starship init added to Fish config"
        else
            log_success "Starship already configured in Fish"
        fi

        # Ensure transient prompt is enabled (configs created by older versions lack it)
        if ! grep -q 'enable_transience' "$fish_conf"; then
            cat >> "$fish_conf" <<'FISHEOF'

# Starship transient prompt
functions -q enable_transience; and enable_transience
FISHEOF
            log_success "Starship transient prompt enabled in Fish config"
        fi
    fi

    # Ensure update alias is present
    if ! grep -q "alias update=" "$fish_conf"; then
        cat >> "$fish_conf" <<'FISHEOF'

# System update
alias update='sudo dnf upgrade --refresh -y; sudo dnf autoremove -y; sudo dnf clean packages; sudo update-pciids; or true; flatpak update -y; sudo fwupdmgr refresh --force; sudo fwupdmgr update -y'
FISHEOF
        log_success "Update alias added to Fish config"
    fi

    # Install Starship
    if command -v starship >/dev/null 2>&1; then
        log_success "Starship already installed"
    else
        log "Installing Starship..."
        if curl -fsSL https://starship.rs/install.sh | sh -s -- -y; then
            log_success "Starship installed"
        else
            log_error "Failed to install Starship"
        fi
    fi

    # Configure Starship
    local starship_conf="$HOME/.config/starship.toml"
    if [[ ! -f "$starship_conf" ]]; then
        log "Creating Starship configuration..."
        cat > "$starship_conf" <<'STAREOF'
# Starship prompt — Catppuccin Mocha powerline style

palette = "catppuccin_mocha"

format = """
[](mauve)\
$os\
$username\
[](bg:blue fg:mauve)\
$directory\
[](bg:green fg:blue)\
$git_branch\
$git_status\
[](bg:teal fg:green)\
$python\
$rust\
$golang\
$nodejs\
$java\
$docker_context\
[](bg:surface0 fg:teal)\
$cmd_duration\
$status\
[](fg:surface0)\
$fill\
[](fg:surface0)\
$time\
[](fg:mauve bg:surface0)\
$battery\
[](fg:mauve)\
$line_break\
$character"""

[os]
disabled = false
style = "bg:mauve fg:crust"
[os.symbols]
Fedora = " "
Linux = " "
Macos = " "
Windows = " "

[username]
show_always = false
style_user = "bg:mauve fg:crust"
style_root = "bg:red fg:crust bold"
format = '[ $user]($style)'

[directory]
style = "bg:blue fg:crust"
format = "[ $path ]($style)"
truncation_length = 3
truncation_symbol = "…/"
[directory.substitutions]
"Documents" = "󰈙 "
"Downloads" = " "
"Music" = "󰎆 "
"Pictures" = " "
"Development" = "󰲋 "

[git_branch]
symbol = ""
style = "bg:green fg:crust"
format = '[ $symbol $branch ]($style)'

[git_status]
style = "bg:green fg:crust"
format = '[$all_status$ahead_behind ]($style)'
conflicted = " "
ahead = "⇡${count} "
behind = "⇣${count} "
diverged = "⇕⇡${ahead_count}⇣${behind_count} "
up_to_date = ""
untracked = " "
stashed = "󰏗 "
modified = " "
staged = " "
renamed = "󰁕 "
deleted = " "

[python]
symbol = ""
style = "bg:teal fg:crust"
format = '[ $symbol $version(\($virtualenv\)) ]($style)'

[rust]
symbol = ""
style = "bg:teal fg:crust"
format = '[ $symbol $version ]($style)'

[golang]
symbol = ""
style = "bg:teal fg:crust"
format = '[ $symbol $version ]($style)'

[nodejs]
symbol = ""
style = "bg:teal fg:crust"
format = '[ $symbol $version ]($style)'

[java]
symbol = ""
style = "bg:teal fg:crust"
format = '[ $symbol $version ]($style)'

[docker_context]
symbol = ""
style = "bg:teal fg:crust"
format = '[ $symbol $context ]($style)'

[cmd_duration]
min_time = 2_000
style = "bg:surface0 fg:text"
format = '[ 󱎫 $duration ]($style)'

[status]
disabled = false
style = "bg:surface0 fg:red"
format = '[ $symbol$status ]($style)'
symbol = " "

[fill]
symbol = " "

[time]
disabled = false
time_format = "%H:%M"
style = "bg:surface0 fg:subtext0"
format = '[ 󰥔 $time ]($style)'

[battery]
disabled = true

[character]
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"
vimcmd_symbol = "[❮](bold mauve)"

[palettes.catppuccin_mocha]
rosewater = "#f5e0dc"
flamingo  = "#f2cdcd"
pink      = "#f5c2e7"
mauve     = "#cba6f7"
red       = "#f38ba8"
maroon    = "#eba0ac"
peach     = "#fab387"
yellow    = "#f9e2af"
green     = "#a6e3a1"
teal      = "#94e2d5"
sky       = "#89dceb"
sapphire  = "#74c7ec"
blue      = "#89b4fa"
lavender  = "#b4befe"
text      = "#cdd6f4"
subtext1  = "#bac2de"
subtext0  = "#a6adc8"
overlay2  = "#9399b2"
overlay1  = "#7f849c"
overlay0  = "#6c7086"
surface2  = "#585b70"
surface1  = "#45475a"
surface0  = "#313244"
base      = "#1e1e2e"
mantle    = "#181825"
crust     = "#11111b"
STAREOF
        log_success "Starship configuration created"
    else
        log_success "Starship configuration already exists"
    fi

    # Set fish as default shell
    if command_exists fish; then
        local fish_path
        local current_shell

        fish_path="$(command -v fish)"
        current_shell="$(getent passwd "$USER" | cut -d: -f7 || echo "")"

        # Ensure fish is in /etc/shells
        if ! grep -qx "$fish_path" /etc/shells; then
            echo "$fish_path" | sudo tee -a /etc/shells >> "$LOG_FILE" 2>&1
            log_success "Fish added to /etc/shells"
        fi

        if [[ "$current_shell" != "$fish_path" ]]; then
            log "Changing default shell to Fish..."
            if chsh -s "$fish_path" 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Default shell changed to Fish (re-login to apply)"
            else
                log_error "Failed to change default shell"
            fi
        else
            log_success "Fish already set as default shell"
        fi
    else
        log_error "Fish not installed, skipping shell change"
    fi
}

optimize_system() {
    log_section "Applying system optimizations"
    
    # Disable CUPS browsing (security)
    if sudo systemctl mask cups-browsed >/dev/null 2>&1; then
        log_success "CUPS browsing disabled"
    fi
    
    # Configure DNF for better performance
    if command_exists dnf5; then
        if sudo dnf5 config-manager setopt max_parallel_downloads="$DNF_MAX_PARALLEL" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "DNF5 configured (max_parallel_downloads=$DNF_MAX_PARALLEL)"
        else
            log_error "Failed to configure DNF5"
        fi
    fi
    
    # Enable SSD TRIM
    if sudo systemctl enable --now fstrim.timer >/dev/null 2>&1; then
        log_success "TRIM timer enabled"
    fi
    
    # Enable firmware updates
    if sudo systemctl enable --now fwupd-refresh.timer >/dev/null 2>&1; then
        log_success "Firmware update timer enabled"
    fi
    
    # Disable NetworkManager wait online (faster boot), unless network filesystems
    # in fstab rely on it being online at boot
    if grep -Eq '^[^#]*[[:space:]](nfs4?|cifs|smb3|sshfs|fuse\.sshfs)[[:space:]]|^[^#]*_netdev' /etc/fstab 2>/dev/null; then
        log_warning "Network filesystems found in /etc/fstab, keeping NetworkManager-wait-online enabled"
    elif sudo systemctl disable NetworkManager-wait-online.service >/dev/null 2>&1; then
        log_success "NetworkManager wait-online disabled"
    fi
}

# Hide a system autostart entry for the current user via ~/.config/autostart override
disable_autostart_entry() {
    local desktop_file="$1"
    local label="$2"
    local system_file="/etc/xdg/autostart/$desktop_file"
    local autostart_file="$HOME/.config/autostart/$desktop_file"

    [[ -f "$system_file" ]] || return 0

    if [[ ! -f "$autostart_file" ]]; then
        cp "$system_file" "$autostart_file" 2>&1 | tee -a "$LOG_FILE" || true
    fi

    if grep -q '^Hidden=' "$autostart_file" 2>/dev/null; then
        sed -i 's/^Hidden=.*/Hidden=true/' "$autostart_file" 2>&1 | tee -a "$LOG_FILE" || true
    else
        printf '\nHidden=true\n' >> "$autostart_file"
    fi

    log_success "$label autostart disabled"
}

disable_software_autostart() {
    log_section "Disabling software store autostart"

    mkdir -p "$HOME/.config/autostart"

    case "$DESKTOP_ENV" in
        GNOME)
            disable_autostart_entry org.gnome.Software.desktop "GNOME Software"
            ;;
        KDE)
            disable_autostart_entry org.kde.discover.notifier.desktop "KDE Discover"
            ;;
        *)
            log "Unknown desktop environment, skipping software store autostart configuration"
            ;;
    esac
}

setup_repositories() {
    log_section "Setting up additional repositories"
    
    local fedora_version
    fedora_version=$(rpm -E %fedora)
    
    # RPM Fusion (free and nonfree)
    log "Adding RPM Fusion repositories..."
    sudo dnf -y install \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_version}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_version}.noarch.rpm" \
        2>&1 | tee -a "$LOG_FILE" || true
    
    # RPM Fusion Tainted (free and nonfree)
    log "Adding RPM Fusion Tainted repositories..."
    sudo dnf -y install \
        rpmfusion-free-release-tainted \
        rpmfusion-nonfree-release-tainted \
        2>&1 | tee -a "$LOG_FILE" || true
    
    log_success "RPM Fusion repositories (including tainted) configured"
    
    # Fedora Workstation repositories
    sudo dnf -y install fedora-workstation-repositories 2>&1 | tee -a "$LOG_FILE" || true

    # Fedora Repos Archive
    sudo dnf -y install fedora-repos-archive 2>&1 | tee -a "$LOG_FILE" || true
    
    # Configure third-party repos
    sudo dnf config-manager setopt google-chrome.enabled=1 2>&1 | tee -a "$LOG_FILE" || true
    sudo dnf config-manager setopt rpmfusion-nonfree-nvidia-driver.enabled=0 2>&1 | tee -a "$LOG_FILE" || true
    sudo dnf config-manager setopt rpmfusion-nonfree-steam.enabled=1 2>&1 | tee -a "$LOG_FILE" || true
    
    # 1Password repository
    log "Adding 1Password repository..."
    sudo rpm --import https://downloads.1password.com/linux/keys/1password.asc 2>&1 | tee -a "$LOG_FILE" || true
    
    local temp_repo
    temp_repo="$(mktemp)"
    cat > "$temp_repo" <<'EOF'
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://downloads.1password.com/linux/keys/1password.asc
EOF
    
    if [[ ! -f /etc/yum.repos.d/1password.repo ]] || ! sudo cmp -s "$temp_repo" /etc/yum.repos.d/1password.repo; then
        sudo install -m0644 "$temp_repo" /etc/yum.repos.d/1password.repo
        log_success "1Password repository added"
    else
        log_success "1Password repository already configured"
    fi
    rm -f "$temp_repo"
    
    # Master PDF Editor repository
    log "Adding Master PDF Editor repository..."
    temp_repo="$(mktemp)"
    if curl -fsSL -o "$temp_repo" http://repo.code-industry.net/rpm/master-pdf-editor.repo 2>&1 | tee -a "$LOG_FILE"; then
        if [[ ! -f /etc/yum.repos.d/master-pdf-editor.repo ]] || ! sudo cmp -s "$temp_repo" /etc/yum.repos.d/master-pdf-editor.repo; then
            sudo install -m0644 "$temp_repo" /etc/yum.repos.d/master-pdf-editor.repo 2>&1 | tee -a "$LOG_FILE" || true
            log_success "Master PDF Editor repository added"
        else
            log_success "Master PDF Editor repository already configured"
        fi
    else
        log_error "Failed to download Master PDF Editor repository"
    fi
    rm -f "$temp_repo"
}

install_packages() {
    log_section "Installing system packages"
    
    local packages=(
        # System monitoring and info
        btop cpu-x hwinfo lshw dmidecode pciutils lm_sensors
        
        # Development tools
        python3-pip python3-build
        
        # Graphics and multimedia
        glx-utils vulkan-tools libva libva-utils mesa-libGLU
        
        # Networking
        wireguard-tools wget
        
        # Shell
        fish

        # Modern CLI tools
        eza bat

        # System utilities
        fastfetch solaar solaar-udev tldr

        # FUSE support
        fuse fuse-libs fuse3 fuse3-libs
        
        # Applications
        google-chrome-stable 1password master-pdf-editor flatseal
    )
    
    # Add KDE-specific packages
    if [[ "$DESKTOP_ENV" == "KDE" ]]; then
        packages+=(virt-manager)
        log "KDE detected, adding virt-manager to installation list"
    fi
    
    echo ""
    log "Installing main packages..."
    log "Packages: ${packages[*]}"
    echo ""
    
    # --skip-unavailable: one missing package (e.g. an unreachable third-party repo)
    # must not abort the whole transaction
    if sudo dnf -y install --skip-unavailable "${packages[@]}"; then
        echo "package installation completed successfully" >> "$LOG_FILE"
        echo ""
        log_success "Main packages installed successfully"
    else
        echo "package installation completed with some errors" >> "$LOG_FILE"
        echo ""
        log_error "Some packages failed to install (continuing anyway)"
    fi
    
    # Install multimedia packages
    echo ""
    log "Installing multimedia support..."
    echo ""
    sudo dnf -y group install --skip-unavailable multimedia --setopt=strict=0 || log_error "Multimedia group install had issues"
    sudo dnf -y group install --skip-unavailable sound-and-video || log_error "Sound-and-video group install had issues"
    
    # Replace free versions with full-featured ones
    echo ""
    log "Replacing packages with full-featured versions..."
    echo ""
    
    sudo dnf -y swap ffmpeg-free ffmpeg --allowerasing || log_error "FFmpeg swap had issues"
    sudo dnf -y swap mesa-va-drivers mesa-va-drivers-freeworld --allowerasing || log_error "Mesa VA drivers swap had issues"
    sudo dnf -y swap mesa-vulkan-drivers mesa-vulkan-drivers-freeworld --allowerasing || log_error "Mesa Vulkan drivers swap had issues"

    echo ""
    log_success "Multimedia packages installed"
}

install_flatpaks() {
    log_section "Installing Flatpak applications"
    
    log "Adding Flathub repository..."
    if flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo >> "$LOG_FILE" 2>&1; then
        log_success "Flathub repository configured"
    else
        log "Flathub repository already exists or failed to add (continuing anyway)"
    fi
    
    # Common apps for all desktop environments
    local flatpak_apps=(
        com.spotify.Client
        com.termius.Termius
        us.zoom.Zoom
        it.mijorus.gearlever
        io.github.kolunmi.Bazaar
        me.proton.Mail
    )
    
    # Add GNOME-specific apps
    if [[ "$DESKTOP_ENV" == "GNOME" ]]; then
        flatpak_apps+=(com.mattjakeman.ExtensionManager)
        log "GNOME detected, adding Extension Manager to installation list"
    fi
    
    echo ""
    log "Installing Flatpak applications (this may take a while)..."
    log "Apps to install: ${flatpak_apps[*]}"
    echo ""
    
    # Install flatpaks with visible progress, log summary to file
    if flatpak -y install flathub "${flatpak_apps[@]}"; then
        echo "flatpak install completed successfully" >> "$LOG_FILE"
        echo ""
        log_success "Flatpak applications installed"
    else
        echo "flatpak install completed with some errors" >> "$LOG_FILE"
        echo ""
        log_error "Some Flatpak applications failed to install (continuing anyway)"
    fi
}

setup_ledger_udev() {
    log_section "Setting up Ledger udev rules"
    
    local temp_script
    temp_script="$(mktemp)"
    TEMP_FILES+=("$temp_script")

    log "Downloading Ledger udev rules script..."
    if curl -fsSL -o "$temp_script" https://raw.githubusercontent.com/LedgerHQ/udev-rules/master/add_udev_rules.sh 2>> "$LOG_FILE"; then
        log "Executing Ledger udev rules script..."
        if sudo bash "$temp_script" >> "$LOG_FILE" 2>&1; then
            log_success "Ledger udev rules installed"
        else
            log_error "Failed to install Ledger udev rules"
        fi
        rm -f "$temp_script"
    else
        log_error "Failed to download Ledger udev rules script"
    fi
}

install_zed_editor() {
    log_section "Installing Zed editor"
    
    if command_exists zed; then
        log_success "Zed editor already installed"
        return 0
    fi
    
    log "Installing Zed editor..."
    if curl -f https://zed.dev/install.sh | sh 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Zed editor installed"
    else
        log_error "Failed to install Zed editor"
    fi
}

# Print the first asset URL of the latest GitHub release matching a jq regex (empty on any failure)
github_asset_url() {
    local repo="$1"
    local regex="$2"
    curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>> "$LOG_FILE" | \
        jq -r --arg re "$regex" '[.assets[]?.browser_download_url | select(test($re))][0] // empty' 2>> "$LOG_FILE" || true
}

# Download a file into the current directory unless it is already there, then remove
# older versions matching old_glob. The download goes to a .part file first, so an
# interrupted download never ends up under the final name.
fetch_package() {
    local name="$1"
    local url="$2"
    local file="$3"
    local old_glob="$4"

    if [[ -z "$url" ]] || [[ -z "$file" ]]; then
        log_error "$name download URL not found"
        return 0
    fi

    if [[ -f "$file" ]]; then
        log "$name already downloaded"
        return 0
    fi

    log "Downloading $name..."
    if wget -q --show-progress -O "$file.part" "$url"; then
        mv -f "$file.part" "$file"
        find . -maxdepth 1 -name "$old_glob" ! -name "$file" -delete
        echo "$name downloaded: $file" >> "$LOG_FILE"
    else
        rm -f "$file.part"
        log_error "Failed to download $name"
    fi
}

download_third_party_apps() {
    log_section "Downloading third-party applications"

    mkdir -p "$PACKAGES_DIR"
    pushd "$PACKAGES_DIR" >/dev/null

    local url

    # Ledger Live (the "latest" URL redirects to the versioned AppImage)
    log "Checking for Ledger Live updates..."
    url=$(curl -fsSL -w '%{url_effective}' -o /dev/null "https://download.live.ledger.com/latest/linux" 2>> "$LOG_FILE" || true)
    if [[ "$url" != *.AppImage ]]; then
        url=""
    fi
    fetch_package "Ledger Live" "$url" "${url##*/}" "ledger-live-desktop-*.AppImage"

    # Tabby Terminal
    log "Checking for Tabby Terminal updates..."
    url=$(github_asset_url "Eugeny/tabby" 'linux-x64\.rpm$')
    fetch_package "Tabby Terminal" "$url" "${url##*/}" "tabby-*.rpm"

    # Bruno API Client
    log "Checking for Bruno updates..."
    url=$(github_asset_url "usebruno/bruno" '_x86_64_linux\.rpm$')
    fetch_package "Bruno" "$url" "${url##*/}" "bruno_*.rpm"

    # Telegram Desktop
    log "Checking for Telegram Desktop updates..."
    url=$(github_asset_url "telegramdesktop/tdesktop" 'td-setup-linux-x64-[0-9.]+\.tar\.xz$')
    fetch_package "Telegram Desktop" "$url" "${url##*/}" "td-setup-linux-x64-*.tar.xz"

    # MikroTik WinBox (URL is scraped from the download page; the file is renamed
    # to include the version, since the upstream name is always WinBox_Linux.zip)
    log "Checking for WinBox updates..."
    url=$(curl -fsSL "https://mikrotik.com/download/winbox" 2>> "$LOG_FILE" | \
        grep -Eo 'https://[a-z]+\.mikrotik\.com/routeros/winbox/[^"]+/WinBox_Linux\.zip' | head -n 1 || true)
    if [[ -n "$url" ]]; then
        local winbox_version
        winbox_version=$(awk -F'/' '{print $(NF-1)}' <<< "$url")
        fetch_package "WinBox" "$url" "winbox_${winbox_version}.zip" "winbox_*.zip"
    else
        log_error "WinBox URL not found — MikroTik page format may have changed"
    fi

    # balenaEtcher
    log "Checking for balenaEtcher updates..."
    url=$(github_asset_url "balena-io/etcher" 'balenaEtcher-linux-x64-[0-9.]+\.zip$')
    fetch_package "balenaEtcher" "$url" "${url##*/}" "balenaEtcher-linux-x64-*.zip"

    echo ""
    log_success "Third-party applications downloaded"
    popd >/dev/null
}

install_third_party_apps() {
    log_section "Installing third-party applications"
    
    pushd "$PACKAGES_DIR" >/dev/null
    mkdir -p "$APPS_DIR"
    
    # Install RPM packages
    local rpm_files=(./*.rpm)
    if [[ "${rpm_files[0]}" != "./*.rpm" ]]; then
        echo ""
        log "Installing RPM packages..."
        echo ""
        if sudo dnf -y install "${rpm_files[@]}"; then
            echo "RPM packages installed successfully" >> "$LOG_FILE"
            echo ""
            log_success "RPM packages installed"
        else
            echo "RPM packages installation had some errors" >> "$LOG_FILE"
            echo ""
            log_error "Some RPM packages failed to install"
        fi
    fi
    
    # Install Ledger Live AppImage under a stable name
    local ledger_appimages=(./ledger-live-desktop-*.AppImage)
    if [[ "${ledger_appimages[0]}" != "./ledger-live-desktop-*.AppImage" ]]; then
        log "Installing Ledger Live..."
        if install -m0755 "${ledger_appimages[0]}" "$APPS_DIR/ledger-live-desktop.AppImage" 2>> "$LOG_FILE"; then
            log_success "Ledger Live installed to $APPS_DIR/ledger-live-desktop.AppImage"
        else
            log_error "Failed to install Ledger Live"
        fi
    fi

    # Extract Telegram
    local tg_archives=(./td-setup-linux-x64-*.tar.xz)
    if [[ "${tg_archives[0]}" != "./td-setup-linux-x64-*.tar.xz" ]]; then
        log "Extracting Telegram Desktop..."
        rm -rf "$APPS_DIR/Telegram"
        if tar -xJf "${tg_archives[0]}" -C "$APPS_DIR" 2>> "$LOG_FILE"; then
            log_success "Telegram installed to $APPS_DIR/Telegram"
        else
            log_error "Failed to extract Telegram"
        fi
    fi
    
    # Extract WinBox
    local winbox_zips=(./winbox_*.zip)
    if [[ "${winbox_zips[0]}" != "./winbox_*.zip" ]]; then
        log "Extracting WinBox..."
        rm -rf "$APPS_DIR/WinBox"
        mkdir -p "$APPS_DIR/WinBox"
        if unzip -oq "${winbox_zips[0]}" -d "$APPS_DIR/WinBox" 2>> "$LOG_FILE"; then
            [[ -f "$APPS_DIR/WinBox/WinBox" ]] && chmod +x "$APPS_DIR/WinBox/WinBox"
            log_success "WinBox installed to $APPS_DIR/WinBox"
        else
            log_error "Failed to extract WinBox"
        fi
    fi
    
    # Extract balenaEtcher
    local etcher_zips=(./balenaEtcher-linux-x64-*.zip)
    if [[ "${etcher_zips[0]}" != "./balenaEtcher-linux-x64-*.zip" ]]; then
        log "Extracting balenaEtcher..."
        local temp_dir
        temp_dir=$(mktemp -d)
        TEMP_FILES+=("$temp_dir")

        if unzip -oq "${etcher_zips[0]}" -d "$temp_dir" 2>> "$LOG_FILE"; then
            rm -rf "$APPS_DIR/balenaEtcher"
            mkdir -p "$APPS_DIR/balenaEtcher"
            
            if [[ -d "$temp_dir/balenaEtcher-linux-x64" ]]; then
                cp -a "$temp_dir/balenaEtcher-linux-x64/." "$APPS_DIR/balenaEtcher/"
            else
                cp -a "$temp_dir/." "$APPS_DIR/balenaEtcher/"
            fi
            
            for binary in "$APPS_DIR/balenaEtcher/balena-etcher" "$APPS_DIR/balenaEtcher/balenaEtcher" "$APPS_DIR/balenaEtcher/etcher"; do
                [[ -f "$binary" ]] && chmod +x "$binary"
            done
            
            log_success "balenaEtcher installed to $APPS_DIR/balenaEtcher"
        else
            log_error "Failed to extract balenaEtcher"
        fi
        
        rm -rf "$temp_dir"
    fi

    popd >/dev/null
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    log_section "Fedora Workstation Post-Installation Setup v${SCRIPT_VERSION}"
    log "Script started at $(date)"
    log "Log file: $LOG_FILE"
    
    check_fedora
    check_not_root
    start_sudo_keepalive

    # Perform initial system update and check if reboot is needed
    initial_system_update

    detect_desktop_environment

    # Basic packages and Nerd Font (doesn't require repos)
    install_basic_packages
    install_nerd_font

    # Repository setup (RPM Fusion, Chrome, 1Password, Master PDF Editor)
    setup_repositories

    # System fonts installation (Fedora repos)
    install_system_fonts

    # System optimization
    optimize_system
    disable_software_autostart
    
    # Package installation
    install_packages
    install_flatpaks
    
    # Hardware support
    setup_ledger_udev
    
    # Third-party applications
    install_zed_editor
    download_third_party_apps
    install_third_party_apps

    # Shell setup
    setup_fish

    log_section "Setup Complete!"
    log "Log file saved to: $LOG_FILE"
    log ""
    log "Detected desktop environment: $DESKTOP_ENV"
    log ""
    log "Next steps:"
    log "  1. Log out and log back in (new default shell: Fish)"
    log "  2. Set your terminal font to '$FONT_NAME' so Starship icons render"
    log "  3. Verify setup: starship --version, zed --version"
    log "  4. Use 'update' command anytime to update your system"
    log ""
    log "Shell:"
    log "  - Shell: Fish with Starship prompt"
    log "  - Font: FiraCode Nerd Font Mono"
    log ""
    log "Installed applications:"
    log "  - Editors: Zed"
    log "  - Terminal: Tabby"
    log "  - Development: Bruno API Client"
    log "  - Communication: Telegram, Zoom"
    log "  - Utilities: Ledger Live, WinBox, balenaEtcher"
    log "  - Flatpaks: Bazaar, Proton Mail, Spotify, and more"
    log ""
    log "Installed fonts:"
    log "  - FiraCode Nerd Font"
    log "  - Google Noto (Sans, Mono, Emoji)"
    log "  - DejaVu, Liberation, Inter, Terminus"
    log ""
    log "All done! Enjoy your Fedora setup!"
}

# Run main function
main "$@"
