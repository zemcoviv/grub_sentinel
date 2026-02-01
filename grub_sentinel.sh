#!/bin/bash

# =============================================================================
# GRUB SENTINEL v0.6.2 - CLEAN PARSE RELEASE
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

# ИСПРАВЛЕНИЕ 1: Принудительное удаление старого лога во избежание конфликта прав
rm -f "$LOG_FILE"
: > "$LOG_FILE"

# --- Параметры ---
DRY_RUN=false
BACKUP_DIR="/var/backups/grub_sentinel"

show_help() {
    cat <<EOF
Использование: $0 [--dry-run] [--backup-dir DIR] [--help]

Опции:
  --dry-run        Выполнить "прогоны" без реального изменения системы
  --backup-dir DIR Папка для резервных копий (по умолчанию: $BACKUP_DIR)
  --help           Показать это сообщение
EOF
}

# --- UI Элементы ---
print_header() {
    clear
    echo -e "${C}┌──────────────────────────────────────────────────────────┐${NC}"
    echo -e "${C}│${BOLD}          GRUB SENTINEL - CLEAN PARSE v0.6.2            ${C}│${NC}"
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

# run_task для фоновых задач
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
        echo "[DRY-RUN] Создать бэкап в: $dest" >> "$LOG_FILE"
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
        sed -i '/GRUB_GFXMODE=/d;/GRUB_TERMINAL=/d;/GRUB_GFXPAYLOAD_LINUX=/d' /etc/default/grub
        {
            echo 'GRUB_GFXMODE=1920x1080,1280x720,auto'
            echo 'GRUB_TERMINAL=gfxterm'
            echo 'GRUB_GFXPAYLOAD_LINUX=keep'
        } >> /etc/default/grub
    "
    run_task "Настройка графического вывода (HiDPI)" "$cmd"
}

prepare_themes() {
    local cmd="
        apt-get update
        apt-get install -y grub2-themes-ubuntu-mate grub2-common || true
        mkdir -p /boot/grub/themes
    "
    run_task "Установка пакетов тем" "$cmd"
}

# --- ИНТЕРАКТИВНЫЕ ФУНКЦИИ ---

select_theme_interactive() {
    echo -e "\n${BOLD}→ Выбор темы оформления:${NC}"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${Y}  (Пропущено в dry-run)${NC}"
        return 0
    fi

    local theme_files=($(find /boot/grub/themes /usr/share/grub/themes -name "theme.txt" 2>/dev/null))
    
    if [ ${#theme_files[@]} -eq 0 ]; then
        echo -e "${Y}  Темы не найдены. Будет использована стандартная.${NC}"
        return 0
    fi

    echo "  0) Отключить тему (стандартная)"
    local i=1
    for theme in "${theme_files[@]}"; do
        local theme_name=$(basename "$(dirname "$theme")")
        echo "  $i) $theme_name ($theme)"
        ((i++))
    done

    local choice
    read -p "  Ваш выбор [0-$((${#theme_files[@]}))]: " choice

    sed -i '/GRUB_THEME=/d' /etc/default/grub

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le ${#theme_files[@]} ]; then
        local selected="${theme_files[$((choice-1))]}"
        echo "GRUB_THEME='$selected'" >> /etc/default/grub
        echo -e "${G}  ✔ Установлена тема: $(basename "$(dirname "$selected")")${NC}"
    else
        echo -e "${Y}  ✔ Тема отключена (используется стандартная)${NC}"
    fi
}

select_boot_priority() {
    echo -e "\n${BOLD}→ Выбор приоритета загрузки:${NC}"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${Y}  (Пропущено в dry-run)${NC}"
        return 0
    fi

    if [ ! -f /boot/grub/grub.cfg ]; then
        echo -e "${R}  Файл grub.cfg не найден! Сначала выполните восстановление.${NC}"
        return 1
    fi

    # ИСПРАВЛЕНИЕ 2: Улучшенный парсинг, учитывающий отступы (табы/пробелы)
    mapfile -t entries < <(grep -E "^[[:space:]]*menuentry ['\"]" /boot/grub/grub.cfg | grep -v "recovery" | sed -E "s/^[[:space:]]*menuentry '([^']+)'.*$/\1/; s/^[[:space:]]*menuentry \"([^\"]+)\".*$/\1/" | grep -v "^if ")
    
    if [ ${#entries[@]} -eq 0 ]; then
        echo -e "${Y}  Записи загрузки не найдены.${NC}"
        return 0
    fi

    local i=0
    for entry in "${entries[@]}"; do
        echo "  $i) $entry"
        ((i++))
    done

    local choice
    read -p "  Загружать по умолчанию [0-$(( ${#entries[@]} - 1 ))]: " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 0 ] && [ "$choice" -lt ${#entries[@]} ]; then
        local selected="${entries[$choice]}"
        
        sed -i '/GRUB_DEFAULT=/d' /etc/default/grub
        echo "GRUB_DEFAULT='$selected'" >> /etc/default/grub
        
        echo -e "${G}  ✔ Приоритет установлен: $selected${NC}"
    else
        echo -e "${Y}  Оставлено значение по умолчанию (обычно 0)${NC}"
    fi
}

# --- Финализация ---

finalize() {
    run_task "Восстановление системных скриптов" \
        "mkdir -p /etc/grub.d && cd /tmp && apt-get download grub2-common && dpkg-deb -x grub2-common*.deb ex && cp -rf ex/etc/grub.d/* /etc/grub.d/ && chmod +x /etc/grub.d/*"

    run_task "Пересборка загрузчика" \
        "apt-get install -y --reinstall grub-efi-amd64-signed shim-signed os-prober && grub-install --target=x86_64-efi --recheck"

    run_task "Генерация конфигурации GRUB" \
        "export GRUB_DISABLE_OS_PROBER=false && update-grub"
}

show_menu() {
    echo -e "\n${C}┌── ИТОГОВОЕ МЕНЮ ─────────────────────────────────────────┐${NC}"
    if [ -f /boot/grub/grub.cfg ]; then
        # ИСПРАВЛЕНИЕ 2 (повтор для финального вывода): учитываем отступы
        grep -E "^[[:space:]]*menuentry ['\"]" /boot/grub/grub.cfg | grep -v "recovery" | sed -E "s/^[[:space:]]*menuentry '([^']+)'.*$/\1/; s/^[[:space:]]*menuentry \"([^\"]+)\".*$/\1/" | grep -v "^if " | sort -u | while read -r line; do
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
    echo "Root required! Run with sudo."
    exit 1
fi

print_header

# Бэкап
backup_files

# Автоматические фиксы
fast_fix
apply_gfx_settings
prepare_themes

# Интерактивная часть
select_theme_interactive
select_boot_priority

# Применение изменений
finalize
show_menu

echo -e "\n${G}✨ Готово! Перезагрузите систему.${NC}\n"
