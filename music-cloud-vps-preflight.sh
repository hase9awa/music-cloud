#!/usr/bin/env bash
set -Eeuo pipefail

# Music Cloud VPS Preflight
# Предварительная настройка VPS перед запуском Music Cloud Installer.
#
# Использование:
#   sudo bash music-cloud-vps-preflight.sh
#   sudo bash music-cloud-vps-preflight.sh --reboot
#   sudo bash music-cloud-vps-preflight.sh --ssh-port 2222
#   sudo bash music-cloud-vps-preflight.sh --ssh-port 2222 --reboot

AUTO_REBOOT=0
SSH_PORT_OVERRIDE=""

log() {
    printf '\n\033[1;36m==> %s\033[0m\n' "$*"
}

ok() {
    printf '\033[1;32mГотово:\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33mВнимание:\033[0m %s\n' "$*" >&2
}

die() {
    printf '\033[1;31mОшибка:\033[0m %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Music Cloud VPS Preflight

Использование:
  sudo bash music-cloud-vps-preflight.sh
  sudo bash music-cloud-vps-preflight.sh --reboot
  sudo bash music-cloud-vps-preflight.sh --ssh-port 2222
  sudo bash music-cloud-vps-preflight.sh --ssh-port 2222 --reboot

Параметры:
  --ssh-port PORT   Явно указать SSH-порт, который нужно разрешить в UFW.
  --reboot          Автоматически перезагрузить VPS в конце, только если
                    система сообщает, что перезагрузка требуется.
  -h, --help        Показать эту справку.
EOF
}

on_error() {
    local line="$1"
    local code="$2"
    printf '\n\033[1;31mНастройка остановлена: строка %s, код %s.\033[0m\n' \
        "$line" "$code" >&2
}

trap 'on_error "$LINENO" "$?"' ERR

while (( $# > 0 )); do
    case "$1" in
        --reboot)
            AUTO_REBOOT=1
            ;;
        --ssh-port)
            shift
            (( $# > 0 )) || die "После --ssh-port необходимо указать номер порта."
            SSH_PORT_OVERRIDE="$1"
            ;;
        --ssh-port=*)
            SSH_PORT_OVERRIDE="${1#*=}"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Неизвестный аргумент: $1"
            ;;
    esac
    shift
done

[[ "${EUID}" -eq 0 ]] || die "Запустите скрипт через sudo или от root."

validate_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

if [[ -n "${SSH_PORT_OVERRIDE}" ]]; then
    validate_port "${SSH_PORT_OVERRIDE}" ||
        die "Некорректный SSH-порт: ${SSH_PORT_OVERRIDE}"
fi

log "Проверка операционной системы"

[[ -r /etc/os-release ]] || die "Не найден /etc/os-release."
. /etc/os-release

case "${ID:-}" in
    debian|ubuntu)
        ;;
    *)
        case " ${ID_LIKE:-} " in
            *" debian "*|*" ubuntu "*)
                warn "Обнаружен производный дистрибутив: ${PRETTY_NAME:-${ID:-неизвестно}}."
                ;;
            *)
                die "Скрипт предназначен для Debian/Ubuntu и совместимых систем."
                ;;
        esac
        ;;
esac

command -v apt-get >/dev/null 2>&1 || die "Команда apt-get не найдена."
[[ -d /run/systemd/system ]] || die "Требуется система с systemd."

ok "ОС: ${PRETTY_NAME:-${ID}}"

log "Определение SSH-порта"

SSH_PORT="${SSH_PORT_OVERRIDE}"

if [[ -z "${SSH_PORT}" && -n "${SSH_CONNECTION:-}" ]]; then
    SSH_PORT="$(awk '{print $4}' <<<"${SSH_CONNECTION}")"
fi

if [[ -z "${SSH_PORT}" ]] && command -v sshd >/dev/null 2>&1; then
    SSH_PORT="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)"
fi

if [[ -z "${SSH_PORT}" ]]; then
    SSH_PORT="22"
    warn "Не удалось определить SSH-порт автоматически. Используется порт 22."
fi

validate_port "${SSH_PORT}" || die "Некорректный SSH-порт: ${SSH_PORT}"

ok "SSH-порт: ${SSH_PORT}"

log "Обновление системы"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

apt-get update
apt-get full-upgrade -y

ok "Системные пакеты обновлены."

log "Установка необходимых утилит"

apt-get install -y \
    ca-certificates \
    curl \
    dnsutils \
    nano \
    ufw

ok "Установлены curl, ca-certificates, dnsutils, nano и ufw."

log "Настройка UFW"

ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
ufw allow 80/tcp comment 'HTTP / Caddy' >/dev/null
ufw allow 443/tcp comment 'HTTPS / Caddy' >/dev/null

if ufw status 2>/dev/null | grep -q '^Status: active'; then
    ok "UFW уже был активен. Необходимые правила добавлены."
else
    ufw --force enable >/dev/null
    ok "UFW включён."
fi

printf '\nТекущие правила UFW:\n'
ufw status numbered

log "Финальная проверка"

printf '\nРазрешено для Music Cloud VPS:\n'
printf '  SSH:     TCP %s\n' "${SSH_PORT}"
printf '  HTTP:    TCP 80\n'
printf '  HTTPS:   TCP 443\n'

if [[ -f /var/run/reboot-required ]]; then
    warn "После обновления система требует перезагрузку."

    if (( AUTO_REBOOT == 1 )); then
        ok "Предварительная настройка завершена. VPS будет перезагружен."
        sleep 3
        systemctl reboot
    else
        cat <<'EOF'

Для перезагрузки выполните:
  sudo reboot

После повторного подключения можно запускать Music Cloud Installer:
  sudo bash ./install-music-cloud.sh --mode vps

Для автоматической перезагрузки при необходимости:
  sudo bash music-cloud-vps-preflight.sh --reboot
EOF
    fi
else
    ok "Перезагрузка не требуется."
    cat <<'EOF'

VPS готов к установке Music Cloud.

Следующий шаг:
  sudo bash ./install-music-cloud.sh --mode vps
EOF
fi
