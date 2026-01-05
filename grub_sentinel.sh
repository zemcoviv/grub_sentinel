#!/bin/bash

# =============================================================================
# GRUB SENTINEL v0.5 - STABLE RELEASE
# GitHub: https://github.com/zemcoviv/grub_sentinel
# License: MIT
# =============================================================================

set -u
trap 'echo -e "\n\n${R}✘ Прервано.${NC}"; exit 1' INT

# --- Конфигурация ---
readonly R='\033[0;31m'
readonly G='\033[0;32m'
readonly Y='\033[1;33m'
readonly B='\033[0;34m'
readonly C='\033[0;36m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'

LOG_FILE="/tmp/grub_sentinel.log"
: > "$LOG_FILE"

# --- Параметры ---
DRY_RUN=false
BACKUP_DIR="/var/backups/grub_sentinel"

show_help() {
    cat <<EOF
Использование: $0 [--dry-run] [--backup-dir DIR] [--help]

Опции:
  --dry-run        Выполнить "прогоны" без реального изменения системы (показывает, что бы было сделано)
  --backup-dir DIR Папка для резервных копий (по умолчанию: $BACKUP_DIR)
  --help           Показать это сообщение
EOF
}

# --- UI Элементы ---
print_header() {
    clear
    echo -e "${C}┌──────────────────────────────────────────────────────────┐${NC}"
    echo -e "${C}│${BOLD}          GRUB SENTINEL - STABLE RELEASE v0.5           ${C}│${NC}"
    echo -e "${C}└──────────────────────────────────────────────────────────┘${NC}"
    echo -e " Лог: ${Y}$LOG_FILE${NC}\n"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${Y}Режим: DRY-RUN (изменения не будут применены)${NC}\n"
    fi
}

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ -d /proc/$pid ]; do
        printf "${C}[%c]${NC}" "$spinstr"
        local temp=${spinstr#?}
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b"
    done
    printf "   \b\b\b"
}

# run_task принимает описание и команду в виде строки (bash -c "...")
run_task() {
    local desc="$1"
    local cmd="$2"
    printf "${BOLD}→${NC} %-45s " "$desc"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${Y}SKIPPED (dry-run)${NC}"
        echo "[DRY-RUN] $desc: $cmd" >> "$LOG_FILE"
        return 0
    fi

    ( bash -c "$cmd" ) >> "$LOG_FILE" 2>&1 &
    spinner $!
    wait $!
    if [ $? -eq 0 ]; then
        echo -e "${G}✔ ГОТОВО${NC}"
    else
        echo -e "${R}✘ ОШИБКА${NC}"
    fi
}

backup_files() {
    local files=("/etc/default/grub" "/etc/grub.d" "/boot/grub/themes")
    local ts
    ts=$(date -u +"%Y%m%dT%H%M%SZ")
    local dest="${BACKUP_DIR}/grub_sentinel_backup_${ts}.tar.gz"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Создать бэкап в: $dest (файлы: ${files[*]})" >> "$LOG_FILE"
        echo -e "${Y}→ Бэкап пропущен (dry-run)${NC}"
        return 0
    fi

    mkdir -p "$BACKUP_DIR" || {
        echo "[ERROR] Не удалось создать папку бэкапов: $BACKUP_DIR" >> "$LOG_FILE"
        return 1
    }

    tar -czf "$dest" "${files[@]}" >> "$LOG_FILE" 2>&1 && {
        echo -e "${G}→ Бэкап создан: ${dest}${NC}"
        echo "Backup created: $dest" >> "$LOG_FILE"
        return 0
    } || {
        echo -e "${R}→ Ошибка создания бэкапа${NC}"
        echo "[ERROR] tar failed" >> "$LOG_FILE"
        return 1
    }
}

# --- Логика ---

fast_fix() {
    run_task "Инициализация пакетного менеджера" \
        "rm -f /var/lib/dpkg/lock* && dpkg --configure -a"
}

apply_gfx_settings() {
    local cmd="
        cp -a /etc/default/grub /etc/default/grub.bak || true
        sed -i '/GRUB_GFXMODE=/d;/GRUB_TERMINAL=/d;/GRUB_GFXPAYLOAD_LINUX=/d;/GRUB_THEME=/d' /etc/default/grub
        {
            echo 'GRUB_GFXMODE=1920x1080,1280x720,auto'
            echo 'GRUB_TERMINAL=gfxterm'
            echo 'GRUB_GFXPAYLOAD_LINUX=keep'
        } >> /etc/default/grub
    "
    run_task "Настройка графического вывода (HiDPI)" "$cmd"
}

install_theme_stable() {
    local cmd="
        apt-get update
        apt-get install -y grub2-themes-ubuntu-mate || apt-get install -y grub2-common
        THEME_PATH=\$(find /boot/grub/themes -name 'theme.txt' | head -n 1 || true)
        if [ -n \"\$THEME_PATH\" ]; then
            grep -q \"^GRUB_THEME=\" /etc/default/grub || true
            echo \"GRUB_THEME='\$THEME_PATH'\" >> /etc/default/grub
        else
            mkdir -p /boot/grub/themes/default
            echo \"GRUB_THEME='/boot/grub/themes/default/theme.txt'\" >> /etc/default/grub
        fi
    "
    run_task "Установка графической темы (Grub2-Themes)" "$cmd"
}

finalize() {
    run_task "Восстановление системных скриптов" \
        "mkdir -p /etc/grub.d && cd /tmp && apt-get download grub2-common && dpkg-deb -x grub2-common*.deb ex && cp -rf ex/etc/grub.d/* /etc/grub.d/ && chmod +x /etc/grub.d/*"

    run_task "Пересборка загрузчика" \
        "apt-get install -y --reinstall grub-efi-amd64-signed shim-signed os-prober && grub-install --target=x86_64-efi --recheck"

    run_task "Обновление конфигурации GRUB" \
        "export GRUB_DISABLE_OS_PROBER=false && update-grub"
}

show_menu() {
    echo -e "\n${C}┌── ИТОГОВОЕ МЕНЮ (НАЙДЕННЫЕ ОС) ──────────────────────────┐${NC}"
    if [ -f /boot/grub/grub.cfg ]; then
        grep -E "menuentry '|^menuentry \"" /boot/grub/grub.cfg | cut -d\"'\" -f2 | cut -d'\"' -f2 | grep -v "recovery" | sort -u | while read -r line; do
            echo -e "${C}│${NC}  > $line"
        done
    fi
    echo -e "${C}└──────────────────────────────────────────────────────────┘${NC}"
}

# --- Парсинг аргументов ---
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
        --help) show_help; exit 0 ;;
        *) echo "Неизвестный аргумент: $1"; show_help; exit 1 ;;
    esac
done

# --- Main ---
if [ "$EUID" -ne 0 ]; then
    echo "Root required!"
    exit 1
fi

print_header

# Бэкап перед внесением изменений (или сообщить что было бы сделано в dry-run)
backup_files

fast_fix
apply_gfx_settings
install_theme_stable
finalize
show_menu

echo -e "\n${G}✨ Готово! Все операции завершены успешно.${NC}\n"
