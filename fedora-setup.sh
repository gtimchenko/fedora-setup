#!/usr/bin/env bash
#
# Fedora Workstation Post-Installation Setup Script
# 
# This script automates the setup of a fresh Fedora Workstation installation with:
# - ZSH with Oh My Zsh and Powerlevel10k theme
# - FiraCode Nerd Font
# - RPM Fusion repositories (free and nonfree)
# - Essential system tools and applications
# - Performance optimizations
# - Third-party applications (Chrome, 1Password, VS Code, etc.)
#
# Usage: ./fedora-setup.sh
#
# Author: Georgiy Timchenko
# License: MIT
# Repository: https://github.com/gtimchenko/fedora-setup

set -Eeuo pipefail

# ============================================================================
# Configuration
# ============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly LOG_FILE="$HOME/fedora-setup-$(date +%Y%m%d-%H%M%S).log"
readonly APPS_DIR="$HOME/Applications"
readonly PACKAGES_DIR="$HOME/packages"
readonly FONT_DIR="$HOME/.local/share/fonts"

# Font configuration
readonly FONT_NAME="FiraCode Nerd Font Mono"
readonly FONT_SETTINGS="FiraCode Nerd Font Mono weight=450 10"
readonly FONT_ZIP_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.zip"

# DNF configuration
readonly DNF_MAX_PARALLEL=10
readonly DNF_DELTARPM=true

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

# ============================================================================
# Installation Functions
# ============================================================================

install_basic_packages() {
    log_section "Installing basic packages"
    
    if sudo dnf -y install zsh unzip dnf5-plugins 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Basic packages installed"
    else
        log_error "Failed to install some basic packages (continuing anyway)"
    fi
}

install_nerd_font() {
    log_section "Installing FiraCode Nerd Font"
    
    if fc-list ":family=$FONT_NAME" | grep -q .; then
        log_success "Font already installed"
        return 0
    fi
    
    mkdir -p "$FONT_DIR"
    local temp_zip="$FONT_DIR/FiraCode.zip"
    
    log "Downloading FiraCode Nerd Font..."
    if curl -fsSL -o "$temp_zip" "$FONT_ZIP_URL"; then
        cd "$FONT_DIR"
        unzip -oq "$temp_zip" && rm -f "$temp_zip"
        fc-cache -f >/dev/null
        cd - >/dev/null
        log_success "Font installed successfully"
    else
        log_error "Failed to download font"
        return 1
    fi
}

configure_terminal_font() {
    log_section "Configuring terminal font"
    
    if ! command_exists gsettings; then
        log "gsettings not available, skipping terminal configuration"
        return 0
    fi
    
    local current_font
    local use_system_font
    
    current_font=$(gsettings get org.gnome.Ptyxis font-name 2>/dev/null || echo "")
    use_system_font=$(gsettings get org.gnome.Ptyxis use-system-font 2>/dev/null || echo "true")
    
    if [[ "$current_font" != "'$FONT_SETTINGS'" ]] || [[ "$use_system_font" != "false" ]]; then
        gsettings set org.gnome.Ptyxis use-system-font false 2>&1 | tee -a "$LOG_FILE" || true
        gsettings set org.gnome.Ptyxis font-name "$FONT_SETTINGS" 2>&1 | tee -a "$LOG_FILE" || true
        log_success "Terminal font configured (restart terminal to apply)"
        exit 0
    else
        log_success "Terminal font already configured"
    fi
}

setup_zsh() {
    log_section "Setting up ZSH with Oh My Zsh and Powerlevel10k"
    
    # Install Oh My Zsh
    if [[ ! -d "${ZSH:-$HOME/.oh-my-zsh}" ]]; then
        log "Installing Oh My Zsh..."
        CHSH=no RUNZSH=no KEEP_ZSHRC=yes \
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" 2>&1 | tee -a "$LOG_FILE" || true
        log_success "Oh My Zsh installed"
    else
        log_success "Oh My Zsh already installed"
    fi
    
    # Install Powerlevel10k theme
    local theme_dir="${ZSH_CUSTOM:-${ZSH:-$HOME/.oh-my-zsh}/custom}/themes/powerlevel10k"
    
    if [[ ! -d "$theme_dir" ]]; then
        log "Installing Powerlevel10k theme..."
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$theme_dir" 2>&1 | tee -a "$LOG_FILE" || true
        log_success "Powerlevel10k installed"
    else
        log "Updating Powerlevel10k theme..."
        git -C "$theme_dir" pull --ff-only 2>&1 | tee -a "$LOG_FILE" || true
        log_success "Powerlevel10k updated"
    fi
    
    # Configure .zshrc
    if [[ -f "$HOME/.zshrc" ]]; then
        if grep -q '^ZSH_THEME=' "$HOME/.zshrc"; then
            if ! grep -q '^ZSH_THEME="powerlevel10k/powerlevel10k"' "$HOME/.zshrc"; then
                sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' "$HOME/.zshrc"
                log_success "ZSH theme updated in .zshrc"
            fi
        else
            printf '\nZSH_THEME="powerlevel10k/powerlevel10k"\n' >> "$HOME/.zshrc"
            log_success "ZSH theme added to .zshrc"
        fi
        
        if ! grep -q '\[\[.*~/.p10k\.zsh.*\]\].*source' "$HOME/.zshrc"; then
            printf '\n[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh\n' >> "$HOME/.zshrc"
        fi
        
        if [[ -f "$HOME/.p10k.zsh" ]] && ! grep -q '^POWERLEVEL10K_DISABLE_CONFIGURATION_WIZARD=' "$HOME/.zshrc"; then
            printf '\nPOWERLEVEL10K_DISABLE_CONFIGURATION_WIZARD=true\n' >> "$HOME/.zshrc"
        fi
    fi
}

change_default_shell() {
    log_section "Setting ZSH as default shell"
    
    if ! command_exists zsh; then
        log_error "ZSH not installed, skipping shell change"
        return 1
    fi
    
    local zsh_path
    local current_shell
    
    zsh_path="$(command -v zsh)"
    current_shell="$(getent passwd "$USER" | cut -d: -f7 || echo "")"
    
    if [[ "$current_shell" != "$zsh_path" ]]; then
        log "Changing default shell to ZSH..."
        if chsh -s "$zsh_path" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Default shell changed to ZSH (re-login to apply)"
        else
            log_error "Failed to change default shell"
            return 1
        fi
    else
        log_success "ZSH already set as default shell"
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
        sudo dnf5 config-manager setopt max_parallel_downloads="$DNF_MAX_PARALLEL" 2>&1 | tee -a "$LOG_FILE" || true
        sudo dnf5 config-manager setopt deltarpm="$DNF_DELTARPM" 2>&1 | tee -a "$LOG_FILE" || true
        log_success "DNF5 configured"
    fi
    
    # Enable SSD TRIM
    if sudo systemctl enable --now fstrim.timer >/dev/null 2>&1; then
        log_success "TRIM timer enabled"
    fi
    
    # Enable firmware updates
    if sudo systemctl enable --now fwupd-refresh.timer >/dev/null 2>&1; then
        log_success "Firmware update timer enabled"
    fi
    
    # Disable NetworkManager wait online (faster boot)
    if sudo systemctl disable NetworkManager-wait-online.service >/dev/null 2>&1; then
        log_success "NetworkManager wait-online disabled"
    fi
}

disable_gnome_software_autostart() {
    log_section "Disabling GNOME Software autostart"
    
    mkdir -p "$HOME/.config/autostart"
    
    if [[ -f /etc/xdg/autostart/org.gnome.Software.desktop ]]; then
        local autostart_file="$HOME/.config/autostart/org.gnome.Software.desktop"
        
        if [[ ! -f "$autostart_file" ]]; then
            cp /etc/xdg/autostart/org.gnome.Software.desktop "$autostart_file" 2>&1 | tee -a "$LOG_FILE" || true
        fi
        
        if grep -q '^Hidden=' "$autostart_file" 2>/dev/null; then
            sed -i 's/^Hidden=.*/Hidden=true/' "$autostart_file" 2>&1 | tee -a "$LOG_FILE" || true
        else
            printf '\nHidden=true\n' >> "$autostart_file"
        fi
        
        log_success "GNOME Software autostart disabled"
    fi
}

setup_repositories() {
    log_section "Setting up additional repositories"
    
    local fedora_version
    fedora_version=$(rpm -E %fedora)
    
    # RPM Fusion
    log "Adding RPM Fusion repositories..."
    sudo dnf -y install \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_version}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_version}.noarch.rpm" \
        2>&1 | tee -a "$LOG_FILE" || true
    
    sudo dnf -y install fedora-workstation-repositories 2>&1 | tee -a "$LOG_FILE" || true
    
    # Configure third-party repos
    sudo dnf config-manager setopt google-chrome.enabled=1 2>&1 | tee -a "$LOG_FILE" || true
    sudo dnf config-manager setopt rpmfusion-nonfree-nvidia-driver.enabled=0 2>&1 | tee -a "$LOG_FILE" || true
    sudo dnf config-manager setopt rpmfusion-nonfree-steam.enabled=1 2>&1 | tee -a "$LOG_FILE" || true
    
    sudo dnf -y install rpmfusion-free-release-tainted rpmfusion-nonfree-release-tainted 2>&1 | tee -a "$LOG_FILE" || true
    
    log_success "RPM Fusion repositories configured"
    
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

upgrade_system() {
    log_section "Upgrading system packages"
    
    log "Cleaning DNF cache..."
    sudo dnf clean all >> "$LOG_FILE" 2>&1 || true
    
    log "Refreshing package metadata..."
    sudo dnf makecache >> "$LOG_FILE" 2>&1 || true
    
    log "Updating PCI IDs database..."
    sudo update-pciids >> "$LOG_FILE" 2>&1 || true
    
    echo ""
    log "Upgrading all packages (this may take a while)..."
    echo ""
    
    # Run upgrade with visible progress, log summary to file
    if sudo dnf -y upgrade --refresh; then
        echo "dnf upgrade completed successfully" >> "$LOG_FILE"
        echo ""
        log_success "System upgraded successfully"
    else
        echo "dnf upgrade completed with some errors" >> "$LOG_FILE"
        echo ""
        log_error "Some packages failed to upgrade (continuing anyway)"
    fi
}

install_packages() {
    log_section "Installing system packages"
    
    local packages=(
        # System monitoring and info
        btop cpu-x hwinfo lshw dmidecode pciutils
        
        # Development tools
        python3-pip python3-build
        
        # Graphics and multimedia
        glx-utils vulkan-tools libva libva-utils mesa-libGLU
        
        # Networking
        wireguard-tools wget
        
        # System utilities
        fastfetch solaar solaar-udev
        
        # FUSE support
        fuse fuse-libs fuse3 fuse3-libs
        
        # Applications
        google-chrome-stable 1password master-pdf-editor flatseal
    )
    
    echo ""
    log "Installing main packages..."
    log "Packages: ${packages[*]}"
    echo ""
    
    if sudo dnf -y install "${packages[@]}"; then
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
    sudo dnf -y group install multimedia --setopt=strict=0 || log_error "Multimedia group install had issues"
    sudo dnf -y group install sound-and-video || log_error "Sound-and-video group install had issues"
    
    # Replace free versions with full-featured ones
    echo ""
    log "Replacing packages with full-featured versions..."
    echo ""
    
    sudo dnf -y swap ffmpeg-free ffmpeg --allowerasing || log_error "FFmpeg swap had issues"
    sudo dnf -y swap mesa-va-drivers mesa-va-drivers-freeworld --allowerasing || log_error "Mesa VA drivers swap had issues"
    sudo dnf -y swap mesa-vulkan-drivers mesa-vulkan-drivers-freeworld --allowerasing || log_error "Mesa Vulkan drivers swap had issues"
    sudo dnf -y swap mesa-vdpau-drivers mesa-vdpau-drivers-freeworld --allowerasing || log_error "Mesa VDPAU drivers swap had issues"
    
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
    
    local flatpak_apps=(
        com.mattjakeman.ExtensionManager
        com.spotify.Client
        com.termius.Termius
        net.cozic.joplin_desktop
        us.zoom.Zoom
        it.mijorus.gearlever
    )
    
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
    
    log "Downloading Ledger udev rules script..."
    if curl -fsSL -o "$temp_script" https://raw.githubusercontent.com/LedgerHQ/udev-rules/master/add_udev_rules.sh 2>> "$LOG_FILE"; then
        log "Downloaded Ledger udev rules script, reviewing..."
        
        # Basic safety check
        if grep -q "rm -rf" "$temp_script" || grep -q "dd if=" "$temp_script"; then
            log_error "Script contains potentially dangerous commands, skipping"
            rm -f "$temp_script"
            return 1
        fi
        
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

download_third_party_apps() {
    log_section "Downloading third-party applications"
    
    mkdir -p "$PACKAGES_DIR"
    cd "$PACKAGES_DIR"
    
    # Ledger Live
    log "Checking for Ledger Live updates..."
    local ledger_url
    ledger_url=$(curl -s -L -w '%{url_effective}' -o /dev/null "https://download.live.ledger.com/latest/linux")
    local ledger_file
    ledger_file=$(basename "$ledger_url")
    
    if [[ -n "$ledger_file" ]] && [[ ! -f "$ledger_file" ]]; then
        log "Downloading Ledger Live..."
        find . -maxdepth 1 -name "ledger-live-desktop-*.AppImage" -delete
        if wget --show-progress "$ledger_url" 2>&1; then
            echo "Ledger Live downloaded: $ledger_file" >> "$LOG_FILE"
        else
            log_error "Failed to download Ledger Live"
        fi
    else
        log "Ledger Live already downloaded"
    fi
    
    # Tabby Terminal
    log "Checking for Tabby Terminal updates..."
    local tabby_url
    tabby_url=$(curl -s "https://api.github.com/repos/Eugeny/tabby/releases/latest" | \
                grep -Eo '"browser_download_url":\s*"[^"]*linux-x64\.rpm"' | head -n 1 | cut -d '"' -f 4)
    
    if [[ -n "$tabby_url" ]]; then
        local tabby_file
        tabby_file=$(basename "$tabby_url")
        if [[ ! -f "$tabby_file" ]]; then
            log "Downloading Tabby Terminal..."
            find . -maxdepth 1 -name "tabby-*.rpm" -delete
            if wget --show-progress "$tabby_url" 2>&1; then
                echo "Tabby Terminal downloaded: $tabby_file" >> "$LOG_FILE"
            else
                log_error "Failed to download Tabby"
            fi
        else
            log "Tabby Terminal already downloaded"
        fi
    fi
    
    # Bruno API Client
    log "Checking for Bruno updates..."
    local bruno_url
    bruno_url=$(curl -s "https://api.github.com/repos/usebruno/bruno/releases/latest" | \
                grep -Eo '"browser_download_url":\s*"[^"]*_x86_64_linux\.rpm"' | head -n 1 | cut -d '"' -f 4)
    
    if [[ -n "$bruno_url" ]]; then
        local bruno_file
        bruno_file=$(basename "$bruno_url")
        if [[ ! -f "$bruno_file" ]]; then
            log "Downloading Bruno..."
            find . -maxdepth 1 -name "bruno_*.rpm" -delete
            if wget --show-progress "$bruno_url" 2>&1; then
                echo "Bruno downloaded: $bruno_file" >> "$LOG_FILE"
            else
                log_error "Failed to download Bruno"
            fi
        else
            log "Bruno already downloaded"
        fi
    fi
    
    # Telegram Desktop
    log "Checking for Telegram Desktop updates..."
    local tg_url
    tg_url=$(curl -s "https://api.github.com/repos/telegramdesktop/tdesktop/releases/latest" | \
             grep -Eo '"browser_download_url":\s*"[^"]*tsetup\.[0-9]+\.[0-9]+\.[0-9]+\.tar\.xz"' | \
             head -n 1 | cut -d '"' -f 4)
    
    if [[ -n "$tg_url" ]]; then
        local tg_file
        tg_file=$(basename "$tg_url")
        if [[ ! -f "$tg_file" ]]; then
            log "Downloading Telegram Desktop..."
            find . -maxdepth 1 -name "tsetup.*.tar.xz" -delete
            if wget --show-progress "$tg_url" 2>&1; then
                echo "Telegram Desktop downloaded: $tg_file" >> "$LOG_FILE"
            else
                log_error "Failed to download Telegram"
            fi
        else
            log "Telegram Desktop already downloaded"
        fi
    fi
    
    # MikroTik WinBox
    log "Checking for WinBox updates..."
    local winbox_url
    winbox_url=$(curl -sL "https://mikrotik.com/download" | \
                 grep -Eo 'https://download\.mikrotik\.com/routeros/winbox/[^"]+/WinBox_Linux\.zip' | head -n 1)
    
    if [[ -n "$winbox_url" ]]; then
        local win_ver
        win_ver=$(printf '%s\n' "$winbox_url" | awk -F'/' '{print $(NF-1)}')
        local winbox_file="winbox_${win_ver}.zip"
        
        if [[ ! -f "$winbox_file" ]]; then
            log "Downloading WinBox..."
            find . -maxdepth 1 -name "winbox_*.zip" -delete
            if wget --show-progress -O "$winbox_file" "$winbox_url" 2>&1; then
                echo "WinBox downloaded: $winbox_file" >> "$LOG_FILE"
            else
                log_error "Failed to download WinBox"
            fi
        else
            log "WinBox already downloaded"
        fi
    fi
    
    # balenaEtcher
    log "Checking for balenaEtcher updates..."
    local etcher_url
    etcher_url=$(curl -s "https://api.github.com/repos/balena-io/etcher/releases/latest" | \
                 grep -Eo '"browser_download_url":\s*"[^"]*balenaEtcher-linux-x64-[0-9.]+\.zip"' | \
                 cut -d '"' -f 4 | head -n 1)
    
    if [[ -n "$etcher_url" ]]; then
        local etcher_file
        etcher_file=$(basename "$etcher_url")
        if [[ ! -f "$etcher_file" ]]; then
            log "Downloading balenaEtcher..."
            find . -maxdepth 1 -name "balenaEtcher-linux-x64-*.zip" -delete
            if wget --show-progress "$etcher_url" 2>&1; then
                echo "balenaEtcher downloaded: $etcher_file" >> "$LOG_FILE"
            else
                log_error "Failed to download balenaEtcher"
            fi
        else
            log "balenaEtcher already downloaded"
        fi
    fi
    
    # Visual Studio Code
    log "Checking for Visual Studio Code updates..."
    local vsc_url
    vsc_url=$(curl -s -L -w '%{url_effective}' -o /dev/null "https://code.visualstudio.com/sha/download?build=stable&os=linux-rpm-x64")
    local vsc_file
    vsc_file=$(basename "$vsc_url")
    
    if [[ -n "$vsc_file" ]] && [[ ! -f "$vsc_file" ]]; then
        log "Downloading Visual Studio Code..."
        find . -maxdepth 1 -name "code-*.rpm" -delete
        if wget --show-progress "$vsc_url" 2>&1; then
            echo "Visual Studio Code downloaded: $vsc_file" >> "$LOG_FILE"
        else
            log_error "Failed to download VS Code"
        fi
    else
        log "Visual Studio Code already downloaded"
    fi
    
    echo ""
    log_success "Third-party applications downloaded"
    cd - >/dev/null
}

install_third_party_apps() {
    log_section "Installing third-party applications"
    
    cd "$PACKAGES_DIR"
    mkdir -p "$APPS_DIR"
    
    # Install RPM packages
    local rpm_files=(./*.rpm)
    if [[ "${rpm_files[0]}" != "./*.rpm" ]]; then
        echo ""
        log "Installing RPM packages..."
        echo ""
        if sudo rpm -Uvh --nodeps "${rpm_files[@]}"; then
            echo "RPM packages installed successfully" >> "$LOG_FILE"
            echo ""
            log_success "RPM packages installed"
        else
            echo "RPM packages installation had some errors" >> "$LOG_FILE"
            echo ""
            log_error "Some RPM packages failed to install"
        fi
    fi
    
    # Extract Telegram
    local tg_archives=(./tsetup*.tar.xz)
    if [[ "${tg_archives[0]}" != "./tsetup*.tar.xz" ]]; then
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
    
    cd - >/dev/null
}

create_update_alias() {
    log_section "Creating update alias"
    
    local update_alias="alias update='sudo dnf upgrade --refresh -y; sudo dnf autoremove -y; sudo dnf clean packages; sudo update-pciids || true; flatpak update -y; sudo fwupdmgr refresh --force; sudo fwupdmgr update -y'"
    
    if [[ -f "$HOME/.zshrc" ]]; then
        sed -i -E '/^[[:space:]]*alias[[:space:]]+update=/d' "$HOME/.zshrc" 2>/dev/null || true
        printf '\n# System update alias\n%s\n' "$update_alias" >> "$HOME/.zshrc"
        log_success "Update alias added to .zshrc"
    else
        log_error ".zshrc not found, skipping alias creation"
    fi
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    log_section "Fedora Workstation Post-Installation Setup v${SCRIPT_VERSION}"
    log "Script started at $(date)"
    log "Log file: $LOG_FILE"
    
    check_fedora
    
    # Font and terminal setup
    install_basic_packages
    install_nerd_font
    configure_terminal_font
    
    # Shell setup
    setup_zsh
    change_default_shell
    
    # System optimization
    optimize_system
    disable_gnome_software_autostart
    
    # Repository setup
    setup_repositories
    upgrade_system
    
    # Package installation
    install_packages
    install_flatpaks
    
    # Hardware support
    setup_ledger_udev
    
    # Third-party applications
    download_third_party_apps
    install_third_party_apps
    
    # Final configuration
    create_update_alias
    
    log_section "Setup Complete!"
    log "Log file saved to: $LOG_FILE"
    log ""
    log "Next steps:"
    log "  1. Restart your terminal or run: source ~/.zshrc"
    log "  2. Log out and log back in to use ZSH as default shell"
    log "  3. Run 'update' command to check for updates anytime"
    log ""
    log "Installed applications:"
    log "  - Terminal: Tabby, Ptyxis (configured)"
    log "  - Development: VS Code, Bruno"
    log "  - Communication: Telegram, Zoom"
    log "  - Utilities: Ledger Live, WinBox, balenaEtcher"
    log "  - Notes: Joplin"
    log ""
    log "All done! Enjoy your Fedora setup!"
}

# Run main function
main "$@"
