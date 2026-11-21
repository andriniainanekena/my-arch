#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ML4W_PROFILE='https://raw.githubusercontent.com/mylinuxforwork/dotfiles/2.17/hyprland-dotfiles-stable.dotinst'
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/arch-workstation"
BACKUP_DIR="$STATE_DIR/backups/$(date +%Y%m%d_%H%M%S)"
SUDO_KEEPALIVE_PID=''
TEMP_DIR=''
SKIP_ML4W=false

info() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

error() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    printf '%s\n' 'Usage: bash install.sh [--skip-ml4w] [--help] - Set up an Arch Linux workstation.'
}

for arg in "$@"; do
    case "$arg" in
        --skip-ml4w)
            SKIP_ML4W=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $arg"
            ;;
    esac
done

[[ -f /etc/arch-release ]] || error 'Arch Linux is required'
[[ $EUID -ne 0 ]] || error 'Run without sudo'
[[ -f "$ROOT_DIR/config/assets/wallpaper.jpg" ]] || error 'Missing config/assets/wallpaper.jpg'
[[ -f "$ROOT_DIR/config/assets/menu.svg" ]] || error 'Missing config/assets/menu.svg'
[[ -d "$ROOT_DIR/config/overrides/.config" ]] || error 'Missing config/overrides/.config'

cleanup() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi

    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

trap cleanup EXIT
trap 'warn "Failed at line $LINENO. Backups: $BACKUP_DIR"' ERR

start_sudo() {
    info 'Checking sudo access'
    sudo -v
    (while kill -0 "$$" 2>/dev/null; do
        sudo -n -v >/dev/null 2>&1 || true
        sleep 40
    done) &
    SUDO_KEEPALIVE_PID=$!
}

install_packages() {
    local file="$1" line
    local -a packages=()

    [[ -f "$file" ]] || error "Missing package list: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -n "$line" ]] || continue
        [[ "$line" =~ ^[a-zA-Z0-9@+._-]+$ ]] || error "Invalid package: $line"
        packages+=("$line")
    done < "$file"
    if ((${#packages[@]})); then
        info "Installing $(basename "$file"): ${#packages[@]} packages"
        sudo pacman -S --needed --noconfirm "${packages[@]}"
    fi
}

backup_user_file() {
    local target="$1" rel

    [[ -e "$target" || -L "$target" ]] || return 0
    rel="${target#"$HOME"/}"
    if [[ -e "$BACKUP_DIR/home/$rel" || -L "$BACKUP_DIR/home/$rel" ]]; then
        return
    fi

    mkdir -p -- "$BACKUP_DIR/home/$(dirname -- "$rel")"
    cp -a -- "$target" "$BACKUP_DIR/home/$rel"
}

backup_system_file() {
    local target="$1" rel

    [[ -e "$target" || -L "$target" ]] || return 0
    rel="${target#/}"
    if sudo test -e "$BACKUP_DIR/system/$rel"; then
        return
    fi

    mkdir -p -- "$BACKUP_DIR/system/$(dirname -- "$rel")"
    sudo cp -a -- "$target" "$BACKUP_DIR/system/$rel"
}

copy_user_file() {
    local source="$1" target="$2"

    [[ -f "$source" ]] || error "Missing source: $source"
    if [[ -f "$target" ]] && cmp -s -- "$source" "$target"; then
        return
    fi
    backup_user_file "$target"
    mkdir -p -- "$(dirname -- "$target")"
    cp -L -- "$source" "$target"
}

install_ml4w() {
    if [[ -f "$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config/hypr/hyprland.lua" ]]; then
        info 'ML4W already installed'
        return
    fi

    if "$SKIP_ML4W"; then
        error '--skip-ml4w requires an installed ML4W profile'
    fi

    info 'Installing ML4W 2.17'
    local executable="$HOME/.local/bin/ml4w-dotfiles-installer"
    if [[ ! -x "$executable" ]]; then
        TEMP_DIR="${TEMP_DIR:-$(mktemp -d)}"
        git clone --depth=1 \
            https://github.com/mylinuxforwork/ml4w-dotfiles-installer.git \
            "$TEMP_DIR/ml4w-installer"
        make -C "$TEMP_DIR/ml4w-installer" install
    fi
    ML4W_YES=1 "$executable" --install "$ML4W_PROFILE"
    [[ -f "$HOME/.config/hypr/hyprland.lua" ]] || error 'ML4W installation failed'
}

apply_overrides() {
    info 'Applying desktop settings'
    local root="$ROOT_DIR/config/overrides" source relative

    while IFS= read -r -d '' source; do
        relative="${source#"$root"/}"
        copy_user_file "$source" "$HOME/$relative"
    done < <(find "$root/.config" -type f -print0 | sort -z)

    if [[ -e "$HOME/.config/ml4w/settings/waybar-disabled" ]]; then
        backup_user_file "$HOME/.config/ml4w/settings/waybar-disabled"
        rm -f -- "$HOME/.config/ml4w/settings/waybar-disabled"
    fi

    local icon="$ROOT_DIR/config/assets/menu.svg"
    copy_user_file "$icon" "$HOME/.local/share/ml4w-custom/menu.svg"
    copy_user_file "$icon" "$HOME/.config/waybar/assets/ml4w-icon.svg"

    local bar="$HOME/.config/quickshell/StatusbarApp/StatusbarWindow.qml"
    if [[ -f "$bar" ]]; then
        if grep -qE 'readonly property int windowGap: [0-9]+' "$bar"; then
            if ! grep -q 'readonly property int windowGap: 5' "$bar"; then
                backup_user_file "$bar"
                sed -i -E \
                    's/readonly property int windowGap: [0-9]+/readonly property int windowGap: 5/' \
                    "$bar"
            fi
        else
            warn 'Quickshell layout changed; patch skipped'
        fi
    fi

    if lspci 2>/dev/null | grep -Eqi \
        'HD Graphics 4600|4th Gen Core Processor Integrated Graphics Controller|Haswell'; then
        local custom="$HOME/.config/hypr/custom.lua"
        python - "$custom" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
if 'skip_non_kms_dmabuf_formats' not in source:
    source = source.replace(
        '    general = {',
        '    quirks = {\n'
        '        skip_non_kms_dmabuf_formats = false,\n'
        '    },\n\n'
        '    general = {',
        1,
    )
    path.write_text(source)
PY
    fi

    if command -v gsettings >/dev/null 2>&1; then
        gsettings set org.gnome.desktop.interface icon-theme 'Tela-circle-blue-dark' || true
        gsettings set org.gnome.desktop.interface font-name 'Fira Sans Semi-Bold 10' || true
    fi

    if command -v xdg-mime >/dev/null 2>&1; then
        xdg-mime default imv.desktop image/png image/jpeg image/gif image/webp image/bmp image/tiff || true
        xdg-mime default org.pwmt.zathura-pdf-mupdf.desktop application/pdf || true
    fi
}

install_wallpaper() {
    info 'Setting wallpaper'
    local wallpaper="$HOME/.config/ml4w/wallpapers/workstation.jpg"

    copy_user_file "$ROOT_DIR/config/assets/wallpaper.jpg" "$wallpaper"
    local cache="$HOME/.cache/ml4w/hyprland-dotfiles/current_wallpaper"
    mkdir -p -- "$(dirname -- "$cache")"
    if [[ -f "$cache" ]]; then
        backup_user_file "$cache"
    fi
    printf '%s\n' "$wallpaper" > "$cache"
}

install_silent_sddm() {
    info 'Installing SilentSDDM 1.5.1'
    TEMP_DIR="${TEMP_DIR:-$(mktemp -d)}"
    local theme_src="$TEMP_DIR/SilentSDDM"
    local theme_dst='/usr/share/sddm/themes/arch-workstation'

    git clone --depth=1 --branch v1.5.1 https://github.com/uiriansan/SilentSDDM.git "$theme_src"
    cp -- "$ROOT_DIR/config/assets/wallpaper.jpg" "$theme_src/backgrounds/workstation.jpg"

    python - "$theme_src" "$ROOT_DIR/config/sddm/theme.conf" <<'PY'
from configparser import ConfigParser
from pathlib import Path
import sys

root = Path(sys.argv[1])
overrides_path = Path(sys.argv[2])
configuration = ConfigParser(interpolation=None)
configuration.optionxform = str
configuration.read(root / 'configs/default.conf', encoding='utf-8')
overrides = ConfigParser(interpolation=None)
overrides.optionxform = str
overrides.read(overrides_path, encoding='utf-8')
for section in overrides.sections():
    if not configuration.has_section(section):
        configuration.add_section(section)
    for key, value in overrides.items(section):
        configuration.set(section, key, value)
with (root / 'configs/arch-workstation.conf').open('w', encoding='utf-8') as output:
    configuration.write(output)
metadata = root / 'metadata.desktop'
content = metadata.read_text(encoding='utf-8')
content = content.replace('Theme-Id=silent', 'Theme-Id=arch-workstation', 1)
content = content.replace('ConfigFile=configs/default.conf', 'ConfigFile=configs/arch-workstation.conf', 1)
metadata.write_text(content, encoding='utf-8')
PY

    sudo install -d -m 755 "$theme_dst"
    sudo rsync -a --exclude='.git' "$theme_src/" "$theme_dst/"
    sudo install -d -m 755 /usr/share/fonts/arch-workstation
    sudo rsync -a "$theme_src/fonts/" /usr/share/fonts/arch-workstation/
    sudo fc-cache -f /usr/share/fonts/arch-workstation >/dev/null

    local sddm_override='/etc/sddm.conf.d/zz-arch-workstation.conf'
    sudo install -d -m 755 /etc/sddm.conf.d
    backup_system_file "$sddm_override"
    sudo tee "$sddm_override" >/dev/null <<'EOF'
[General]
InputMethod=qtvirtualkeyboard
GreeterEnvironment=QML2_IMPORT_PATH=/usr/share/sddm/themes/arch-workstation/components/,QT_IM_MODULE=qtvirtualkeyboard

[Theme]
Current=arch-workstation
EOF

    if [[ -f /etc/sddm.conf ]]; then
        backup_system_file /etc/sddm.conf
        sudo python - /etc/sddm.conf <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
section = re.search(r'(?ms)^\[Theme\]\s*\n(?P<body>.*?)(?=^\[|\Z)', text)
if section and re.search(r'(?m)^\s*Current\s*=', section.group('body')):
    body = re.sub(r'(?m)^\s*Current\s*=.*$', 'Current=arch-workstation', section.group('body'), count=1)
    text = text[:section.start('body')] + body + text[section.end('body'):]
    path.write_text(text, encoding='utf-8')
PY
    fi

    local manager='/etc/systemd/system/display-manager.service' active=''
    if [[ -L "$manager" ]]; then
        active="$(readlink -f "$manager")"
    fi
    case "$active" in
        ''|*/sddm.service)
            sudo systemctl enable sddm.service
            ;;
        *)
            warn "Display manager unchanged: $active"
            ;;
    esac
}

install_virtualbox() {
    info 'Installing VirtualBox'
    local kernel headers found=false
    local -a headers_to_install=()

    for kernel in linux linux-lts linux-zen linux-hardened linux-rt linux-rt-lts; do
        if pacman -Qq "$kernel" >/dev/null 2>&1; then
            headers="${kernel}-headers"
            if pacman -Si "$headers" >/dev/null 2>&1; then
                headers_to_install+=("$headers")
                found=true
            fi
        fi
    done
    if ((${#headers_to_install[@]})); then
        sudo pacman -S --needed --noconfirm "${headers_to_install[@]}"
    fi

    install_packages "$ROOT_DIR/packages/virtualization.txt"
    if ! "$found"; then
        warn 'Kernel headers not found; VirtualBox may not work'
    fi

    if getent group vboxusers >/dev/null && ! id -nG "$USER" | grep -qw vboxusers; then
        sudo usermod -aG vboxusers "$USER"
    fi
}

install_arduino_ide() {
    info 'Installing Arduino IDE'
    local app_dir="$HOME/.local/opt/arduino-ide"
    local app_image="$app_dir/Arduino-IDE.AppImage"
    local api='https://api.github.com/repos/arduino/arduino-ide/releases/latest'
    local release url filename

    TEMP_DIR="${TEMP_DIR:-$(mktemp -d)}"
    release="$TEMP_DIR/arduino-release.json"
    curl --fail --location --silent --show-error --retry 3 "$api" -o "$release"
    url="$(jq -er \
        '[.assets[] | select(.name | endswith("_Linux_64bit.AppImage")) | .browser_download_url] | first' \
        "$release")" \
        || error 'Arduino IDE AppImage not found'
    [[ "$url" == https://github.com/arduino/arduino-ide/releases/download/* ]] \
        || error 'Unexpected Arduino download URL'

    filename="$TEMP_DIR/Arduino-IDE.AppImage"
    curl --fail --location --show-error --retry 3 "$url" -o "$filename"
    [[ -s "$filename" ]] || error 'Arduino IDE download is empty'
    mkdir -p "$app_dir" "$HOME/.local/bin" "$HOME/.local/share/applications"
    backup_user_file "$app_image"
    backup_user_file "$HOME/.local/bin/arduino-ide"
    backup_user_file "$HOME/.local/share/applications/arduino-ide.desktop"
    install -m 755 "$filename" "$app_image"

    cat > "$HOME/.local/bin/arduino-ide" <<'ARDUINO_LAUNCHER'
#!/usr/bin/env bash
exec "$HOME/.local/opt/arduino-ide/Arduino-IDE.AppImage" "$@"
ARDUINO_LAUNCHER
    chmod 755 "$HOME/.local/bin/arduino-ide"
    cat > "$HOME/.local/share/applications/arduino-ide.desktop" <<DESKTOP_ENTRY
[Desktop Entry]
Type=Application
Name=Arduino IDE
Comment=Arduino development environment
Exec=$HOME/.local/bin/arduino-ide %F
Icon=applications-development
Categories=Development;IDE;Electronics;
Terminal=false
DESKTOP_ENTRY

    if getent group uucp >/dev/null && ! id -nG "$USER" | grep -qw uucp; then
        sudo usermod -aG uucp "$USER"
    fi
}

setup_postgres() {
    info 'Setting up PostgreSQL'
    local data='/var/lib/postgres/data'

    if sudo test -f "$data/PG_VERSION"; then
        info 'PostgreSQL already initialized'
    else
        if sudo test -d "$data" && [[ -n "$(sudo find "$data" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
            error "Invalid PostgreSQL data directory: $data"
        fi
        sudo install -d -o postgres -g postgres -m 700 "$data"
        sudo -u postgres initdb -D "$data" --locale=C.UTF-8 --encoding=UTF8
    fi

    sudo systemctl enable --now postgresql.service
}

info 'Starting workstation setup'
start_sudo
info 'Updating system'
sudo pacman -Syu --noconfirm
install_packages "$ROOT_DIR/packages/base.txt"
install_ml4w
install_packages "$ROOT_DIR/packages/desktop.txt"
install_packages "$ROOT_DIR/packages/development.txt"
install_packages "$ROOT_DIR/packages/database.txt"
install_virtualbox
install_arduino_ide
apply_overrides
install_wallpaper
install_silent_sddm
setup_postgres

if command -v ml4w-dock >/dev/null 2>&1; then
    ml4w-dock disable >/dev/null 2>&1 || true
fi
info 'Setup complete. Reboot to apply changes.'
info "Backups: $BACKUP_DIR"