#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Универсальный установщик Music Cloud
#
# Debian/Ubuntu с systemd; архитектуры amd64 или arm64.
#
# Режимы установки:
# 
# vps  — сервер с публичным IPv4/DNS. Caddy получает HTTPS через входящие
#        подключения TCP 80/443.
#
# home — домашняя сеть/CGNAT. Используется исходящее подключение Cloudflare
#        Tunnel к локальному Caddy.
#
# auto — сравнивает публичный IPv4 с адресами, назначенными этому устройству,
#        и предлагает режим vps или home; пользователь может изменить выбор.
#
# Публичные адреса на одном домене:
#
# https://example.com/              Navidrome
# https://example.com/uploads/      загрузчик Copyparty
# https://example.com/tags/         редактор метаданных Tagr
#
# Скрипт не создаёт системных пользователей и не изменяет настройки SSH.
#
# Интерактивная установка:
#
# sudo bash install-music-cloud-universal.sh
#
# Принудительный выбор режима установки:
#
# sudo bash install-music-cloud-universal.sh --mode vps
# sudo bash install-music-cloud-universal.sh --mode home
#
# Восстановление импорта музыки в существующей установке
# без пересборки контейнеров:
#
# sudo bash install-music-cloud-universal.sh --repair-import
#
# Диагностика / удаление:
#
# sudo bash install-music-cloud-universal.sh --diagnose
# sudo bash install-music-cloud-universal.sh --uninstall
#
# ==============================================================================

APP_NAME="music-cloud"
SCRIPT_VERSION="5.1.1-universal"
DATA_DIR="/srv/${APP_NAME}"
STACK_DIR="/opt/${APP_NAME}"
STATE_DIR="/etc/${APP_NAME}"

DEFAULT_UPLOAD_DIR="${DATA_DIR}/upload"
DEFAULT_LIBRARY_DIR="${DATA_DIR}/library"
UPLOAD_DIR="${DEFAULT_UPLOAD_DIR}"
LIBRARY_DIR="${DEFAULT_LIBRARY_DIR}"

COMPOSE_FILE="${STACK_DIR}/compose.yaml"
TAGR_SOURCE_DIR="${STACK_DIR}/tagr-src"
TAGR_ENTRYPOINT_SCRIPT="${STACK_DIR}/tagr-entrypoint.sh"
COPYPARTY_CONFIG_FILE="${STACK_DIR}/copyparty-data/${APP_NAME}.conf"

INSTALL_STATE_FILE="${STATE_DIR}/install-state.env"
SECRETS_DIR="${STATE_DIR}/secrets"
TAGR_LOGIN_FILE="${SECRETS_DIR}/tagr-login"
TAGR_PASSWORD_FILE="${SECRETS_DIR}/tagr-password"
TAGR_SECRET_FILE="${SECRETS_DIR}/tagr-secret"
CLOUDFLARED_TOKEN_FILE="${SECRETS_DIR}/cloudflare-tunnel-token"

BEETS_VENV="${STACK_DIR}/beets-venv"
BEETS_CONFIG_DIR="${STATE_DIR}/beets"
BEETS_CONFIG_FILE="${BEETS_CONFIG_DIR}/config.yaml"

CADDY_SITE_DIR="/etc/caddy/sites.d"
CADDY_SITE_FILE="${CADDY_SITE_DIR}/${APP_NAME}.caddy"
CADDY_ORIGIN_PORT="8080"
CLOUDFLARED_METRICS_PORT="20241"

CREDENTIALS_FILE="/root/${APP_NAME}-credentials.txt"

AUTO_IMPORT_SCRIPT="/usr/local/bin/${APP_NAME}-auto-import"
DEDUPE_SCRIPT="/usr/local/bin/${APP_NAME}-dedupe"
BEETS_WRAPPER="/usr/local/bin/${APP_NAME}-beet"
BEETS_UPDATE_SCRIPT="/usr/local/bin/${APP_NAME}-beets-update"
BEETS_WATCH_SCRIPT="/usr/local/bin/${APP_NAME}-beets-watch"
UPLOAD_WATCH_SCRIPT="/usr/local/bin/${APP_NAME}-upload-watch"
LEGACY_AUTO_IMPORT_WATCH_SCRIPT="/usr/local/bin/${APP_NAME}-auto-import-watch"

AUTO_IMPORT_SERVICE="${APP_NAME}-auto-import.service"
AUTO_IMPORT_PATH="${APP_NAME}-auto-import.path"
AUTO_IMPORT_TIMER="${APP_NAME}-auto-import.timer"
BEETS_UPDATE_SERVICE="${APP_NAME}-beets-update.service"
BEETS_UPDATE_TIMER="${APP_NAME}-beets-update.timer"
BEETS_WATCH_SERVICE="${APP_NAME}-beets-watch.service"
UPLOAD_WATCH_SERVICE="${APP_NAME}-upload-watch.service"
LEGACY_AUTO_IMPORT_WATCH_SERVICE="${APP_NAME}-auto-import-watch.service"
CLOUDFLARED_SERVICE="${APP_NAME}-cloudflared.service"
DOCKER_STORAGE_DROPIN="/etc/systemd/system/docker.service.d/${APP_NAME}-storage.conf"

# Pinned application versions. Update these constants deliberately after testing.
NAVIDROME_IMAGE="deluan/navidrome:0.63.0"
COPYPARTY_IMAGE="copyparty/ac:1.20.19"
TAGR_GIT_REF="v1.8.6"
BEETS_VERSION="2.4.0"

# Local Tagr build safeguards for small ARM boards and mini PCs.
TAGR_BUILD_TIMEOUT="180m"
TAGR_BUILD_MIN_TOTAL_KIB=$((6 * 1024 * 1024))
TAGR_BUILD_SWAP_FILE="${DATA_DIR}/tagr-build.swap"
TAGR_BUILD_SWAP_CREATED=0
TAGR_BUILD_ZRAM_DEVICE=""

ACTION="install"
REQUESTED_DEPLOY_MODE="${MUSIC_CLOUD_DEPLOY_MODE:-auto}"
DEPLOY_MODE=""
DEPLOY_MODE_SOURCE=""
PUBLIC_ROUTE_OK=0
DNS_MATCH=0
TUNNEL_TOKEN=""
DOCKER_REPO_OS=""
OS_CODENAME=""

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            install)
                ACTION="install"
                ;;
            --diagnose|diagnose)
                ACTION="diagnose"
                ;;
            --uninstall|uninstall)
                ACTION="uninstall"
                ;;
            --repair-import|repair-import)
                ACTION="repair-import"
                ;;
            --mode)
                shift
                (( $# > 0 )) || die "После --mode укажите auto, vps или home."
                REQUESTED_DEPLOY_MODE="$1"
                ;;
            --mode=*)
                REQUESTED_DEPLOY_MODE="${1#*=}"
                ;;
            --vps)
                REQUESTED_DEPLOY_MODE="vps"
                ;;
            --home)
                REQUESTED_DEPLOY_MODE="home"
                ;;
            --auto)
                REQUESTED_DEPLOY_MODE="auto"
                ;;
            --help|-h|help)
                ACTION="help"
                ;;
            *)
                die "Неизвестный аргумент: $1"
                ;;
        esac
        shift
    done

    case "${REQUESTED_DEPLOY_MODE}" in
        auto|vps|home) ;;
        *) die "Режим должен быть auto, vps или home: ${REQUESTED_DEPLOY_MODE}" ;;
    esac
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

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

on_error() {
    local line="$1"
    local code="$2"
    printf '\n\033[1;31mУстановка остановлена: строка %s, код %s.\033[0m\n' \
        "$line" "$code" >&2
}
trap 'on_error "$LINENO" "$?"' ERR

require_root() {
    [[ "${EUID}" -eq 0 ]] || die \
        "Запустите скрипт через sudo: sudo bash $0"
}

set_run_user() {
    local user="$1"

    getent passwd "${user}" >/dev/null ||
        die "Пользователь ${user} не найден."

    RUN_USER="${user}"
    RUN_UID="$(id -u "${RUN_USER}")"
    RUN_GID="$(id -g "${RUN_USER}")"
    RUN_GROUP="$(id -gn "${RUN_USER}")"
    RUN_HOME="$(getent passwd "${RUN_USER}" | cut -d: -f6)"

    [[ -n "${RUN_HOME}" && -d "${RUN_HOME}" ]] ||
        die "Не удалось определить домашний каталог пользователя ${RUN_USER}."

    if [[ "${RUN_USER}" == "root" ]]; then
        warn "Скрипт использует root. Контейнеры и музыкальные файлы будут принадлежать root."
    fi
}

load_install_state() {
    [[ -r "${INSTALL_STATE_FILE}" ]] || return 1

    if find "${INSTALL_STATE_FILE}" -perm /022 -print -quit | grep -q .; then
        die "Файл состояния доступен на запись группе или другим: ${INSTALL_STATE_FILE}"
    fi

    # shellcheck disable=SC1090
    . "${INSTALL_STATE_FILE}"

    case "${STATE_VERSION:-}" in
        3|3.*|4|4.*|5.0-home-cf|5.0.1-home-cf|5.0.2-home-cf|5.1.0-universal|5.1.1-universal)
            ;;
        *)
            die "Неподдерживаемая версия файла состояния ${INSTALL_STATE_FILE}."
            ;;
    esac

    [[ -n "${OWNER_USER:-}" ]] ||
        die "В файле состояния отсутствует OWNER_USER."

    set_run_user "${OWNER_USER}"

    [[ "${RUN_UID}" == "${OWNER_UID:-}" &&
       "${RUN_GID}" == "${OWNER_GID:-}" &&
       "${RUN_HOME}" == "${OWNER_HOME:-}" ]] ||
        die "UID/GID/home владельца изменились после установки. Проверьте ${INSTALL_STATE_FILE}."

    DOMAIN="${INSTALL_DOMAIN:-${DOMAIN:-}}"
    UPLOAD_DIR="${INSTALL_UPLOAD_DIR:-${UPLOAD_DIR:-${DEFAULT_UPLOAD_DIR}}}"
    LIBRARY_DIR="${INSTALL_LIBRARY_DIR:-${LIBRARY_DIR:-${DEFAULT_LIBRARY_DIR}}}"

    if [[ -n "${INSTALL_DEPLOY_MODE:-}" ]]; then
        DEPLOY_MODE="${INSTALL_DEPLOY_MODE}"
        DEPLOY_MODE_SOURCE="state"
    elif [[ -s "${CLOUDFLARED_TOKEN_FILE}" ||
            -f "/etc/systemd/system/${CLOUDFLARED_SERVICE}" ]]; then
        DEPLOY_MODE="home"
        DEPLOY_MODE_SOURCE="legacy-state"
    else
        DEPLOY_MODE="vps"
        DEPLOY_MODE_SOURCE="legacy-state"
    fi

    case "${DEPLOY_MODE}" in
        vps|home) ;;
        *) die "Некорректный INSTALL_DEPLOY_MODE в ${INSTALL_STATE_FILE}: ${DEPLOY_MODE}" ;;
    esac
}

detect_run_user() {
    local requested_user

    if [[ -f "${INSTALL_STATE_FILE}" ]]; then
        load_install_state
        warn "Найдена существующая установка. Используется сохранённый владелец: ${RUN_USER} (${RUN_UID}:${RUN_GID})."
        return
    fi

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        requested_user="${SUDO_USER}"
    elif [[ -n "${DOAS_USER:-}" && "${DOAS_USER}" != "root" ]]; then
        requested_user="${DOAS_USER}"
    else
        requested_user="root"
    fi

    set_run_user "${requested_user}"
}

save_install_state() {
    install -d -m 0755 "${STATE_DIR}"

    (
        umask 077

        {
            printf 'STATE_VERSION=%q\n' "${SCRIPT_VERSION}"
            printf 'OWNER_USER=%q\n' "${RUN_USER}"
            printf 'OWNER_UID=%q\n' "${RUN_UID}"
            printf 'OWNER_GID=%q\n' "${RUN_GID}"
            printf 'OWNER_HOME=%q\n' "${RUN_HOME}"
            printf 'INSTALL_DOMAIN=%q\n' "${DOMAIN}"
            printf 'INSTALL_DEPLOY_MODE=%q\n' "${DEPLOY_MODE}"
            printf 'INSTALL_UPLOAD_DIR=%q\n' "${UPLOAD_DIR}"
            printf 'INSTALL_LIBRARY_DIR=%q\n' "${LIBRARY_DIR}"
            printf 'CADDY_ORIGIN_PORT=%q\n' "${CADDY_ORIGIN_PORT}"
            printf 'NAVIDROME_IMAGE_PIN=%q\n' "${NAVIDROME_IMAGE}"
            printf 'COPYPARTY_IMAGE_PIN=%q\n' "${COPYPARTY_IMAGE}"
            printf 'TAGR_GIT_REF_PIN=%q\n' "${TAGR_GIT_REF}"
            printf 'BEETS_VERSION_PIN=%q\n' "${BEETS_VERSION}"
        } > "${INSTALL_STATE_FILE}"

        chmod 0600 "${INSTALL_STATE_FILE}"
    )
}

run_as_owner() {
    if [[ "${RUN_USER}" == "root" ]]; then
        env \
            HOME="${RUN_HOME}" \
            LANG=en_US.UTF-8 \
            LC_ALL=en_US.UTF-8 \
            PYTHONUTF8=1 \
            PATH=/usr/local/bin:/usr/bin:/bin \
            "$@"
    else
        runuser -u "${RUN_USER}" -- env \
            HOME="${RUN_HOME}" \
            LANG=en_US.UTF-8 \
            LC_ALL=en_US.UTF-8 \
            PYTHONUTF8=1 \
            PATH=/usr/local/bin:/usr/bin:/bin \
            "$@"
    fi
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local answer

    if [[ "${default}" == "y" ]]; then
        read -r -p "${prompt} [Y/n]: " answer
        answer="${answer:-y}"
    else
        read -r -p "${prompt} [y/N]: " answer
        answer="${answer:-n}"
    fi

    [[ "${answer,,}" =~ ^(y|yes|д|да)$ ]]
}

validate_domain() {
    local value="$1"
    [[ "${value}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

ask_domain() {
    local value

    while true; do
        read -r -p "Введите домен без https:// и путей: " value
        value="${value,,}"
        value="${value%.}"

        if validate_domain "${value}"; then
            printf '%s' "${value}"
            return
        fi

        warn "Пример корректного значения: music.example.com"
    done
}

validate_login() {
    local value="$1"
    [[ "${value}" =~ ^[A-Za-z0-9._-]{3,32}$ ]]
}

ask_login() {
    local prompt="$1"
    local default="$2"
    local value

    while true; do
        read -r -p "${prompt} [${default}]: " value
        value="${value:-$default}"

        if validate_login "${value}"; then
            printf '%s' "${value}"
            return
        fi

        warn "Логин: 3–32 символа, буквы, цифры, точка, _ или -."
    done
}

generate_password() {
    # URL-safe alphabet without YAML/config separators.
    openssl rand -base64 24 | tr -d '\n' | tr '/+' '_-'
}

ask_password() {
    local prompt="$1"
    local value

    while true; do
        read -r -s -p "${prompt} (пусто = сгенерировать): " value
        # Эта функция вызывается через подстановку команды. Перевод строки
        # должен идти в stderr, иначе он становится частью пароля.
        printf '\n' >&2

        if [[ -z "${value}" ]]; then
            generate_password
            return
        fi

        if [[ ${#value} -ge 12 ]]; then
            printf '%s' "${value}"
            return
        fi

        warn "Используйте не менее 12 символов."
    done
}

ask_upload_password() {
    local prompt="$1"
    local value

    while true; do
        read -r -s -p "${prompt} (пусто = сгенерировать): " value
        # Эта функция вызывается через подстановку команды. Перевод строки
        # должен идти в stderr, иначе он становится частью пароля.
        printf '\n' >&2

        if [[ -z "${value}" ]]; then
            generate_password
            return
        fi

        if [[ ${#value} -ge 12 && "${value}" =~ ^[A-Za-z0-9._~!@%+=-]+$ ]]; then
            printf '%s' "${value}"
            return
        fi

        warn "Пароль загрузки: минимум 12 символов; разрешены буквы, цифры и . _ ~ ! @ % + = -"
    done
}

validate_storage_path() {
    local value="$1"

    [[ "${value}" == /* ]] || return 1
    [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || return 1
    [[ "${value}" != *'"'* && "${value}" != *':'* && "${value}" != *'\\'* ]] || return 1

    case "${value}" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/lost+found|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
            return 1
            ;;
    esac
}

ask_storage_path() {
    local prompt="$1"
    local default="$2"
    local value

    while true; do
        read -r -e -p "${prompt} [${default}]: " value
        value="${value:-$default}"
        value="$(realpath -m -- "${value}")"

        if validate_storage_path "${value}"; then
            printf '%s' "${value}"
            return
        fi

        warn "Укажите безопасный абсолютный путь. Нельзя выбирать корень или системный каталог целиком; символы :, \\ и \" не поддерживаются."
    done
}

ask_tunnel_token() {
    local value
    local reuse_available=0

    [[ -s "${CLOUDFLARED_TOKEN_FILE}" ]] && reuse_available=1

    while true; do
        if (( reuse_available == 1 )); then
            read -r -s -p "Токен Cloudflare Tunnel (пусто = использовать сохранённый): " value
        else
            read -r -s -p "Токен Cloudflare Tunnel: " value
        fi
        printf '\n' >&2

        if [[ -z "${value}" && ${reuse_available} -eq 1 ]]; then
            value="$(cat "${CLOUDFLARED_TOKEN_FILE}")"
        fi

        if [[ ${#value} -ge 40 && ! "${value}" =~ [[:space:]] ]]; then
            printf '%s' "${value}"
            return
        fi

        warn "Токен пустой, слишком короткий или содержит пробельные символы. Скопируйте только значение после --token."
    done
}

is_private_or_special_ipv4() {
    local a b
    IFS=. read -r a b _ <<<"$1"

    case "${a:-}" in
        0|10|127|169|224|225|226|227|228|229|230|231|232|233|234|235|236|237|238|239|240|241|242|243|244|245|246|247|248|249|250|251|252|253|254|255)
            return 0
            ;;
        100)
            (( ${b:-0} >= 64 && ${b:-0} <= 127 )) && return 0
            ;;
        172)
            (( ${b:-0} >= 16 && ${b:-0} <= 31 )) && return 0
            ;;
        192)
            [[ "${b:-}" == "0" || "${b:-}" == "168" ]] && return 0
            ;;
        198)
            [[ "${b:-}" == "18" || "${b:-}" == "19" || "${b:-}" == "51" ]] && return 0
            ;;
        203)
            [[ "${b:-}" == "0" ]] && return 0
            ;;
    esac

    return 1
}

auto_detect_deployment_mode() {
    local public_ip="" address=""

    if command -v curl >/dev/null 2>&1; then
        public_ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    fi

    if [[ -n "${public_ip}" ]] &&
       ip -o -4 addr show scope global 2>/dev/null |
           awk '{print $4}' | cut -d/ -f1 | grep -Fxq "${public_ip}"; then
        DEPLOY_MODE="vps"
        DEPLOY_MODE_SOURCE="auto-public-ip-on-interface"
        return
    fi

    while read -r address; do
        [[ -n "${address}" ]] || continue
        if ! is_private_or_special_ipv4 "${address}"; then
            DEPLOY_MODE="vps"
            DEPLOY_MODE_SOURCE="auto-public-interface"
            return
        fi
    done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)

    DEPLOY_MODE="home"
    DEPLOY_MODE_SOURCE="auto-nat-or-private-address"
}

ask_explicit_deployment_mode() {
    local answer

    while true; do
        read -r -p "Режим размещения [vps/home]: " answer
        answer="${answer,,}"
        case "${answer}" in
            vps|home)
                DEPLOY_MODE="${answer}"
                DEPLOY_MODE_SOURCE="user"
                return
                ;;
            *) warn "Введите vps или home." ;;
        esac
    done
}

resolve_deployment_mode() {
    if [[ "${REQUESTED_DEPLOY_MODE}" != "auto" ]]; then
        DEPLOY_MODE="${REQUESTED_DEPLOY_MODE}"
        DEPLOY_MODE_SOURCE="argument"
        return
    fi

    if [[ -n "${DEPLOY_MODE}" &&
          ( "${DEPLOY_MODE_SOURCE}" == "state" || "${DEPLOY_MODE_SOURCE}" == "legacy-state" ) ]]; then
        warn "Используется режим существующей установки: ${DEPLOY_MODE}. Для смены передайте --mode vps или --mode home."
        return
    fi

    auto_detect_deployment_mode
    printf '\nАвтоопределение: %s (источник: %s).\n' "${DEPLOY_MODE}" "${DEPLOY_MODE_SOURCE}"

    if [[ -t 0 ]]; then
        if ! ask_yes_no "Использовать режим ${DEPLOY_MODE}?" "y"; then
            ask_explicit_deployment_mode
        fi
    fi
}

is_own_listener() {
    local port="$1"
    local container=""

    case "${port}" in
        80|443)
            [[ "${DEPLOY_MODE}" == "vps" ]] && systemctl is-active --quiet caddy 2>/dev/null
            return
            ;;
        "${CADDY_ORIGIN_PORT}")
            [[ "${DEPLOY_MODE}" == "home" ]] && systemctl is-active --quiet caddy 2>/dev/null
            return
            ;;
        "${CLOUDFLARED_METRICS_PORT}")
            [[ "${DEPLOY_MODE}" == "home" ]] && systemctl is-active --quiet "${CLOUDFLARED_SERVICE}" 2>/dev/null
            return
            ;;
        4533) container="music-cloud-navidrome" ;;
        3923) container="music-cloud-uploads" ;;
        3000) container="music-cloud-tagr" ;;
        *) return 1 ;;
    esac

    command -v docker >/dev/null 2>&1 || return 1
    [[ "$(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null || true)" == "true" ]]
}

check_command_port() {
    local port="$1"
    local label="$2"

    if ! ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; then
        return
    fi

    if is_own_listener "${port}"; then
        ok "Порт ${port} уже используется текущей установкой (${label})."
        return
    fi

    warn "Порт ${port} уже занят (${label})."
    ss -ltnp "sport = :${port}" 2>/dev/null || true
    ask_yes_no "Продолжить, несмотря на занятый порт ${port}?" "n" ||
        die "Освободите порт ${port} и повторите запуск."
}

# ------------------------------------------------------------------------------
# OS / packages
# ------------------------------------------------------------------------------

check_os() {
    local arch like

    [[ -r /etc/os-release ]] || die "/etc/os-release не найден."
    [[ -d /run/systemd/system ]] || die "Требуется Linux с systemd. FriendlyWrt/OpenWrt этим установщиком не поддерживается."

    # shellcheck disable=SC1091
    . /etc/os-release

    arch="$(dpkg --print-architecture 2>/dev/null || true)"
    case "${arch}" in
        amd64|arm64)
            ;;
        *)
            die "Поддерживаются только 64-битные amd64 и arm64. Обнаружена архитектура: ${arch:-неизвестно}."
            ;;
    esac

    case "${ID:-}" in
        ubuntu|debian)
            DOCKER_REPO_OS="${ID}"
            ;;
        *)
            like=" ${ID_LIKE:-} "
            if [[ "${like}" == *" ubuntu "* ]]; then
                DOCKER_REPO_OS="ubuntu"
            elif [[ "${like}" == *" debian "* ]]; then
                DOCKER_REPO_OS="debian"
            else
                die "Поддерживаются Debian/Ubuntu и совместимые производные. Обнаружено: ${PRETTY_NAME:-неизвестно}."
            fi
            warn "Обнаружен производный дистрибутив ${PRETTY_NAME:-${ID:-неизвестно}}. Репозиторий Docker будет выбран как ${DOCKER_REPO_OS}."
            ask_yes_no "Продолжить на производном дистрибутиве?" "n" || die "Операция отменена."
            ;;
    esac

    OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    [[ -n "${OS_CODENAME}" ]] || die "Не удалось определить VERSION_CODENAME для репозитория Docker."

    case "${DOCKER_REPO_OS}:${VERSION_ID:-}" in
        ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|debian:11|debian:12|debian:13)
            ;;
        *)
            warn "Версия ${PRETTY_NAME:-неизвестно} не входит в проверенный список установщика."
            ask_yes_no "Продолжить на неподтверждённой версии?" "n" || die "Операция отменена."
            ;;
    esac

    ok "ОС: ${PRETTY_NAME:-${ID}}; архитектура: ${arch}; Docker repo: ${DOCKER_REPO_OS}/${OS_CODENAME}."
}

install_base_packages() {
    log "Установка базовых пакетов"

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y \
        ca-certificates \
        curl \
        git \
        gnupg \
        openssl \
        locales \
        python3 \
        python3-venv \
        python3-pip \
        ffmpeg \
        libchromaprint-tools \
        libimage-exiftool-perl \
        util-linux \
        iproute2 \
        inotify-tools \
        jq

    locale-gen en_US.UTF-8 >/dev/null
}

remove_conflicting_docker_packages() {
    local package
    local -a conflicts=()

    for package in \
        docker.io \
        docker-compose \
        docker-compose-v2 \
        docker-doc \
        podman-docker \
        containerd \
        runc; do
        if dpkg-query -W -f='${db:Status-Abbrev}' "${package}" 2>/dev/null |
           grep -q '^ii '; then
            conflicts+=("${package}")
        fi
    done

    if (( ${#conflicts[@]} == 0 )); then
        return
    fi

    warn "Обнаружены пакеты, конфликтующие с официальным Docker Engine: ${conflicts[*]}"
    ask_yes_no "Удалить конфликтующие пакеты и продолжить?" "y" ||
        die "Установка Docker отменена."

    apt-get remove -y "${conflicts[@]}"
}

install_docker_home() {
    local docker_data_root="${DATA_DIR}/docker-data"
    local docker_tmp_root="${DATA_DIR}/docker-tmp"
    local backing_fs docker_driver expected_driver docker_root

    log "Установка Docker Engine (домашний режим, управляемое хранилище)"

    remove_conflicting_docker_packages
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${DOCKER_REPO_OS}/gpg" \
        -o /etc/apt/keyrings/docker.asc
    chmod 0644 /etc/apt/keyrings/docker.asc

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${DOCKER_REPO_OS}
Suites: ${OS_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    rm -f /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl stop docker.service docker.socket containerd.service 2>/dev/null || true
    install -d -m 0755 "${DATA_DIR}" "${docker_data_root}" "${docker_tmp_root}" \
        /etc/docker /etc/containerd /etc/systemd/system/docker.service.d

    backing_fs="$(findmnt -no FSTYPE --target "${DATA_DIR}" 2>/dev/null || true)"
    case "${backing_fs}" in
        ext4|xfs) expected_driver="overlay2" ;;
        *)
            expected_driver="vfs"
            warn "Файловая система ${backing_fs:-неизвестна} не поддерживает overlay2; используется vfs."
            ;;
    esac

    python3 - /etc/docker/daemon.json "${docker_data_root}" "${expected_driver}" <<'PYDOCKER'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
data_root = sys.argv[2]
storage_driver = sys.argv[3]
config = {}
if path.exists() and path.stat().st_size:
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise SystemExit(f"Некорректный {path}: {exc}")
if not isinstance(config, dict):
    raise SystemExit(f"{path} должен содержать JSON-объект")
features = config.get("features")
if not isinstance(features, dict):
    features = {}
features["containerd-snapshotter"] = False
config["features"] = features
config["data-root"] = data_root
config["storage-driver"] = storage_driver
tmp = path.with_name(path.name + ".tmp")
tmp.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
tmp.chmod(0o644)
tmp.replace(path)
PYDOCKER

    containerd config default > /etc/containerd/config.toml
    chmod 0644 /etc/containerd/config.toml
    rm -f "/etc/systemd/system/containerd.service.d/${APP_NAME}-storage.conf"

    cat > "/etc/systemd/system/docker.service.d/${APP_NAME}-backend.conf" <<EOF
[Unit]
RequiresMountsFor=${DATA_DIR}

[Service]
Environment="DOCKER_TMPDIR=${docker_tmp_root}"
EOF

    rm -f /run/containerd/containerd.sock /run/containerd/containerd.sock.ttrpc
    systemctl daemon-reload
    systemctl enable containerd docker
    systemctl start containerd
    systemctl is-active --quiet containerd || {
        journalctl -u containerd --no-pager -n 100 >&2 || true
        die "Служба containerd не запустилась."
    }
    systemctl start docker
    systemctl is-active --quiet docker || {
        journalctl -u docker --no-pager -n 100 >&2 || true
        die "Служба Docker не запустилась."
    }

    docker_driver="$(docker info --format '{{.Driver}}')"
    docker_root="$(docker info --format '{{.DockerRootDir}}')"
    [[ "$(realpath -m "${docker_root}")" == "$(realpath -m "${docker_data_root}")" ]] ||
        die "Docker использует ${docker_root}, ожидался ${docker_data_root}."
    [[ "${docker_driver}" == "${expected_driver}" ]] ||
        die "Docker использует ${docker_driver}, ожидался ${expected_driver}."
    ok "Docker: data-root=${docker_root}, driver=${docker_driver}, fs=${backing_fs}."
    docker version >/dev/null
    docker compose version >/dev/null
}

install_docker_vps() {
    log "Установка Docker Engine (VPS, стандартное хранилище Docker)"

    remove_conflicting_docker_packages
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${DOCKER_REPO_OS}/gpg" \
        -o /etc/apt/keyrings/docker.asc
    chmod 0644 /etc/apt/keyrings/docker.asc

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${DOCKER_REPO_OS}
Suites: ${OS_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    rm -f /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl daemon-reload
    systemctl enable --now containerd docker
    docker version >/dev/null
    docker compose version >/dev/null
}

install_docker() {
    if [[ "${DEPLOY_MODE}" == "home" ]]; then
        install_docker_home
    else
        install_docker_vps
    fi
}

install_caddy() {
    log "Установка Caddy"

    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key |
        gpg --dearmor --yes \
            -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
        -o /etc/apt/sources.list.d/caddy-stable.list

    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    chmod o+r /etc/apt/sources.list.d/caddy-stable.list

    apt-get update
    apt-get install -y caddy
}

install_cloudflared() {
    log "Установка cloudflared"

    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        -o /usr/share/keyrings/cloudflare-main.gpg
    chmod 0644 /usr/share/keyrings/cloudflare-main.gpg

    cat > /etc/apt/sources.list.d/cloudflared.list <<'EOF'
deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main
EOF

    apt-get update
    apt-get install -y cloudflared

    cloudflared --version
    cloudflared tunnel run --help 2>&1 | grep -q -- '--token-file' ||
        die "Установленная версия cloudflared не поддерживает --token-file (требуется 2025.4.0 или новее)."
}

# ------------------------------------------------------------------------------
# Interactive settings
# ------------------------------------------------------------------------------

show_intro() {
    cat <<EOF

Установщик создаст музыкальную систему на одном домене:

  https://ДОМЕН/          Navidrome
  https://ДОМЕН/uploads/  загрузка музыки
  https://ДОМЕН/tags/     редактирование тегов и обложек

Выбран режим: ${DEPLOY_MODE}
EOF

    if [[ "${DEPLOY_MODE}" == "vps" ]]; then
        cat <<'EOF'

VPS-режим:
  • DNS A-запись должна указывать на публичный IPv4 сервера;
  • входящие TCP 80 и 443 должны быть доступны;
  • Caddy самостоятельно получает и обновляет TLS-сертификат.
EOF
    else
        cat <<EOF

Домашний режим / CGNAT:
  • домен должен использовать DNS Cloudflare;
  • создайте Cloudflare Tunnel и Published application;
  • hostname должен вести на http://127.0.0.1:${CADDY_ORIGIN_PORT};
  • проброс портов, публичный IPv4 и входящие 80/443 не требуются.
EOF
    fi

    cat <<EOF

Поддерживаются Debian/Ubuntu с systemd на amd64 или arm64.
Tagr собирается локально и требует суммарно около 4–6 ГиБ RAM+swap.
EOF
}

collect_settings() {
    local library_default

    printf '\n'
    DOMAIN="$(ask_domain)"

    library_default="${LIBRARY_DIR:-${DEFAULT_LIBRARY_DIR}}"
    printf '\nХранилище музыки:\n'
    printf 'Можно выбрать системный диск, USB-накопитель или уже смонтированное сетевое хранилище.\n'
    LIBRARY_DIR="$(ask_storage_path "Путь к музыкальной библиотеке" "${library_default}")"

    if [[ "${DEPLOY_MODE}" == "home" ]]; then
        printf '\nCloudflare Tunnel:\n'
        printf 'В Cloudflare маршрут hostname должен вести на http://127.0.0.1:%s\n' "${CADDY_ORIGIN_PORT}"
        TUNNEL_TOKEN="$(ask_tunnel_token)"
    fi

    printf '\nДоступ к загрузке Copyparty:\n'
    printf 'Веб-форма Copyparty запрашивает имя пользователя и пароль.\n'
    UPLOAD_LOGIN="$(ask_login "Имя учётной записи" "music")"
    UPLOAD_PASSWORD="$(ask_upload_password "Пароль")"

    printf '\nДоступ к редактору тегов Tagr:\n'
    TAGR_LOGIN="$(ask_login "Логин" "admin")"
    TAGR_PASSWORD="$(ask_password "Пароль")"
    TAGR_SECRET="$(openssl rand -hex 32)"

    cat <<EOF

Параметры установки:

  Режим:                ${DEPLOY_MODE}
  Системный пользователь:${RUN_USER}
  UID:GID:               ${RUN_UID}:${RUN_GID}
  Домашний каталог:      ${RUN_HOME}
  Публичный адрес:       https://${DOMAIN}/
  Каталог загрузки:      ${UPLOAD_DIR}
  Музыкальная библиотека:${LIBRARY_DIR}
  Конфигурация:          ${STACK_DIR}
EOF

    if [[ "${DEPLOY_MODE}" == "home" ]]; then
        printf '  Origin Cloudflare:     http://127.0.0.1:%s\n' "${CADDY_ORIGIN_PORT}"
        printf '  Токен Tunnel:          получен (не выводится)\n'
    else
        printf '  Входящие порты:        TCP 80 и 443\n'
    fi
    printf '\n'

    if [[ -f "${COMPOSE_FILE}" ]]; then
        warn "Найдена существующая установка ${COMPOSE_FILE}."
        ask_yes_no "Обновить/перезаписать конфигурацию?" "n" || die "Операция отменена."
    fi

    ask_yes_no "Начать установку?" "y" || die "Операция отменена."
}

# ------------------------------------------------------------------------------
# Network preflight

# ------------------------------------------------------------------------------
# Network preflight

# ------------------------------------------------------------------------------
# DNS
# ------------------------------------------------------------------------------

check_outbound_network() {
    log "Проверка исходящего доступа в интернет"

    curl -fsS --max-time 15 https://api.cloudflare.com/client/v4/ips >/dev/null ||
        die "Нет доступа к API Cloudflare по HTTPS. Проверьте DNS, шлюз и исходящий TCP/443."

    getent ahosts region1.v2.argotunnel.com >/dev/null 2>&1 ||
        warn "Не удалось заранее разрешить адрес Cloudflare Tunnel. cloudflared повторит попытку после установки."

    ok "Исходящий HTTPS доступен. Входящие порты не требуются."
}

check_dns() {
    log "Проверка DNS для VPS"

    local public_ip domain_ip
    public_ip="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
    domain_ip="$(getent ahostsv4 "${DOMAIN}" | awk 'NR==1 {print $1}' || true)"

    printf 'Публичный IPv4 сервера: %s\n' "${public_ip:-не определён}"
    printf '%s → %s\n' "${DOMAIN}" "${domain_ip:-не найден}"

    if [[ -n "${public_ip}" && "${public_ip}" == "${domain_ip}" ]]; then
        DNS_MATCH=1
        ok "DNS указывает на VPS."
        return
    fi

    DNS_MATCH=0
    warn "DNS пока не указывает на публичный IPv4 этого VPS."
    warn "Caddy сможет получить сертификат только после корректного обновления DNS."
    ask_yes_no "Продолжить установку?" "y" || die "Исправьте DNS и повторите запуск."
}

check_network_preflight() {
    if [[ "${DEPLOY_MODE}" == "home" ]]; then
        check_outbound_network
    else
        check_dns
    fi
}

# ------------------------------------------------------------------------------
# Directories and ownership

# ------------------------------------------------------------------------------
# Directories and ownership

# ------------------------------------------------------------------------------
# Directories and ownership
# ------------------------------------------------------------------------------

prepare_library_directory() {
    local first_bad="" mount_target="" fs_type=""

    if [[ ! -e "${LIBRARY_DIR}" ]]; then
        if [[ "${LIBRARY_DIR}" == /mnt/* || "${LIBRARY_DIR}" == /media/* ]]; then
            warn "Путь ${LIBRARY_DIR} отсутствует. Если это внешний диск, сначала настройте его постоянное монтирование."
            ask_yes_no "Создать каталог на текущей файловой системе?" "n" ||
                die "Подключите хранилище и повторите запуск."
        fi
        install -d -m 0755 -o "${RUN_USER}" -g "${RUN_GROUP}" "${LIBRARY_DIR}"
    fi

    [[ -d "${LIBRARY_DIR}" ]] || die "Музыкальная библиотека не является каталогом: ${LIBRARY_DIR}"

    mount_target="$(findmnt -no TARGET --target "${LIBRARY_DIR}" 2>/dev/null || true)"
    fs_type="$(findmnt -no FSTYPE --target "${LIBRARY_DIR}" 2>/dev/null || true)"
    printf 'Хранилище библиотеки: mount=%s, fs=%s\n' \
        "${mount_target:-не определено}" "${fs_type:-не определено}"

    if [[ ( "${LIBRARY_DIR}" == /mnt/* || "${LIBRARY_DIR}" == /media/* ) &&
          ( -z "${mount_target}" || "${mount_target}" == "/" ) ]]; then
        warn "Выбран путь под /mnt или /media, но отдельное монтирование не обнаружено. Музыка может попасть на системный диск."
        ask_yes_no "Продолжить с этим путём?" "n" || die "Настройте монтирование и повторите запуск."
    fi

    first_bad="$(run_as_owner find "${LIBRARY_DIR}" -xdev \
        \( -type d ! -readable -o -type d ! -writable -o -type d ! -executable -o -type f ! -readable -o -type f ! -writable \) \
        -print -quit 2>/dev/null || true)"

    if [[ -n "${first_bad}" ]]; then
        warn "Пользователь ${RUN_USER} не имеет необходимых прав как минимум на: ${first_bad}"
        if ask_yes_no "Рекурсивно назначить владельца ${RUN_USER}:${RUN_GROUP} для всей библиотеки?" "n"; then
            find "${LIBRARY_DIR}" -xdev -exec chown "${RUN_UID}:${RUN_GID}" -- {} +
            find "${LIBRARY_DIR}" -xdev -exec chmod u+rwX -- {} +
        else
            die "Для Tagr и beets библиотека должна быть доступна пользователю ${RUN_USER} на чтение и запись."
        fi
    fi

    run_as_owner sh -c 'set -eu; test -r "$1"; test -w "$1"; test -x "$1"' sh "${LIBRARY_DIR}" ||
        die "Нет доступа к выбранной музыкальной библиотеке: ${LIBRARY_DIR}"
}

configure_storage_boot_dependency() {
    local mount_target

    mount_target="$(findmnt -no TARGET --target "${LIBRARY_DIR}" 2>/dev/null || true)"
    if [[ -z "${mount_target}" || "${mount_target}" == "/" ]]; then
        rm -f "${DOCKER_STORAGE_DROPIN}"
        systemctl daemon-reload
        return
    fi

    install -d -m 0755 "$(dirname "${DOCKER_STORAGE_DROPIN}")"
    cat > "${DOCKER_STORAGE_DROPIN}" <<EOF
[Unit]
RequiresMountsFor=${LIBRARY_DIR}
EOF
    chmod 0644 "${DOCKER_STORAGE_DROPIN}"
    systemctl daemon-reload
    ok "Docker будет запускаться после монтирования ${LIBRARY_DIR}."
}

create_directories() {
    log "Создание каталогов"

    install -d -m 0755 \
        "${DATA_DIR}" \
        "${UPLOAD_DIR}" \
        "${STACK_DIR}" \
        "${STACK_DIR}/navidrome-data" \
        "${STACK_DIR}/copyparty-data" \
        "${STACK_DIR}/tagr-data" \
        "${STATE_DIR}" \
        "${CADDY_SITE_DIR}"

    install -d -m 0700 "${SECRETS_DIR}"

    chown -R "${RUN_UID}:${RUN_GID}" \
        "${UPLOAD_DIR}" \
        "${STACK_DIR}/navidrome-data" \
        "${STACK_DIR}/copyparty-data" \
        "${STACK_DIR}/tagr-data"

    chmod 0755 "${UPLOAD_DIR}"
    prepare_library_directory
    configure_storage_boot_dependency
}

# ------------------------------------------------------------------------------
# beets
# ------------------------------------------------------------------------------

install_beets() {
    log "Установка beets, MusicBrainz и Chroma/AcoustID"

    install -d -m 0700 -o "${RUN_USER}" -g "${RUN_GROUP}" \
        "${BEETS_VENV}" \
        "${BEETS_CONFIG_DIR}"

    if [[ ! -x "${BEETS_VENV}/bin/python" ]]; then
        run_as_owner python3 -m venv "${BEETS_VENV}"
    fi

    run_as_owner "${BEETS_VENV}/bin/pip" install --upgrade pip wheel
    # lastgenre входит в beets, но его зависимость pylast является optional.
    # Устанавливаем официальный extra, чтобы плагин был действительно работоспособен.
    run_as_owner "${BEETS_VENV}/bin/pip" install --upgrade \
        "beets[lastgenre]==${BEETS_VERSION}" \
        requests \
        pyacoustid \
        Pillow

    # beets 2.4.0 использует слишком короткий буфер fcntl.ioctl() для
    # определения ширины терминала. Python 3.14 обнаруживает переполнение и
    # завершает импорт beets с SystemError: buffer overflow. Применяем точечный
    # backport upstream-исправления через shutil.get_terminal_size(), сохраняя
    # beets 2.4.0 для совместимости с Debian 11 / Python 3.9.
    # Патч идемпотентен и выполняется до первого импорта beets.ui.
    run_as_owner "${BEETS_VENV}/bin/python" - <<'PYBEETSTERM'
from pathlib import Path
import importlib.util

spec = importlib.util.find_spec("beets")
if spec is None or not spec.submodule_search_locations:
    raise SystemExit("Не удалось найти установленный пакет beets")

ui_path = Path(next(iter(spec.submodule_search_locations))) / "ui" / "__init__.py"
text = ui_path.read_text(encoding="utf-8")

old_function = "".join([
    'def term_width():\n',
    '    """Get the width (columns) of the terminal."""\n',
    '    fallback = config["ui"]["terminal_width"].get(int)\n',
    '\n',
    '    # The fcntl and termios modules are not available on non-Unix\n',
    '    # platforms, so we fall back to a constant.\n',
    '    try:\n',
    '        import fcntl\n',
    '        import termios\n',
    '    except ImportError:\n',
    '        return fallback\n',
    '\n',
    '    try:\n',
    '        buf = fcntl.ioctl(0, termios.TIOCGWINSZ, " " * 4)\n',
    '    except OSError:\n',
    '        return fallback\n',
    '\n',
    '    try:\n',
    '        height, width = struct.unpack("hh", buf)\n',
    '    except struct.error:\n',
    '        return fallback\n',
    '    return width\n',
])

new_function = "".join([
    'def term_width():\n',
    '    """Get the width (columns) of the terminal."""\n',
    '    columns, _ = shutil.get_terminal_size(fallback=(0, 0))\n',
    '    return columns if columns else config["ui"]["terminal_width"].get(int)\n',
])

if "shutil.get_terminal_size(fallback=(0, 0))" in text:
    print("beets terminal-width patch already applied")
    raise SystemExit(0)

if old_function not in text:
    raise SystemExit(
        f"Не удалось применить Python 3.14 patch к {ui_path}: "
        "структура beets.ui отличается от ожидаемой"
    )

if "import shutil\n" not in text:
    marker = "import re\n"
    if marker not in text:
        raise SystemExit(f"Не удалось добавить import shutil в {ui_path}")
    text = text.replace(marker, marker + "import shutil\n", 1)

ui_path.write_text(text.replace(old_function, new_function, 1), encoding="utf-8")
print(f"beets Python 3.14 terminal-width patch applied: {ui_path}")
PYBEETSTERM

    cat > "${BEETS_CONFIG_FILE}" <<EOF
directory: ${LIBRARY_DIR}
library: ${BEETS_CONFIG_DIR}/library.db

plugins:
  - musicbrainz
  - chroma
  - fromfilename
  - fetchart
  - embedart
  - lastgenre
  - duplicates
  - missing
  - info
  - mbsync

import:
  write: true
  move: true
  copy: false
  resume: false
  incremental: false
  timid: false
  quiet: true
  quiet_fallback: asis
  # Новая копия импортируется, затем обработчик оставляет её и удаляет
  # старую запись/файл по точному ключу трека.
  duplicate_action: keep
  log: ${BEETS_CONFIG_DIR}/import.log

match:
  strong_rec_thresh: 0.04

paths:
  default: \$albumartist/\$album%aunique{}/\$disc-\$track \$title
  singleton: Singles/\$artist/\$title
  comp: Compilations/\$album%aunique{}/\$disc-\$track \$title

fromfilename:
  auto: true

chroma:
  auto: true

fetchart:
  auto: true
  cautious: true
  minwidth: 500
  cover_names:
    - cover
    - folder
    - front
  sources:
    - filesystem
    - coverart
    - itunes

embedart:
  auto: true

lastgenre:
  auto: true
  source: album
  count: 3
  canonical: true
  fallback: ""

replace:
  '[\\\\/]': _
  '^\\.': _
  '[\\x00-\\x1f]': _
  '[<>:"?*|]': _
  '\\.$': _
  '\\s+$': ""

ui:
  color: true
EOF

    touch \
        "${BEETS_CONFIG_DIR}/import.log" \
        "${BEETS_CONFIG_DIR}/auto-import.log" \
        "${BEETS_CONFIG_DIR}/update.log"

    chown -R "${RUN_UID}:${RUN_GID}" \
        "${BEETS_CONFIG_DIR}" \
        "${BEETS_VENV}"

    cat > "${BEETS_WRAPPER}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
export HOME="${RUN_HOME}"
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export PYTHONUTF8=1
export BEETSDIR="${BEETS_CONFIG_DIR}"
exec "${BEETS_VENV}/bin/beet" -c "${BEETS_CONFIG_FILE}" "\$@"
EOF
    chmod 0755 "${BEETS_WRAPPER}"

    run_as_owner fpcalc -version >/dev/null

    # Проверяем обязательные Python-зависимости отдельно. Команда beet version
    # в некоторых версиях beets печатает ошибку загрузки плагина, но всё равно
    # завершается с кодом 0, поэтому одного set -e здесь недостаточно.
    run_as_owner "${BEETS_VENV}/bin/python" - <<'PYBEETSDEPS'
import tempfile

import acoustid
import pylast
from PIL import Image
from beets.util.artresizer import ArtResizer

# fetchart с minwidth и embedart требуют локальный backend обработки
# изображений. Без Pillow импорт падает уже после распознавания альбома и не
# успевает переместить треки из upload в библиотеку.
with tempfile.NamedTemporaryFile(suffix=".png") as image_file:
    Image.new("RGB", (2, 3)).save(image_file.name)
    size = ArtResizer.shared.get_size(image_file.name)
    if size != (2, 3):
        raise SystemExit(f"ArtResizer backend не работает: получен размер {size!r}")

print("pyacoustid OK")
print("pylast OK")
print("Pillow/ArtResizer OK")
PYBEETSDEPS

    local beets_check_output
    if ! beets_check_output="$(run_as_owner "${BEETS_WRAPPER}" version 2>&1)"; then
        printf '%s\n' "${beets_check_output}" >&2
        die "Проверка beets завершилась с ошибкой."
    fi

    if grep -Eiq \
        'error loading plugin|PluginImportError|ModuleNotFoundError|ImportError' \
        <<<"${beets_check_output}"; then
        printf '%s\n' "${beets_check_output}" >&2
        die "Один или несколько плагинов beets не загрузились."
    fi

    printf '%s\n' "${beets_check_output}"
}

# ------------------------------------------------------------------------------
# Tagr: build with Next.js basePath=/tags
# ------------------------------------------------------------------------------

prepare_tagr_source() {
    log "Подготовка Tagr для полноценной работы по пути /tags"

    rm -rf "${TAGR_SOURCE_DIR}"

    git clone --depth 1 --branch "${TAGR_GIT_REF}" \
        https://github.com/suitux/Tagr.git \
        "${TAGR_SOURCE_DIR}"

    [[ "$(git -C "${TAGR_SOURCE_DIR}" describe --tags --exact-match 2>/dev/null || true)" == "${TAGR_GIT_REF}" ]] ||
        die "Не удалось получить закреплённую версию Tagr ${TAGR_GIT_REF}."

    # Одного next.config basePath недостаточно: Tagr v1.8.6 содержит абсолютные
    # пути в Auth.js, proxy, SessionProvider, PWA и изображениях. Патчим весь
    # связанный набор атомарно и завершаем установку, если структура исходников
    # неожиданно изменилась.
    python3 - "${TAGR_SOURCE_DIR}" <<'PYTAGRPATCH'
from pathlib import Path
import sys

root = Path(sys.argv[1])


def read(rel: str) -> tuple[Path, str]:
    path = root / rel
    if not path.is_file():
        raise SystemExit(f"Не найден обязательный файл Tagr: {rel}")
    return path, path.read_text(encoding="utf-8")


def replace_once(rel: str, old: str, new: str) -> None:
    path, text = read(rel)
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"Ожидалось одно совпадение в {rel}, найдено {count}: {old!r}"
        )
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


# Next.js 16 использует Turbopack для production build по умолчанию. На
# маломощном устройстве этот этап может надолго остановиться на сообщении
# "Creating an optimized production build". Для воспроизводимой серверной
# сборки используем поддерживаемый Next.js режим Webpack.
replace_once(
    "package.json",
    '"build": "next build"',
    '"build": "next build --webpack"',
)

# Ограничиваем heap сборщика. При недостатке физической RAM установщик ниже
# временно добавит swap, поэтому Node завершится с диагностикой, а не отправит
# всё устройство в бесконечный memory-thrashing.
replace_once(
    "Dockerfile",
    "ENV NEXT_TELEMETRY_DISABLED=1\n\nARG APP_VERSION=0.0.0",
    "ENV NEXT_TELEMETRY_DISABLED=1\nENV NODE_OPTIONS=\"--max-old-space-size=1536\"\n\nARG APP_VERSION=0.0.0",
)

# Next.js standalone output tracing не видит динамический require внутри
# libsql и поэтому может не перенести optional platform package в runner.
# Копируем фактически установленный musl-пакет из builder через BuildKit mount.
# Поиск по имени, а не по версии/архитектуре, сохраняет поддержку amd64, arm64
# и armv7 без загрузки второго экземпляра пакета из npm.
replace_once(
    "Dockerfile",
    """COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static

# Prisma: copy schema + config, install CLI for db push & studio at runtime""",
    """COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
# libsql loads its native binding with a dynamic require. Next.js standalone
# tracing can omit that optional platform package, so copy the package that
# pnpm actually installed for this Alpine build from the builder stage.
RUN --mount=type=bind,from=builder,source=/app/node_modules,target=/mnt/builder-node-modules,ro set -eux; native_src="$(find /mnt/builder-node-modules/.pnpm -type d -path '*/node_modules/@libsql/linux-*musl*' | head -n 1)"; test -n "${native_src}"; native_name="$(basename "${native_src}")"; mkdir -p /app/node_modules/@libsql; cp -a "${native_src}" "/app/node_modules/@libsql/${native_name}"; libsql_entry="$(find /app/node_modules -type f -path '*/libsql/index.js' | head -n 1)"; test -n "${libsql_entry}"; node -e "require(process.argv[1]); console.log('libsql native runtime OK')" "${libsql_entry}"

# Prisma: copy schema + config, install CLI for db push & studio at runtime""",
)

# Next.js: маршруты и клиентские чанки публикуются под /tags.
# Caddy уже канонизирует /tags -> /tags/. Запрещаем Next.js выполнять обратную
# нормализацию /tags/ -> /tags до запуска proxy, иначе возникает конфликт
# редиректов и корневой маршрут Tagr обходит проверку авторизации.
path, text = read("next.config.ts")
if 'basePath: "/tags"' not in text and "basePath: '/tags'" not in text:
    needle = "const nextConfig: NextConfig = {"
    if text.count(needle) != 1:
        raise SystemExit("Структура next.config.ts изменилась")
    text = text.replace(needle, needle + '\n  experimental: { webpackMemoryOptimizations: true },\n  basePath: "/tags",', 1)

if "skipTrailingSlashRedirect:" not in text:
    if 'basePath: "/tags",' in text:
        text = text.replace(
            'basePath: "/tags",',
            'basePath: "/tags",\n  skipTrailingSlashRedirect: true,',
            1,
        )
    elif "basePath: '/tags'," in text:
        text = text.replace(
            "basePath: '/tags',",
            "basePath: '/tags',\n  skipTrailingSlashRedirect: true,",
            1,
        )
    else:
        raise SystemExit(
            "Не удалось добавить skipTrailingSlashRedirect рядом с basePath"
        )

path.write_text(text, encoding="utf-8")

# Next.js удаляет свой basePath перед передачей URL route handler-у.
# Поэтому внешний /tags/api/auth/providers внутри Auth.js выглядит как
# /api/auth/providers. Серверный basePath Auth.js обязан оставаться стандартным
# /api/auth; иначе Auth.js завершает запрос с UnknownAction. Внешний префикс
# задаётся только клиентскому SessionProvider.
replace_once("src/auth.ts", "signIn: '/login'", "signIn: '/tags/login'")
replace_once(
    "src/app/layout.tsx",
    "<SessionProvider>",
    "<SessionProvider basePath='/tags/api/auth'>",
)

# Общий Axios-клиент Tagr использует абсолютный baseURL=/api. За Caddy этот
# путь попадает в Navidrome на корне домена и все клиентские операции Tagr
# (включая POST /scan/start) получают HTTP 404. Публикуем API под тем же
# внешним basePath, что и приложение.
replace_once(
    "src/lib/axios.ts",
    "baseURL: '/api',",
    "baseURL: '/tags/api',",
)

# MusicBrainz cover hooks bypass the shared Axios instance and use absolute
# /api URLs directly. Under /tags these requests go to Navidrome and return
# HTTP 404. Route both single-track and bulk cover operations through the
# external /tags/api prefix.
replace_once(
    "src/features/musicbrainz/hooks/use-fetch-musicbrainz-cover.ts",
    "import axios from 'axios'",
    "import { api } from '@/lib/axios'",
)
replace_once(
    "src/features/musicbrainz/hooks/use-fetch-musicbrainz-cover.ts",
    "axios.post<FetchCoverResult>(`/api/songs/${songId}/musicbrainz/fetch-cover`,",
    "api.post<FetchCoverResult>(`/songs/${songId}/musicbrainz/fetch-cover`,",
)
replace_once(
    "src/features/musicbrainz/hooks/use-bulk-fetch-musicbrainz-cover.ts",
    "fetch('/api/songs/bulk/musicbrainz/fetch-cover',",
    "fetch('/tags/api/songs/bulk/musicbrainz/fetch-cover',",
)

# Авторизация корневого маршрута выполняется только в proxy.ts. Не добавляем
# второй redirect() в server component: два независимых механизма редиректа
# усложняют обработку basePath и могут создавать повторный префикс /tags.

# Next/Image не добавляет basePath к статическим src автоматически.
for old, new in (
    ("{ url: '/icons/icon-192x192.png'", "{ url: '/tags/icons/icon-192x192.png'"),
    ("{ url: '/icons/icon-512x512.png'", "{ url: '/tags/icons/icon-512x512.png'"),
    ("{ url: '/icons/apple-touch-icon.png'", "{ url: '/tags/icons/apple-touch-icon.png'"),
):
    replace_once("src/app/layout.tsx", old, new)
replace_once(
    "src/app/login/page.tsx",
    "src='/icons/tagr-logo.webp'",
    "src='/tags/icons/tagr-logo.webp'",
)

# Proxy исходного Tagr сравнивает pathname только с /login и редиректит на
# корень домена. При basePath это образует /tags -> /login -> Navidrome либо
# бесконечный цикл. Новый proxy понимает и внешний, и уже нормализованный путь.
proxy_path = root / "src/proxy.ts"
if not proxy_path.is_file():
    raise SystemExit("Не найден обязательный файл Tagr: src/proxy.ts")
proxy_path.write_text("""import { NextResponse } from 'next/server'
import type { NextRequest } from 'next/server'
import { auth } from '@/auth'

const BASE_PATH = '/tags'

function withoutBasePath(pathname: string): string {
  if (pathname === BASE_PATH || pathname === `${BASE_PATH}/`) return '/'
  if (pathname.startsWith(`${BASE_PATH}/`)) return pathname.slice(BASE_PATH.length)
  return pathname
}

function externalUrl(request: NextRequest, pathname: string): URL {
  // Используем обычный URL, а не request.nextUrl.clone(). У NextURL уже есть
  // basePath=/tags; если дополнительно записать /tags в pathname, Next.js
  // сериализует адрес как /tags/tags/....
  const url = new URL(request.url)
  url.pathname = pathname === '/' ? `${BASE_PATH}/` : `${BASE_PATH}${pathname}`
  url.search = ''
  return url
}

export async function proxy(request: NextRequest) {
  const pathname = withoutBasePath(request.nextUrl.pathname)
  const isOnLoginPage = pathname === '/login' || pathname === '/login/'
  const isAuthRoute = pathname.startsWith('/api/auth')
  const isShareRoute = pathname.startsWith('/share/')
    || pathname.startsWith('/api/share/')

  if (isAuthRoute || isShareRoute) {
    return NextResponse.next()
  }

  const session = await auth()
  const isLoggedIn = !!session

  if (isOnLoginPage && isLoggedIn) {
    return NextResponse.redirect(externalUrl(request, '/'))
  }

  if (!isOnLoginPage && !isLoggedIn) {
    return NextResponse.redirect(externalUrl(request, '/login'))
  }

  return NextResponse.next()
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|sw\\.js|manifest\\.webmanifest|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)']
}
""", encoding="utf-8")

# PWA-ресурсы также должны оставаться внутри /tags, иначе они попадают в
# Navidrome на корне домена.
replace_once(
    "src/components/pwa/service-worker-register.tsx",
    "navigator.serviceWorker.register('/sw.js')",
    "navigator.serviceWorker.register('/tags/sw.js', { scope: '/tags/' })",
)

sw_path, sw_text = read("public/sw.js")
sw_text = sw_text.replace("'/icons/icon-192x192.png'", "'/tags/icons/icon-192x192.png'")
sw_text = sw_text.replace("'/icons/icon-512x512.png'", "'/tags/icons/icon-512x512.png'")
sw_text = sw_text.replace("event.request.url.includes('/_next/static/')", "event.request.url.includes('/tags/_next/static/')")
sw_path.write_text(sw_text, encoding="utf-8")

manifest_path, manifest = read("src/app/manifest.ts")
replacements = {
    "start_url: '/'": "start_url: '/tags/'",
    "src: '/screenshots/desktop.png'": "src: '/tags/screenshots/desktop.png'",
    "src: '/screenshots/mobile.png'": "src: '/tags/screenshots/mobile.png'",
    "src: '/icons/icon-192x192.png'": "src: '/tags/icons/icon-192x192.png'",
    "src: '/icons/icon-512x512.png'": "src: '/tags/icons/icon-512x512.png'",
}
for old, new in replacements.items():
    if old not in manifest:
        raise SystemExit(f"Не найден ожидаемый фрагмент manifest.ts: {old!r}")
    manifest = manifest.replace(old, new)
manifest_path.write_text(manifest, encoding="utf-8")

# Контрольные проверки — не позволяем собрать частично пропатченный образ.
checks = {
    "package.json": ['"build": "next build --webpack"'],
    "Dockerfile": [
        'ENV NODE_OPTIONS="--max-old-space-size=1536"',
        "libsql native runtime OK",
        "@libsql/linux-*musl*",
    ],
    "next.config.ts": ['basePath: "/tags"', "skipTrailingSlashRedirect: true", "webpackMemoryOptimizations: true"],
    "src/auth.ts": ["signIn: '/tags/login'"],
    "src/app/layout.tsx": ["basePath='/tags/api/auth'"],
    "src/lib/axios.ts": ["baseURL: '/tags/api'"],
    "src/features/musicbrainz/hooks/use-fetch-musicbrainz-cover.ts": [
        "import { api } from '@/lib/axios'",
        "api.post<FetchCoverResult>(`/songs/${songId}/musicbrainz/fetch-cover`,",
    ],
    "src/features/musicbrainz/hooks/use-bulk-fetch-musicbrainz-cover.ts": [
        "fetch('/tags/api/songs/bulk/musicbrainz/fetch-cover',",
    ],
    "src/app/page.tsx": ["const songCount = await countSongs()", "const session = await auth()"],
    "src/proxy.ts": [
        "const BASE_PATH = '/tags'",
        "const url = new URL(request.url)",
        "externalUrl(request, '/login')",
    ],
}
for rel, needles in checks.items():
    data = (root / rel).read_text(encoding="utf-8")
    for needle in needles:
        if needle not in data:
            raise SystemExit(f"Патч Tagr не применён: {rel}: {needle}")

page_data = (root / "src/app/page.tsx").read_text(encoding="utf-8")
if "redirect(" in page_data or "next/navigation" in page_data:
    raise SystemExit(
        "Корневая server component не должна выполнять редирект: "
        "авторизация маршрута централизована в proxy.ts."
    )

proxy_data = (root / "src/proxy.ts").read_text(encoding="utf-8")
# Проверяем только исполняемые строки. Комментарий выше намеренно объясняет,
# почему request.nextUrl.clone() использовать нельзя, и не должен считаться
# ошибочным кодом.
proxy_code = "\n".join(
    line for line in proxy_data.splitlines()
    if not line.lstrip().startswith("//")
)
for forbidden in (
    "request.nextUrl.clone()",
    "externalPath(",
    "url.pathname = `${BASE_PATH}",
):
    if forbidden in proxy_code:
        raise SystemExit(
            "Proxy Tagr содержит небезопасную обработку basePath: " + forbidden
        )

axios_data = (root / "src/lib/axios.ts").read_text(encoding="utf-8")
if "baseURL: '/api'" in axios_data or 'baseURL: "/api"' in axios_data:
    raise SystemExit(
        "Клиентский API Tagr всё ещё направлен в корень домена /api вместо /tags/api."
    )

cover_hook = (root / "src/features/musicbrainz/hooks/use-fetch-musicbrainz-cover.ts").read_text(encoding="utf-8")
if "import axios from 'axios'" in cover_hook or "axios.post<FetchCoverResult>(`/api/" in cover_hook:
    raise SystemExit(
        "Одиночная загрузка обложки MusicBrainz всё ещё использует абсолютный /api."
    )

bulk_cover_hook = (root / "src/features/musicbrainz/hooks/use-bulk-fetch-musicbrainz-cover.ts").read_text(encoding="utf-8")
if "fetch('/api/songs/bulk/musicbrainz/fetch-cover'" in bulk_cover_hook:
    raise SystemExit(
        "Массовая загрузка обложек MusicBrainz всё ещё использует абсолютный /api."
    )

auth_data = (root / "src/auth.ts").read_text(encoding="utf-8")
if "basePath:" in auth_data:
    raise SystemExit(
        "Серверный basePath Auth.js не должен содержать /tags: "
        "Next.js удаляет этот префикс перед route handler."
    )

print("Tagr /tags patch OK; redirects, scan API and MusicBrainz cover API use /tags")
PYTAGRPATCH

    chown -R "${RUN_UID}:${RUN_GID}" "${TAGR_SOURCE_DIR}"
}

# ------------------------------------------------------------------------------
# Runtime secrets and Docker Compose
# ------------------------------------------------------------------------------

write_runtime_secrets_and_configs() {
    log "Сохранение секретов вне Docker Compose"

    # Ограниченная umask действует только при создании секретов и не влияет
    # на последующие конфигурационные файлы и unit-файлы.
    (
        umask 077
        install -d -m 0700 "${SECRETS_DIR}"

    printf '%s' "${TAGR_LOGIN}" > "${TAGR_LOGIN_FILE}"
    printf '%s' "${TAGR_PASSWORD}" > "${TAGR_PASSWORD_FILE}"
    printf '%s' "${TAGR_SECRET}" > "${TAGR_SECRET_FILE}"
    chmod 0600 "${TAGR_LOGIN_FILE}" "${TAGR_PASSWORD_FILE}" "${TAGR_SECRET_FILE}"

    if [[ "${DEPLOY_MODE}" == "home" ]]; then
        printf '%s' "${TUNNEL_TOKEN}" > "${CLOUDFLARED_TOKEN_FILE}"
        chmod 0600 "${CLOUDFLARED_TOKEN_FILE}"
    else
        rm -f "${CLOUDFLARED_TOKEN_FILE}"
    fi

    cat > "${COPYPARTY_CONFIG_FILE}" <<EOF
[global]
  i: 127.0.0.1
  p: 3923
  rp-loc: /uploads
  xff-hdr: X-Forwarded-For
  xff-src: 127.0.0.1
  rproxy: 1
  usernames
  no-robots
  hist: /cfg/hists
  # Показывать предупреждение об уязвимой версии в панели управления.
  # Не завершаем контейнер автоматически: удалённый advisory-сервис не должен
  # превращать установку в бесконечный restart-loop без понятной диагностики.
  vc-url: https://api.copyparty.eu/advisories-panic

[accounts]
  ${UPLOAD_LOGIN}: ${UPLOAD_PASSWORD}

[/]
  /upload
  accs:
    A: ${UPLOAD_LOGIN}
EOF
    chown "${RUN_UID}:${RUN_GID}" "${COPYPARTY_CONFIG_FILE}"
    chmod 0600 "${COPYPARTY_CONFIG_FILE}"

    # Проверяем, что конфигурация содержит именно введённые реквизиты и
    # обязательные параметры reverse proxy. Пароль при этом не выводится.
    python3 - "${COPYPARTY_CONFIG_FILE}" "${UPLOAD_LOGIN}" "${UPLOAD_PASSWORD}" <<'PYCPCONFIG'
from pathlib import Path
import sys

path = Path(sys.argv[1])
login = sys.argv[2]
password = sys.argv[3]
text = path.read_text(encoding="utf-8")

required = (
    "i: 127.0.0.1",
    "p: 3923",
    "rp-loc: /uploads",
    "xff-src: 127.0.0.1",
    "rproxy: 1",
    "usernames",
    f"{login}: {password}",
    f"A: {login}",
)
missing = [item for item in required if item not in text]
if missing:
    raise SystemExit(
        "Конфигурация Copyparty создана не полностью: " + ", ".join(missing)
    )
PYCPCONFIG

    cat > "${TAGR_ENTRYPOINT_SCRIPT}" <<'EOF'
#!/bin/sh
set -eu

AUTH_USER="$(cat /run/secrets/tagr_login)"
AUTH_PASSWORD="$(cat /run/secrets/tagr_password)"
AUTH_SECRET="$(cat /run/secrets/tagr_secret)"
export AUTH_USER AUTH_PASSWORD AUTH_SECRET

exec /app/docker-entrypoint.sh
EOF
        chmod 0755 "${TAGR_ENTRYPOINT_SCRIPT}"
    )
}

write_compose() {
    log "Создание Docker Compose"

    cat > "${COMPOSE_FILE}" <<EOF
services:
  navidrome:
    image: "${NAVIDROME_IMAGE}"
    container_name: music-cloud-navidrome
    user: "${RUN_UID}:${RUN_GID}"
    restart: unless-stopped
    ports:
      - "127.0.0.1:4533:4533"
    environment:
      ND_MUSICFOLDER: /music
      ND_DATAFOLDER: /data
      ND_LOGLEVEL: info
      ND_SCANNER_SCANONSTARTUP: "true"
      ND_SCANNER_SCHEDULE: "1m"
    volumes:
      - "${LIBRARY_DIR}:/music:ro"
      - "${STACK_DIR}/navidrome-data:/data"
    security_opt:
      - no-new-privileges:true

  uploads:
    image: "${COPYPARTY_IMAGE}"
    container_name: music-cloud-uploads
    user: "${RUN_UID}:${RUN_GID}"
    restart: unless-stopped
    # Host networking исключает Docker-NAT между Caddy и Copyparty.
    # Сам Copyparty слушает только 127.0.0.1 благодаря параметру i в конфиге.
    network_mode: host
    # Официальный образ автоматически загружает все *.conf из /cfg.
    # Явный -c здесь не нужен и может привести к повторной загрузке конфига.
    environment:
      PYTHONUNBUFFERED: "1"
    volumes:
      - "${UPLOAD_DIR}:/upload"
      - "${STACK_DIR}/copyparty-data:/cfg"
    stop_grace_period: 15s
    healthcheck:
      test: ["CMD-SHELL", "wget --spider -q 'http://127.0.0.1:3923/uploads/?reset=/._'"]
      interval: 5s
      timeout: 3s
      retries: 12
      start_period: 20s
    security_opt:
      - no-new-privileges:true

  tagr:
    build:
      context: "${TAGR_SOURCE_DIR}"
      args:
        APP_VERSION: "${TAGR_GIT_REF}"
    image: "local/music-cloud-tagr:${TAGR_GIT_REF}"
    container_name: music-cloud-tagr
    restart: unless-stopped
    entrypoint:
      - "/bin/sh"
      - "/run/music-cloud/tagr-entrypoint.sh"
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      PUID: "${RUN_UID}"
      PGID: "${RUN_GID}"
      NODE_ENV: production
      DATABASE_URL: "file:/data/tagr.db"
      # AUTH_URL содержит только origin. Серверный Auth.js использует
      # внутренний /api/auth, потому что Next.js удаляет /tags перед route
      # handler. Внешний /tags/api/auth задаётся SessionProvider на клиенте.
      AUTH_URL: "https://${DOMAIN}"
      AUTH_TRUST_HOST: "true"
      MUSIC_FOLDERS: "/music"
    volumes:
      - "${STACK_DIR}/tagr-data:/data"
      - "${LIBRARY_DIR}:/music"
      - "${TAGR_ENTRYPOINT_SCRIPT}:/run/music-cloud/tagr-entrypoint.sh:ro"
      - "${TAGR_LOGIN_FILE}:/run/secrets/tagr_login:ro"
      - "${TAGR_PASSWORD_FILE}:/run/secrets/tagr_password:ro"
      - "${TAGR_SECRET_FILE}:/run/secrets/tagr_secret:ro"
    healthcheck:
      test: ["CMD-SHELL", "wget --spider -q 'http://127.0.0.1:3000/tags/login'"]
      interval: 5s
      timeout: 3s
      retries: 18
      start_period: 45s
    security_opt:
      - no-new-privileges:true
EOF

    chmod 0600 "${COMPOSE_FILE}"
    docker compose -f "${COMPOSE_FILE}" config >/dev/null

    # Проверяем точные строки. grep -F воспринимает перевод строки внутри
    # шаблона как несколько шаблонов; пустой шаблон совпадает с любой строкой.
    python3 - "${COMPOSE_FILE}" "${UPLOAD_PASSWORD}" "${TAGR_PASSWORD}" <<'PYSECRET'
from pathlib import Path
import sys

compose_path = Path(sys.argv[1])
secrets = {
    "пароль Copyparty": sys.argv[2],
    "пароль Tagr": sys.argv[3],
}
compose_text = compose_path.read_text(encoding="utf-8")

for label, value in secrets.items():
    if not value:
        raise SystemExit(f"Пустой секрет: {label}")
    if "\n" in value or "\r" in value:
        raise SystemExit(f"Недопустимый перевод строки в секрете: {label}")
    if value in compose_text:
        raise SystemExit(f"Секрет обнаружен в Docker Compose: {label}")
PYSECRET
}

# ------------------------------------------------------------------------------
# systemd automation
# ------------------------------------------------------------------------------

write_auto_import() {
    log "Настройка устойчивого автоматического импорта с заменой дублей"

    cat > "${DEDUPE_SCRIPT}" <<PYDEDUPE
#!/opt/music-cloud/beets-venv/bin/python
from __future__ import annotations

import os
import re
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path
from typing import Any

from beets.library import Library

DB_PATH = "${BEETS_CONFIG_DIR}/library.db"
MUSIC_DIR = "${LIBRARY_DIR}"


def norm(value: Any) -> str:
    if value is None:
        return ""
    text = unicodedata.normalize("NFKC", str(value)).casefold()
    return re.sub(r"\s+", " ", text).strip()


def as_int(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def value(obj: Any, key: str) -> Any:
    try:
        return obj.get(key, "")
    except Exception:
        return getattr(obj, key, "")


def item_path(item: Any) -> str:
    raw = value(item, "path")
    return os.fsdecode(raw) if raw else ""


def inside_music_dir(path: str) -> bool:
    if not path:
        return False
    try:
        return os.path.commonpath(
            (os.path.realpath(path), os.path.realpath(MUSIC_DIR))
        ) == os.path.realpath(MUSIC_DIR)
    except ValueError:
        return False


def album_key_from_item(item: Any, *, strict: bool) -> tuple[Any, ...] | None:
    mb_albumid = norm(value(item, "mb_albumid"))
    if mb_albumid:
        return ("mb_album", mb_albumid)

    albumartist = norm(value(item, "albumartist")) or norm(value(item, "artist"))
    album = norm(value(item, "album"))
    if not albumartist or not album:
        return None

    if strict:
        return (
            "album",
            albumartist,
            album,
            as_int(value(item, "year")),
            norm(value(item, "albumdisambig")),
        )
    return ("album", albumartist, album)


def album_key(album: Any) -> tuple[Any, ...] | None:
    mb_albumid = norm(value(album, "mb_albumid"))
    if mb_albumid:
        return ("mb_album", mb_albumid)

    albumartist = norm(value(album, "albumartist"))
    title = norm(value(album, "album"))
    if not albumartist or not title:
        return None

    return (
        "album",
        albumartist,
        title,
        as_int(value(album, "year")),
        norm(value(album, "albumdisambig")),
    )


def track_key(item: Any) -> tuple[Any, ...] | None:
    mb_albumid = norm(value(item, "mb_albumid"))
    mb_trackid = norm(value(item, "mb_trackid"))
    disc = as_int(value(item, "disc"))
    track = as_int(value(item, "track"))

    if mb_albumid and mb_trackid:
        return ("mb_track", mb_albumid, mb_trackid, disc, track)

    artist = norm(value(item, "artist"))
    albumartist = norm(value(item, "albumartist")) or artist
    title = norm(value(item, "title"))
    album = norm(value(item, "album"))

    if not artist or not title:
        return None

    if album:
        return (
            "metadata_track",
            albumartist,
            album,
            disc,
            track,
            artist,
            title,
        )

    return ("loose_single", artist, title)


def rank_item(item: Any) -> tuple[int, float, float, int]:
    path = item_path(item)
    exists = int(bool(path) and os.path.isfile(path))
    try:
        added = float(value(item, "added") or 0)
    except (TypeError, ValueError):
        added = 0.0
    try:
        mtime = os.path.getmtime(path) if exists else 0.0
    except OSError:
        mtime = 0.0
    return (exists, added, mtime, as_int(value(item, "id")))


def rank_album(album: Any) -> tuple[int, float, int]:
    count = sum(1 for _ in album.items())
    try:
        added = float(value(album, "added") or 0)
    except (TypeError, ValueError):
        added = 0.0
    return (count, added, as_int(value(album, "id")))


def same_file(a: str, b: str) -> bool:
    if not a or not b:
        return False
    if os.path.realpath(a) == os.path.realpath(b):
        return True
    try:
        return os.path.exists(a) and os.path.exists(b) and os.path.samefile(a, b)
    except OSError:
        return False


def remove_duplicate(loser: Any, winner: Any) -> None:
    loser_path = item_path(loser)
    winner_path = item_path(winner)

    delete_file = bool(
        loser_path
        and os.path.isfile(loser_path)
        and inside_music_dir(loser_path)
        and not same_file(loser_path, winner_path)
    )

    print(
        "REPLACE: keeping id={} {!r}; removing id={} {!r}{}".format(
            value(winner, "id"),
            winner_path,
            value(loser, "id"),
            loser_path,
            " and old file" if delete_file else " from database",
        )
    )
    loser.remove(delete=delete_file)


def deduplicate_tracks(lib: Library) -> int:
    groups: dict[tuple[Any, ...], list[Any]] = defaultdict(list)
    for item in lib.items():
        key = track_key(item)
        if key is not None:
            groups[key].append(item)

    removed = 0
    for items in groups.values():
        if len(items) < 2:
            continue
        winner = max(items, key=rank_item)
        for loser in sorted(items, key=rank_item, reverse=True):
            if value(loser, "id") == value(winner, "id"):
                continue
            remove_duplicate(loser, winner)
            removed += 1
    return removed


def consolidate_albums(lib: Library) -> int:
    groups: dict[tuple[Any, ...], list[Any]] = defaultdict(list)
    for album in lib.albums():
        key = album_key(album)
        if key is not None:
            groups[key].append(album)

    changes = 0
    canonical: dict[tuple[Any, ...], Any] = {}

    for key, albums in groups.items():
        winner = max(albums, key=rank_album)
        canonical[key] = winner
        if len(albums) < 2:
            continue

        for old_album in albums:
            if value(old_album, "id") == value(winner, "id"):
                continue
            moved = 0
            for item in list(old_album.items()):
                item.album_id = winner.id
                item.store()
                moved += 1
            old_id = value(old_album, "id")
            old_album.remove(delete=False, with_items=False)
            changes += 1
            print(
                "ALBUM: merged album id={} into id={} ({} tracks)".format(
                    old_id, value(winner, "id"), moved
                )
            )

    for item in list(lib.items()):
        if value(item, "album_id"):
            continue
        key = album_key_from_item(item, strict=True)
        target = canonical.get(key) if key is not None else None
        if target is None:
            continue
        item.album_id = target.id
        item.store()
        changes += 1
        print(
            "ALBUM: attached singleton id={} to album id={}".format(
                value(item, "id"), value(target, "id")
            )
        )

    for album in list(lib.albums()):
        if any(True for _ in album.items()):
            continue
        album.remove(delete=False, with_items=False)
        changes += 1

    return changes


def main() -> int:
    if not os.path.isfile(DB_PATH):
        print(f"Library database does not exist yet: {DB_PATH}")
        print("MUSIC_CLOUD_REMOVED=0")
        print("MUSIC_CLOUD_ALBUM_CHANGES=0")
        return 0

    Path(MUSIC_DIR).mkdir(parents=True, exist_ok=True)
    lib = Library(DB_PATH, MUSIC_DIR)

    removed = deduplicate_tracks(lib)
    album_changes = consolidate_albums(lib)

    print(f"MUSIC_CLOUD_REMOVED={removed}")
    print(f"MUSIC_CLOUD_ALBUM_CHANGES={album_changes}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"Deduplication failed: {exc}", file=sys.stderr)
        raise
PYDEDUPE

    chmod 0755 "${DEDUPE_SCRIPT}"
    "${BEETS_VENV}/bin/python" -m py_compile "${DEDUPE_SCRIPT}"

    cat > "${AUTO_IMPORT_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

UPLOAD="${UPLOAD_DIR}"
BEET="${BEETS_WRAPPER}"
DEDUPE="${DEDUPE_SCRIPT}"
LOG="${BEETS_CONFIG_DIR}/auto-import.log"
LOCK="/run/lock/${APP_NAME}-beets.lock"
QUIET_SECONDS=45
MAX_NO_PROGRESS=2

find_audio() {
    find "\${UPLOAD}" -type f \
        \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.m4a' -o \
           -iname '*.mp4' -o -iname '*.ogg' -o -iname '*.opus' -o \
           -iname '*.wav' -o -iname '*.wave' -o -iname '*.aif' -o \
           -iname '*.aiff' -o -iname '*.alac' -o -iname '*.wma' -o \
           -iname '*.ape' -o -iname '*.mpc' -o -iname '*.tta' -o \
           -iname '*.dsf' -o -iname '*.dff' \) "\$@"
}

has_audio() {
    find_audio -print -quit | grep -q .
}

count_audio() {
    find_audio -printf 'x\n' | wc -l
}

upload_has_content() {
    find "\${UPLOAD}" -mindepth 1 \
        ! -name '.music-cloud-keep' -print -quit | grep -q .
}

wait_for_first_audio() {
    local attempt

    # Copyparty сначала может создать каталог, а файл записать уже внутри него.
    # PathChanged на корне не рекурсивен, поэтому не выходим мгновенно из
    # сервиса в узком окне между созданием каталога и появлением аудиофайла.
    for attempt in {1..15}; do
        has_audio && return 0
        upload_has_content || return 1
        sleep 2
    done

    has_audio
}

wait_for_upload_quiet() {
    local rc

    echo "Ожидание \${QUIET_SECONDS} секунд без изменений в каталоге загрузки..."

    while true; do
        set +e
        /usr/bin/inotifywait -q -r -t "\${QUIET_SECONDS}" \
            -e close_write,moved_to,moved_from,create,delete,modify,attrib \
            -- "\${UPLOAD}" >/dev/null 2>>"\${LOG}"
        rc=\$?
        set -e

        case "\${rc}" in
            0) continue ;;
            2) return 0 ;;
            *)
                # Ошибка inotify (например, исчерпан лимит watches) не должна
                # навсегда блокировать импорт уже загруженных файлов. Даём
                # записи завершиться и продолжаем по таймерному fallback.
                echo "inotifywait завершился с кодом \${rc}; fallback: ожидание \${QUIET_SECONDS} секунд без inotify."
                sleep "\${QUIET_SECONDS}"
                return 0
                ;;
        esac
    done
}

run_dedupe() {
    local output status removed album_changes

    set +e
    output="\$("\${DEDUPE}" 2>&1)"
    status=\$?
    set -e
    printf '%s\n' "\${output}"

    if (( status != 0 )); then
        echo "Обработчик замены дублей завершился с кодом \${status}."
        return "\${status}"
    fi

    removed="\$(awk -F= '/^MUSIC_CLOUD_REMOVED=/{print \$2}' <<<"\${output}" | tail -n 1)"
    album_changes="\$(awk -F= '/^MUSIC_CLOUD_ALBUM_CHANGES=/{print \$2}' <<<"\${output}" | tail -n 1)"
    removed="\${removed:-0}"
    album_changes="\${album_changes:-0}"

    if (( removed > 0 || album_changes > 0 )); then
        echo "Нормализация путей после замены дублей..."
        "\${BEET}" move
    fi
}

mkdir -p "\${UPLOAD}"
touch "\${UPLOAD}/.music-cloud-keep"

exec 9>"\${LOCK}"

if ! flock -w 600 9; then
    echo "Не удалось получить блокировку beets за 600 секунд." >>"\${LOG}"
    exit 1
fi

{
    echo
    echo "===== \$(date --iso-8601=seconds) ====="

    if ! wait_for_first_audio; then
        echo "Поддерживаемых аудиофайлов для импорта нет."
        exit 0
    fi

    no_progress=0

    while has_audio; do
        wait_for_upload_quiet

        before_count="\$(count_audio)"
        echo "Аудиофайлов перед импортом: \${before_count}"

        set +e
        "\${BEET}" import -q "\${UPLOAD}"
        import_status=\$?
        set -e

        dedupe_status=0
        run_dedupe || dedupe_status=\$?

        find "\${UPLOAD}" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true

        after_count="\$(count_audio)"
        echo "beets exit status: \${import_status}"
        echo "dedupe exit status: \${dedupe_status}"
        echo "Аудиофайлов после импорта: \${after_count}"

        if (( after_count == 0 )); then
            if (( dedupe_status != 0 )); then
                echo "Файлы импортированы, но замена дублей завершилась ошибкой."
                exit "\${dedupe_status}"
            fi
            echo "Импорт завершён: новые версии заменили старые совпадающие треки."
            exit "\${import_status}"
        fi

        if (( after_count < before_count )); then
            no_progress=0
            echo "Импорт продвинулся; повторная проверка оставшихся файлов."
            continue
        fi

        no_progress=\$((no_progress + 1))

        if (( import_status != 0 || dedupe_status != 0 || no_progress >= MAX_NO_PROGRESS )); then
            echo "Импорт не продвинулся. Оставшиеся аудиофайлы:"
            find_audio -printf '  %P\n' | sed -n '1,100p'
            echo "Следующая автоматическая попытка будет выполнена таймером."
            exit 1
        fi

        sleep 10
    done
} >>"\${LOG}" 2>&1
EOF

    chmod 0755 "${AUTO_IMPORT_SCRIPT}"

    # systemd.path использует inotify только для указанного каталога и не
    # наблюдает вложенные каталоги рекурсивно. Copyparty часто загружает альбом
    # в новый подкаталог, поэтому отдельный рекурсивный watcher запускает
    # oneshot-импорт сразу при событиях внутри дерева. Таймер остаётся fallback.
    cat > "${UPLOAD_WATCH_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

UPLOAD="${UPLOAD_DIR}"
IMPORT_SERVICE="${AUTO_IMPORT_SERVICE}"

mkdir -p "\${UPLOAD}"

while true; do
    set +e
    /usr/bin/inotifywait -q -m -r \
        --format '%e|%w%f' \
        -e close_write,moved_to,create \
        -- "\${UPLOAD}" |
    while IFS='|' read -r events changed_path; do
        # Срабатываем и на CREATE каталога: auto-import имеет короткое окно
        # ожидания появления первого аудиофайла и закрывает гонку Copyparty.
        /bin/systemctl start --no-block "\${IMPORT_SERVICE}" || true
    done
    rc=\${PIPESTATUS[0]}
    set -e

    echo "upload watcher завершился с кодом \${rc}; повтор через 3 секунды" >&2
    sleep 3
done
EOF
    chmod 0755 "${UPLOAD_WATCH_SCRIPT}"

    cat > "/etc/systemd/system/${AUTO_IMPORT_SERVICE}" <<EOF
[Unit]
Description=Automatically import uploaded music and replace duplicate tracks
After=network-online.target
Wants=network-online.target
RequiresMountsFor=${LIBRARY_DIR}

[Service]
Type=oneshot
User=${RUN_USER}
Group=$(id -gn "${RUN_USER}")
Environment=HOME=${RUN_HOME}
Environment=LANG=en_US.UTF-8
Environment=LC_ALL=en_US.UTF-8
Environment=PYTHONUTF8=1
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=${AUTO_IMPORT_SCRIPT}
TimeoutStartSec=infinity
EOF

    cat > "/etc/systemd/system/${UPLOAD_WATCH_SERVICE}" <<EOF
[Unit]
Description=Recursively watch Music Cloud uploads
After=local-fs.target
RequiresMountsFor=${UPLOAD_DIR}

[Service]
Type=simple
ExecStart=${UPLOAD_WATCH_SCRIPT}
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

    cat > "/etc/systemd/system/${AUTO_IMPORT_PATH}" <<EOF
[Unit]
Description=Watch the music upload directory

[Path]
PathChanged=${UPLOAD_DIR}
PathModified=${UPLOAD_DIR}
Unit=${AUTO_IMPORT_SERVICE}

[Install]
WantedBy=multi-user.target
EOF

    cat > "/etc/systemd/system/${AUTO_IMPORT_TIMER}" <<EOF
[Unit]
Description=Retry pending Music Cloud imports

[Timer]
OnBootSec=2min
OnUnitInactiveSec=5min
AccuracySec=30s
Persistent=true
Unit=${AUTO_IMPORT_SERVICE}

[Install]
WantedBy=timers.target
EOF

    # Remove the experimental watcher name used by version 4.8 to avoid two
    # independent watchers starting the same importer.
    systemctl disable --now "${LEGACY_AUTO_IMPORT_WATCH_SERVICE}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${LEGACY_AUTO_IMPORT_WATCH_SERVICE}" "${LEGACY_AUTO_IMPORT_WATCH_SCRIPT}"

    systemctl daemon-reload
    systemctl reset-failed "${AUTO_IMPORT_SERVICE}" "${UPLOAD_WATCH_SERVICE}" 2>/dev/null || true
    systemctl enable --now "${AUTO_IMPORT_PATH}"
    systemctl enable --now "${AUTO_IMPORT_TIMER}"
    systemctl enable --now "${UPLOAD_WATCH_SERVICE}"

    # Process files that were uploaded before this repair/installation.
    systemctl start --no-block "${AUTO_IMPORT_SERVICE}" || true
}

write_beets_update_timer() {
    log "Настройка автоматической синхронизации beets после Tagr"

    cat > "${BEETS_UPDATE_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

LOG="${BEETS_CONFIG_DIR}/update.log"
LOCK="/run/lock/${APP_NAME}-beets.lock"

exec 9>"\${LOCK}"

# Импорт и обновление базы не должны обращаться к library.db одновременно.
if ! flock -w 600 9; then
    echo "Не удалось получить блокировку beets за 600 секунд." >>"\${LOG}"
    exit 1
fi

{
    echo
    echo "===== \$(date --iso-8601=seconds) ====="
    echo "Причина запуска: \${1:-systemd}"

    # update читает теги, изменённые внешним редактором, обновляет library.db
    # и по умолчанию перемещает/переименовывает файлы согласно paths. Флаг -M
    # намеренно НЕ используется, поскольку он запрещает перемещение.
    "${BEETS_WRAPPER}" update
} >>"\${LOG}" 2>&1
EOF

    chmod 0755 "${BEETS_UPDATE_SCRIPT}"

    cat > "${BEETS_WATCH_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

WATCH_DIR="${LIBRARY_DIR}"
UPDATE="${BEETS_UPDATE_SCRIPT}"
LOG="${BEETS_CONFIG_DIR}/update.log"

mkdir -p "\${WATCH_DIR}"

while true; do
    # Один рекурсивный inotifywait завершается после первого изменения. Пока
    # beets выполняет update и перемещает файл, watcher не слушает собственные
    # события, поэтому не образуется бесконечный цикл.
    if ! changed_path="\$(/usr/bin/inotifywait -q -r \
        -e close_write,moved_to,moved_from,create,delete \
        --format '%w%f' "\${WATCH_DIR}" 2>>"\${LOG}")"; then
        sleep 5
        continue
    fi

    # Tagr может записывать теги и обложку несколькими операциями. Даём записи
    # завершиться и объединяем их в один запуск beets.
    sleep 8

    # beets сравнивает mtime с сохранённым значением. touch после debounce
    # гарантирует, что даже правка сразу после импорта будет замечена.
    if [[ -f "\${changed_path}" ]]; then
        touch -- "\${changed_path}"
    fi

    if ! "\${UPDATE}" "изменение файлов Tagr/inotify"; then
        echo "\$(date --iso-8601=seconds): beets update завершился с ошибкой" >>"\${LOG}"
    fi

done
EOF

    chmod 0755 "${BEETS_WATCH_SCRIPT}"

    cat > "/etc/systemd/system/${BEETS_UPDATE_SERVICE}" <<EOF
[Unit]
Description=Synchronize beets database and paths after metadata changes
After=network-online.target
Wants=network-online.target
RequiresMountsFor=${LIBRARY_DIR}

[Service]
Type=oneshot
User=${RUN_USER}
Group=$(id -gn "${RUN_USER}")
Environment=HOME=${RUN_HOME}
Environment=LANG=en_US.UTF-8
Environment=LC_ALL=en_US.UTF-8
Environment=PYTHONUTF8=1
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=${BEETS_UPDATE_SCRIPT} systemd-timer
EOF

    cat > "/etc/systemd/system/${BEETS_UPDATE_TIMER}" <<EOF
[Unit]
Description=Safety synchronization of the beets database

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    cat > "/etc/systemd/system/${BEETS_WATCH_SERVICE}" <<EOF
[Unit]
Description=Watch Tagr metadata writes and synchronize beets paths
After=local-fs.target ${AUTO_IMPORT_PATH}
Wants=${AUTO_IMPORT_PATH}
RequiresMountsFor=${LIBRARY_DIR}

[Service]
Type=simple
User=${RUN_USER}
Group=$(id -gn "${RUN_USER}")
Environment=HOME=${RUN_HOME}
Environment=LANG=en_US.UTF-8
Environment=LC_ALL=en_US.UTF-8
Environment=PYTHONUTF8=1
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=${BEETS_WATCH_SCRIPT}
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${BEETS_UPDATE_TIMER}"
    systemctl enable --now "${BEETS_WATCH_SERVICE}"
}

# ------------------------------------------------------------------------------
# Caddy
# ------------------------------------------------------------------------------

ensure_caddy_import() {
    install -d -o root -g root -m 0755 "${CADDY_SITE_DIR}"

    if [[ ! -f /etc/caddy/Caddyfile ]]; then
        install -o root -g root -m 0644 /dev/null /etc/caddy/Caddyfile
    fi

    # Caddy работает от отдельного пользователя и должен иметь возможность
    # читать как основной файл, так и все импортируемые snippets.
    chown root:root /etc/caddy/Caddyfile
    chmod 0644 /etc/caddy/Caddyfile

    if ! grep -Fqx "import ${CADDY_SITE_DIR}/*.caddy" /etc/caddy/Caddyfile; then
        cp -a /etc/caddy/Caddyfile \
            "/etc/caddy/Caddyfile.backup.$(date +%Y%m%d-%H%M%S)"

        {
            printf '\n# Managed site snippets\n'
            printf 'import %s/*.caddy\n' "${CADDY_SITE_DIR}"
        } >> /etc/caddy/Caddyfile
    fi

    chown root:root /etc/caddy/Caddyfile
    chmod 0644 /etc/caddy/Caddyfile
}

show_caddy_diagnostics() {
    warn "Диагностика Caddy:"
    systemctl status caddy.service --no-pager -l >&2 || true
    journalctl -u caddy.service -n 100 --no-pager >&2 || true

    if [[ "${DEPLOY_MODE}" == "home" ]]; then
        printf '\nСлушающие процессы на origin-порту %s:\n' "${CADDY_ORIGIN_PORT}" >&2
        ss -ltnp "sport = :${CADDY_ORIGIN_PORT}" 2>/dev/null >&2 || true
    else
        printf '\nСлушающие процессы на портах 80/443:\n' >&2
        ss -ltnp 2>/dev/null | grep -E ':(80|443)([[:space:]]|$)' >&2 || true
    fi
}

write_caddy_site() {
    ensure_caddy_import

    if [[ "${DEPLOY_MODE}" == "home" ]]; then
        log "Настройка локального Caddy origin для Cloudflare Tunnel"
        site_address="http://:${CADDY_ORIGIN_PORT}"
        bind_line="    bind 127.0.0.1"
    else
        log "Настройка публичного Caddy и HTTPS"
        site_address="${DOMAIN}"
        bind_line=""
    fi

    cat > "${CADDY_SITE_FILE}" <<EOF
${site_address} {
${bind_line}
    encode zstd gzip

    redir /uploads /uploads/ 308
    redir /tags /tags/ 308

    @uploads path /uploads/*
    handle @uploads {
        reverse_proxy 127.0.0.1:3923 {
            header_up Host {host}
            header_up X-Forwarded-Host {host}
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Prefix /uploads
        }
    }

    @tags path /tags/*
    handle @tags {
        reverse_proxy 127.0.0.1:3000 {
            header_up Host {host}
            header_up X-Forwarded-Host {host}
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Prefix /tags
        }
    }

    handle {
        reverse_proxy 127.0.0.1:4533
    }
}
EOF

    caddy fmt --overwrite "${CADDY_SITE_FILE}"
    chown root:root "${CADDY_SITE_FILE}"
    chmod 0644 "${CADDY_SITE_FILE}"
    caddy validate --config /etc/caddy/Caddyfile

    if id caddy >/dev/null 2>&1; then
        runuser -u caddy -- env HOME=/var/lib/caddy /usr/bin/caddy validate --config /etc/caddy/Caddyfile
    else
        die "Системный пользователь caddy не найден после установки пакета."
    fi

    systemctl enable caddy
    if systemctl is-active --quiet caddy.service; then
        systemctl reload caddy.service || {
            show_caddy_diagnostics
            die "Caddy не смог применить конфигурацию через reload."
        }
    else
        systemctl start caddy.service || {
            show_caddy_diagnostics
            die "Caddy не смог запуститься."
        }
    fi
    systemctl is-active --quiet caddy.service || {
        show_caddy_diagnostics
        die "Caddy не находится в состоянии active после запуска."
    }
}

show_cloudflared_diagnostics() {
    warn "Диагностика Cloudflare Tunnel:"
    systemctl status "${CLOUDFLARED_SERVICE}" --no-pager -l >&2 || true
    journalctl -u "${CLOUDFLARED_SERVICE}" -n 150 --no-pager >&2 || true
    cloudflared --version >&2 2>/dev/null || true
}

disable_cloudflared_service() {
    systemctl disable --now "${CLOUDFLARED_SERVICE}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${CLOUDFLARED_SERVICE}"
    systemctl daemon-reload
}

write_cloudflared_service() {
    if [[ "${DEPLOY_MODE}" != "home" ]]; then
        disable_cloudflared_service
        return
    fi

    log "Настройка Cloudflare Tunnel как systemd-сервиса"
    [[ -s "${CLOUDFLARED_TOKEN_FILE}" ]] || die "Не найден файл токена ${CLOUDFLARED_TOKEN_FILE}."
    chmod 0600 "${CLOUDFLARED_TOKEN_FILE}"

    cat > "/etc/systemd/system/${CLOUDFLARED_SERVICE}" <<EOF
[Unit]
Description=Cloudflare Tunnel for Music Cloud
After=network-online.target caddy.service
Wants=network-online.target
Requires=caddy.service

[Service]
Type=simple
Environment=HOME=/var/lib/cloudflared-music-cloud
StateDirectory=cloudflared-music-cloud
StateDirectoryMode=0700
UMask=0077
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --metrics 127.0.0.1:${CLOUDFLARED_METRICS_PORT} run --token-file ${CLOUDFLARED_TOKEN_FILE}
Restart=on-failure
RestartSec=5s
TimeoutStopSec=30s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF

    systemd-analyze verify "/etc/systemd/system/${CLOUDFLARED_SERVICE}" >/dev/null
    systemctl daemon-reload
    systemctl enable --now "${CLOUDFLARED_SERVICE}"

    local attempt
    for attempt in {1..45}; do
        if systemctl is-active --quiet "${CLOUDFLARED_SERVICE}" &&
           curl -fsS --max-time 3 "http://127.0.0.1:${CLOUDFLARED_METRICS_PORT}/ready" >/dev/null 2>&1; then
            ok "Cloudflare Tunnel подключён и готов."
            return
        fi
        sleep 2
    done

    show_cloudflared_diagnostics
    die "Cloudflare Tunnel не достиг состояния ready. Проверьте токен и исходящий доступ."
}

# ------------------------------------------------------------------------------
# Firewall

# ------------------------------------------------------------------------------
# Firewall
# ------------------------------------------------------------------------------

configure_firewall() {
    if [[ "${DEPLOY_MODE}" == "home" ]]; then
        log "Проверка сетевой модели"
        ok "Входящие порты не открываются: Caddy слушает 127.0.0.1:${CADDY_ORIGIN_PORT}, cloudflared использует исходящие соединения."
        return
    fi

    if command -v ufw >/dev/null 2>&1 &&
       ufw status 2>/dev/null | grep -q '^Status: active'; then
        log "Открытие TCP 80/443 в активном UFW"
        ufw allow 80/tcp
        ufw allow 443/tcp
    else
        warn "UFW не активен. Убедитесь, что TCP 80 и 443 открыты в firewall провайдера."
    fi
}

# ------------------------------------------------------------------------------
# Start and verification

# ------------------------------------------------------------------------------
# Start and verification
# ------------------------------------------------------------------------------

TAGR_BUILD_SWAP_CREATED=0
TAGR_BUILD_ZRAM_DEVICE=""

show_tagr_build_diagnostics() {
    warn "Диагностика ресурсов сборки Tagr:"
    printf '%s\n' "--- память ---" >&2
    free -h >&2 || true
    printf '%s\n' "--- swap ---" >&2
    swapon --show >&2 || true
    printf '%s\n' "--- диски ---" >&2
    df -h "${STACK_DIR}" /var/lib/docker >&2 2>/dev/null || true
    printf '%s\n' "--- Docker ---" >&2
    docker system df >&2 2>/dev/null || true
    printf '%s\n' "--- последние сообщения ядра о памяти ---" >&2
    journalctl -k -n 250 --no-pager 2>/dev/null |
        grep -Ei 'out of memory|oom-kill|killed process' |
        tail -n 30 >&2 || true
}

cleanup_tagr_build_swap() {
    if (( TAGR_BUILD_SWAP_CREATED != 1 )); then
        return
    fi

    log "Удаление временного swap после сборки Tagr"
    swapoff "${TAGR_BUILD_SWAP_FILE}" 2>/dev/null || true
    rm -f "${TAGR_BUILD_SWAP_FILE}"
    TAGR_BUILD_SWAP_CREATED=0
}

ensure_tagr_build_resources() {
    local mem_kib swap_kib total_kib missing_kib swap_mib
    local free_kib required_free_kib fs_type swap_dir

    mem_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    swap_kib="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
    mem_kib="${mem_kib:-0}"
    swap_kib="${swap_kib:-0}"
    total_kib=$((mem_kib + swap_kib))

    printf 'Ресурсы сборки: RAM=%s MiB, swap=%s MiB, всего=%s MiB\n' \
        "$((mem_kib / 1024))" \
        "$((swap_kib / 1024))" \
        "$((total_kib / 1024))"

    if (( total_kib >= TAGR_BUILD_MIN_TOTAL_KIB )); then
        return
    fi

    swap_dir="$(dirname "${TAGR_BUILD_SWAP_FILE}")"
    install -d -m 0755 "${swap_dir}"

    missing_kib=$((TAGR_BUILD_MIN_TOTAL_KIB - total_kib))
    swap_mib=$(((missing_kib + 1023) / 1024 + 512))
    required_free_kib=$(((swap_mib + 4096) * 1024))

    free_kib="$(df --output=avail -k "${swap_dir}" |
        awk 'NR==2 {print $1}')"
    free_kib="${free_kib:-0}"

    if (( free_kib < required_free_kib )); then
        show_tagr_build_diagnostics
        die "На разделе ${swap_dir} недостаточно места: нужно около ${swap_mib} MiB для swap и 4 GiB запаса."
    fi

    fs_type="$(findmnt -no FSTYPE --target "${swap_dir}" 2>/dev/null || true)"

    case "${fs_type}" in
        ext2|ext3|ext4|xfs)
            ;;
        *)
            die "Раздел ${swap_dir} (${fs_type:-неизвестная ФС}) не подходит для swap-файла."
            ;;
    esac

    log "Создание дискового swap ${swap_mib} MiB на ${swap_dir}"

    swapoff "${TAGR_BUILD_SWAP_FILE}" 2>/dev/null || true
    rm -f "${TAGR_BUILD_SWAP_FILE}"

    if ! fallocate -l "${swap_mib}M" "${TAGR_BUILD_SWAP_FILE}"; then
        dd if=/dev/zero \
            of="${TAGR_BUILD_SWAP_FILE}" \
            bs=1M \
            count="${swap_mib}" \
            status=progress \
            conv=fsync
    fi

    chmod 0600 "${TAGR_BUILD_SWAP_FILE}"
    mkswap "${TAGR_BUILD_SWAP_FILE}" >/dev/null

    swapon -p 100 "${TAGR_BUILD_SWAP_FILE}" ||
        die "Не удалось подключить swap на ${swap_dir}."

    TAGR_BUILD_ZRAM_DEVICE=""
    TAGR_BUILD_SWAP_CREATED=1

    swapon --show
    ok "Дисковый swap подключён. После сборки он будет удалён."
}

build_tagr_image() {
    local status

    ensure_tagr_build_resources

    docker buildx rm --force music-cloud-native \
        >/dev/null 2>&1 || true
    docker rm -f buildx_buildkit_music-cloud-native0 \
        >/dev/null 2>&1 || true

    docker buildx use default >/dev/null
    docker buildx inspect default --bootstrap >/dev/null

    set +e
    timeout \
        --foreground \
        --signal=TERM \
        --kill-after=5m \
        "${TAGR_BUILD_TIMEOUT}" \
        env BUILDKIT_PROGRESS=plain \
        docker buildx build \
            --builder default \
            --load \
            --pull \
            --progress=plain \
            --provenance=false \
            --build-arg "APP_VERSION=${TAGR_GIT_REF}" \
            --tag "local/music-cloud-tagr:${TAGR_GIT_REF}" \
            "${TAGR_SOURCE_DIR}"
    status=$?
    set -e

    cleanup_tagr_build_swap

    case "${status}" in
        0)
            if ! docker run --rm --entrypoint /bin/sh \
                "local/music-cloud-tagr:${TAGR_GIT_REF}" -c '
                    set -eu
                    libsql_entry="$(find /app/node_modules \
                        -type f \
                        -path "*/libsql/index.js" |
                        head -n 1)"
                    test -n "${libsql_entry}"
                    node -e "require(process.argv[1])" \
                        "${libsql_entry}"
                '; then
                show_tagr_build_diagnostics
                die "Собранный образ Tagr не прошёл проверку libSQL."
            fi

            ok "Образ Tagr успешно собран и прошёл проверку libSQL."
            ;;
        124)
            show_tagr_build_diagnostics
            die "Сборка Tagr превысила лимит ${TAGR_BUILD_TIMEOUT}."
            ;;
        137)
            show_tagr_build_diagnostics
            die "Сборка Tagr была завершена из-за нехватки памяти."
            ;;
        *)
            show_tagr_build_diagnostics
            die "Сборка Tagr завершилась с кодом ${status}."
            ;;
    esac
}

start_stack() {
    log "Загрузка закреплённых образов и запуск контейнеров"

    local pull_attempt

    for pull_attempt in {1..6}; do
        if docker compose -f "${COMPOSE_FILE}" pull navidrome uploads; then
            break
        fi

        if (( pull_attempt == 6 )); then
            die "Не удалось загрузить образы после 6 попыток. Проверьте доступ к auth.docker.io и registry-1.docker.io."
        fi

        warn "Ошибка соединения с Docker Hub. Повторная попытка ${pull_attempt}/6 через $((pull_attempt * 15)) секунд."
        sleep $((pull_attempt * 15))
    done

    trap 'cleanup_tagr_build_swap' EXIT
    trap 'cleanup_tagr_build_swap; exit 130' INT TERM
    build_tagr_image
    trap - EXIT INT TERM

    # Образ уже собран через buildx; --no-build запрещает Compose случайно
    # запустить вторую скрытую сборку.
    docker compose -f "${COMPOSE_FILE}" up -d \
        --no-build --remove-orphans --force-recreate
    docker compose -f "${COMPOSE_FILE}" ps
}

show_container_diagnostics() {
    local container="$1"

    warn "Диагностика контейнера ${container}:"

    docker inspect --format \
        'Status={{.State.Status}} Running={{.State.Running}} Restarting={{.State.Restarting}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}} RestartCount={{.RestartCount}} Error={{.State.Error}}' \
        "${container}" 2>/dev/null || true

    printf '%s\n' "--- последние логи ${container} ---" >&2
    docker logs --tail=150 "${container}" 2>&1 || true
    printf '%s\n' "--- конец логов ${container} ---" >&2
}

show_storage_diagnostics() {
    warn "Права, владельцы и файловые системы Music Cloud:"
    ls -ldn \
        "${DATA_DIR}" \
        "${UPLOAD_DIR}" \
        "${LIBRARY_DIR}" \
        "${STACK_DIR}/copyparty-data" \
        "${STACK_DIR}/tagr-data" 2>/dev/null || true

    findmnt --target "${LIBRARY_DIR}" 2>/dev/null || true
    df -h "${LIBRARY_DIR}" "${STACK_DIR}" 2>/dev/null || true

    if command -v namei >/dev/null 2>&1; then
        namei -l "${UPLOAD_DIR}" "${LIBRARY_DIR}" 2>/dev/null || true
    fi
}

wait_for_container() {
    local container="$1"
    local stable_seconds=0
    local last_restart_count=""
    local attempt state running restarting health restart_count

    # Running=true недостаточно: контейнер в restart-loop бывает running несколько
    # секунд между падениями. Требуем непрерывно стабильное состояние и, если
    # healthcheck определён, статус healthy.
    for attempt in {1..90}; do
        if ! docker inspect "${container}" >/dev/null 2>&1; then
            sleep 2
            continue
        fi

        IFS='|' read -r state running restarting health restart_count < <(
            docker inspect --format \
                '{{.State.Status}}|{{.State.Running}}|{{.State.Restarting}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}' \
                "${container}"
        )

        if [[ "${state}" == "running" &&
              "${running}" == "true" &&
              "${restarting}" == "false" &&
              ( "${health}" == "none" || "${health}" == "healthy" ) ]]; then
            if [[ -n "${last_restart_count}" &&
                  "${restart_count}" == "${last_restart_count}" ]]; then
                stable_seconds=$((stable_seconds + 2))
            else
                stable_seconds=2
                last_restart_count="${restart_count}"
            fi

            if (( stable_seconds >= 12 )); then
                ok "Контейнер ${container} стабильно запущен."
                return
            fi
        else
            stable_seconds=0
            last_restart_count="${restart_count}"
        fi

        sleep 2
    done

    show_container_diagnostics "${container}"
    die "Контейнер ${container} не достиг стабильного состояния running/healthy."
}

wait_for_http() {
    local label="$1"
    local container="$2"
    shift 2

    local attempt code
    for attempt in {1..60}; do
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "$@" 2>/dev/null || true)"
        if [[ "${code}" =~ ^[234][0-9][0-9]$ ]]; then
            ok "${label}: HTTP ${code}."
            return
        fi
        sleep 2
    done

    if [[ -n "${container}" ]]; then
        show_container_diagnostics "${container}"
    fi
    die "${label} не отвечает корректным HTTP-статусом."
}

verify_host_write_access() {
    local path="$1"
    local label="$2"

    if ! run_as_owner sh -c \
        'set -eu; test -w "$1"; f="$1/.music-cloud-host-write-test.$$"; : > "$f"; rm -f "$f"' \
        sh "${path}"; then
        show_storage_diagnostics
        die "Пользователь ${RUN_USER} не может записывать в ${path} (${label})."
    fi
}

verify_container_write_access() {
    local container="$1"
    local path="$2"
    local label="$3"

    if ! docker exec --user "${RUN_UID}:${RUN_GID}" "${container}" \
        sh -c 'set -eu; test -w "$1"; f="$1/.music-cloud-container-write-test.$$"; : > "$f"; rm -f "$f"' \
        sh "${path}"; then
        show_container_diagnostics "${container}"
        show_storage_diagnostics
        die "${label}: контейнер не смог записать в ${path}. Причина приведена в диагностике выше."
    fi
}

verify_copyparty_config_mount() {
    local host_hash container_hash

    host_hash="$(sha256sum "${COPYPARTY_CONFIG_FILE}" | awk '{print $1}')"
    container_hash="$(docker exec music-cloud-uploads python3 -c \
        'import hashlib; print(hashlib.sha256(open("/cfg/music-cloud.conf", "rb").read()).hexdigest())' \
        2>/dev/null || true)"

    if [[ -z "${container_hash}" || "${container_hash}" != "${host_hash}" ]]; then
        show_container_diagnostics music-cloud-uploads
        die "Copyparty видит неактуальный или другой файл /cfg/music-cloud.conf."
    fi

    ok "Copyparty использует актуальную конфигурацию."
}

verify_copyparty_auth() {
    local base_url="$1"
    local expect_https="$2"
    shift 2

    local anonymous_code basic_code cookie_code page
    local cookie_jar login_body
    cookie_jar="$(mktemp)"
    login_body="$(mktemp)"

    # WebDAV PROPFIND обращается к защищённому тому, поэтому действительно
    # проверяет права. Basic Auth — стандартный путь для WebDAV-клиентов.
    anonymous_code="$(curl -sS -o /dev/null -w '%{http_code}' \
        --max-time 12 -X PROPFIND -H 'Depth: 0' "$@" "${base_url}" 2>/dev/null || true)"
    basic_code="$(curl -sS -o /dev/null -w '%{http_code}' \
        --max-time 12 --basic --user "${UPLOAD_LOGIN}:${UPLOAD_PASSWORD}" \
        -X PROPFIND -H 'Depth: 0' "$@" "${base_url}" 2>/dev/null || true)"

    if [[ ! "${basic_code}" =~ ^(200|207)$ ]]; then
        rm -f "${cookie_jar}" "${login_body}"
        show_container_diagnostics music-cloud-uploads
        die "Copyparty отклонил настроенные имя пользователя или пароль через Basic Auth (HTTP ${basic_code:-нет ответа})."
    fi

    # Имитируем реальную HTML-форму Copyparty. --form-string не трактует
    # пароль, начинающийся с @, как имя локального файла.
    curl -sS -L --max-time 15 \
        -c "${cookie_jar}" -b "${cookie_jar}" \
        --form-string 'act=login' \
        --form-string "uname=${UPLOAD_LOGIN}" \
        --form-string "cppwd=${UPLOAD_PASSWORD}" \
        --form-string 'uhash=-' \
        "$@" "${base_url}" -o "${login_body}" || true

    cookie_code="$(curl -sS -o /dev/null -w '%{http_code}' \
        --max-time 12 -c "${cookie_jar}" -b "${cookie_jar}" \
        -X PROPFIND -H 'Depth: 0' "$@" "${base_url}" 2>/dev/null || true)"

    if [[ ! "${cookie_code}" =~ ^(200|207)$ ]]; then
        rm -f "${cookie_jar}" "${login_body}"
        show_container_diagnostics music-cloud-uploads
        die "Copyparty отклонил сессию, созданную через веб-форму (HTTP ${cookie_code:-нет ответа})."
    fi

    if [[ "${anonymous_code}" =~ ^(200|207)$ ]]; then
        rm -f "${cookie_jar}" "${login_body}"
        die "Copyparty разрешает анонимный WebDAV-доступ к защищённому тому."
    fi

    if [[ "${expect_https}" == "1" ]]; then
        page="$(curl -fsS --max-time 12 "$@" "${base_url}" 2>/dev/null || true)"
        if grep -Fqi 'switch to https' <<<"${page}"; then
            rm -f "${cookie_jar}" "${login_body}"
            show_container_diagnostics music-cloud-uploads
            die "Copyparty не распознал HTTPS за Caddy. Проверьте forwarded headers."
        fi
    fi

    rm -f "${cookie_jar}" "${login_body}"
    ok "Copyparty: Basic Auth, веб-вход и запрет анонимного доступа проверены."
}

verify_tagr_routes() {
    local root_url="$1"
    local login_url="$2"
    local auth_url="$3"
    shift 3

    local headers final_url code
    headers="$(mktemp)"

    code="$(curl -sS -D "${headers}" -o /dev/null -w '%{http_code}' \
        --max-time 12 --max-redirs 0 "$@" "${login_url}" 2>/dev/null || true)"
    if [[ "${code}" != "200" ]]; then
        rm -f "${headers}"
        show_container_diagnostics music-cloud-tagr
        die "Tagr /tags/login должен отвечать HTTP 200 без редиректа, получен ${code:-нет ответа}."
    fi

    code="$(curl -sS -L -o /dev/null -w '%{http_code}' \
        --max-time 20 --max-redirs 5 "$@" "${root_url}" 2>/dev/null || true)"
    final_url="$(curl -sS -L -o /dev/null -w '%{url_effective}' \
        --max-time 20 --max-redirs 5 "$@" "${root_url}" 2>/dev/null || true)"

    if [[ "${code}" != "200" || ! "${final_url}" =~ /tags/login/?$ ]]; then
        rm -f "${headers}"
        show_container_diagnostics music-cloud-tagr
        die "Tagr имеет неправильную цепочку редиректов: HTTP ${code:-нет ответа}, итог ${final_url:-неизвестен}."
    fi

    code="$(curl -sS -o /dev/null -w '%{http_code}' \
        --max-time 12 "$@" "${auth_url}" 2>/dev/null || true)"
    rm -f "${headers}"

    if [[ "${code}" != "200" ]]; then
        show_container_diagnostics music-cloud-tagr
        die "Auth.js Tagr недоступен по /tags/api/auth/providers (HTTP ${code:-нет ответа})."
    fi

    ok "Tagr: страница входа, редиректы и endpoint Auth.js проверены."
}

verify_tagr_client_api_prefix() {
    local axios_file="${TAGR_SOURCE_DIR}/src/lib/axios.ts"
    local cover_file="${TAGR_SOURCE_DIR}/src/features/musicbrainz/hooks/use-fetch-musicbrainz-cover.ts"
    local bulk_cover_file="${TAGR_SOURCE_DIR}/src/features/musicbrainz/hooks/use-bulk-fetch-musicbrainz-cover.ts"

    if [[ ! -r "${axios_file}" ]] ||
       ! grep -Fq "baseURL: '/tags/api'" "${axios_file}" ||
       grep -Fq "baseURL: '/api'" "${axios_file}" ||
       [[ ! -r "${cover_file}" ]] ||
       ! grep -Fq "api.post<FetchCoverResult>(\`/songs/\${songId}/musicbrainz/fetch-cover\`," "${cover_file}" ||
       grep -Fq "axios.post<FetchCoverResult>(\`/api/" "${cover_file}" ||
       [[ ! -r "${bulk_cover_file}" ]] ||
       ! grep -Fq "fetch('/tags/api/songs/bulk/musicbrainz/fetch-cover'" "${bulk_cover_file}" ||
       grep -Fq "fetch('/api/songs/bulk/musicbrainz/fetch-cover'" "${bulk_cover_file}"; then
        show_container_diagnostics music-cloud-tagr
        die "Клиентские API Tagr или MusicBrainz собраны без обязательного префикса /tags/api."
    fi

    ok "Tagr: сканирование и загрузка обложек MusicBrainz направлены в /tags/api."
}

verify_tagr_auth_logs() {
    local logs

    logs="$(docker logs --since=10m music-cloud-tagr 2>&1 || true)"

    if grep -Eiq \
        'UnknownAction: Cannot parse action|\[auth\]\[error\].*UnknownAction' \
        <<<"${logs}"; then
        show_container_diagnostics music-cloud-tagr
        die "В журнале Tagr обнаружена ошибка маршрутизации Auth.js UnknownAction."
    fi

    ok "Tagr: в журнале нет ошибок UnknownAction Auth.js."
}

verify_public_route() {
    local attempt code

    for attempt in {1..20}; do
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 "https://${DOMAIN}/" 2>/dev/null || true)"
        if [[ "${code}" =~ ^[234][0-9][0-9]$ ]]; then
            PUBLIC_ROUTE_OK=1
            ok "Публичный маршрут Cloudflare: HTTPS ${code}."
            return
        fi
        sleep 3
    done

    PUBLIC_ROUTE_OK=0
    warn "Публичный hostname https://${DOMAIN}/ пока не отвечает через этот Tunnel."
    warn "В Cloudflare проверьте Published application: ${DOMAIN} → http://127.0.0.1:${CADDY_ORIGIN_PORT}."
}

verify_installation() {
    log "Строгая проверка установки"

    wait_for_container music-cloud-navidrome
    wait_for_container music-cloud-uploads
    wait_for_container music-cloud-tagr

    wait_for_http "Navidrome" "music-cloud-navidrome" "http://127.0.0.1:4533/"
    wait_for_http "Copyparty" "music-cloud-uploads" "http://127.0.0.1:3923/uploads/"
    wait_for_http "Tagr login" "music-cloud-tagr" "http://127.0.0.1:3000/tags/login"
    wait_for_http "Tagr Auth.js" "music-cloud-tagr" "http://127.0.0.1:3000/tags/api/auth/providers"

    if [[ "${DEPLOY_MODE}" == "home" ]]; then
        wait_for_http "Локальный Caddy origin" "" \
            -H "Host: ${DOMAIN}" "http://127.0.0.1:${CADDY_ORIGIN_PORT}/"
    fi

    verify_copyparty_config_mount
    verify_copyparty_auth "http://127.0.0.1:3923/uploads/" 0
    verify_tagr_routes \
        "http://127.0.0.1:3000/tags/" \
        "http://127.0.0.1:3000/tags/login" \
        "http://127.0.0.1:3000/tags/api/auth/providers"
    verify_tagr_client_api_prefix
    verify_tagr_auth_logs

    verify_host_write_access "${UPLOAD_DIR}" "каталог загрузки"
    verify_host_write_access "${LIBRARY_DIR}" "музыкальная библиотека"
    verify_container_write_access music-cloud-uploads /upload "Copyparty"
    verify_container_write_access music-cloud-tagr /music "Tagr"

    [[ -x "${DEDUPE_SCRIPT}" ]] || die "Обработчик дублей ${DEDUPE_SCRIPT} не установлен."
    [[ -x "${UPLOAD_WATCH_SCRIPT}" ]] || die "Watcher ${UPLOAD_WATCH_SCRIPT} не установлен."
    systemctl is-active --quiet "${AUTO_IMPORT_PATH}" || die "${AUTO_IMPORT_PATH} не запущен."
    systemctl is-active --quiet "${AUTO_IMPORT_TIMER}" || die "${AUTO_IMPORT_TIMER} не запущен."
    systemctl is-active --quiet "${UPLOAD_WATCH_SERVICE}" || die "${UPLOAD_WATCH_SERVICE} не запущен."
    systemctl is-active --quiet "${BEETS_UPDATE_TIMER}" || die "${BEETS_UPDATE_TIMER} не запущен."
    systemctl is-active --quiet "${BEETS_WATCH_SERVICE}" || die "${BEETS_WATCH_SERVICE} не запущен."
    systemctl is-active --quiet caddy || die "Caddy не запущен."
    caddy validate --config /etc/caddy/Caddyfile >/dev/null

    if [[ "${DEPLOY_MODE}" == "home" ]]; then
        systemctl is-active --quiet "${CLOUDFLARED_SERVICE}" || die "${CLOUDFLARED_SERVICE} не запущен."
        curl -fsS --max-time 5 "http://127.0.0.1:${CLOUDFLARED_METRICS_PORT}/ready" >/dev/null || {
            show_cloudflared_diagnostics
            die "Cloudflare Tunnel не готов."
        }
        verify_public_route
        if (( PUBLIC_ROUTE_OK == 1 )); then
            verify_copyparty_auth "https://${DOMAIN}/uploads/" 1
            verify_tagr_routes \
                "https://${DOMAIN}/tags/" \
                "https://${DOMAIN}/tags/login" \
                "https://${DOMAIN}/tags/api/auth/providers"
        fi
    elif (( DNS_MATCH == 1 )); then
        wait_for_http "Публичный HTTPS через Caddy" "" \
            --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/"
        verify_copyparty_auth "https://${DOMAIN}/uploads/" 1 \
            --resolve "${DOMAIN}:443:127.0.0.1"
        verify_tagr_routes \
            "https://${DOMAIN}/tags/" \
            "https://${DOMAIN}/tags/login" \
            "https://${DOMAIN}/tags/api/auth/providers" \
            --resolve "${DOMAIN}:443:127.0.0.1"
    else
        warn "Публичный HTTPS не проверен: DNS ещё не указывает на VPS."
    fi
}

show_install_diagnostics() {
    require_root

    log "Диагностика Music Cloud"

    if [[ -f "${INSTALL_STATE_FILE}" ]]; then
        load_install_state
    else
        warn "Файл состояния ${INSTALL_STATE_FILE} не найден."
        set_run_user "root"
    fi

    if [[ -f "${COMPOSE_FILE}" ]]; then
        docker compose -f "${COMPOSE_FILE}" ps -a || true
    else
        warn "Compose-файл ${COMPOSE_FILE} не найден."
    fi

    local container
    for container in \
        music-cloud-navidrome \
        music-cloud-uploads \
        music-cloud-tagr; do
        if docker inspect "${container}" >/dev/null 2>&1; then
            show_container_diagnostics "${container}"
        else
            warn "Контейнер ${container} не найден."
        fi
    done

    show_storage_diagnostics

    systemctl status caddy --no-pager -l 2>/dev/null || true
    systemctl status "${CLOUDFLARED_SERVICE}" --no-pager -l 2>/dev/null || true
    systemctl status "${AUTO_IMPORT_PATH}" --no-pager -l 2>/dev/null || true
    systemctl status "${AUTO_IMPORT_TIMER}" --no-pager -l 2>/dev/null || true
    systemctl status "${UPLOAD_WATCH_SERVICE}" --no-pager -l 2>/dev/null || true
    systemctl status "${BEETS_UPDATE_TIMER}" --no-pager -l 2>/dev/null || true
    systemctl status "${BEETS_WATCH_SERVICE}" --no-pager -l 2>/dev/null || true

    printf '%s
' "--- auto-import.log ---"
    tail -n 200 "${BEETS_CONFIG_DIR}/auto-import.log" 2>/dev/null || true
    printf '%s
' "--- import.log ---"
    tail -n 100 "${BEETS_CONFIG_DIR}/import.log" 2>/dev/null || true
}

save_credentials() {
    (
        umask 077
        cat > "${CREDENTIALS_FILE}" <<EOF
Music Cloud installed: $(date --iso-8601=seconds)
Deployment mode: ${DEPLOY_MODE}

Owner:
  User: ${RUN_USER}
  UID:GID: ${RUN_UID}:${RUN_GID}
  Home: ${RUN_HOME}

Navidrome:
  URL: https://${DOMAIN}/
  The first administrator is created in the browser wizard.

Uploads (Copyparty):
  URL: https://${DOMAIN}/uploads/
  Account name: ${UPLOAD_LOGIN}
  Password: ${UPLOAD_PASSWORD}

Tag editor:
  URL: https://${DOMAIN}/tags/
  Login: ${TAGR_LOGIN}
  Password: ${TAGR_PASSWORD}

Paths:
  Upload: ${UPLOAD_DIR}
  Library: ${LIBRARY_DIR}
  Stack: ${STACK_DIR}
  Beets config: ${BEETS_CONFIG_FILE}
EOF

        if [[ "${DEPLOY_MODE}" == "home" ]]; then
            cat >> "${CREDENTIALS_FILE}" <<EOF
  Cloudflare origin: http://127.0.0.1:${CADDY_ORIGIN_PORT}
  Tunnel token file: ${CLOUDFLARED_TOKEN_FILE}
EOF
        fi

        cat >> "${CREDENTIALS_FILE}" <<EOF

Commands:
  docker compose -f ${COMPOSE_FILE} ps
  systemctl status ${AUTO_IMPORT_PATH} --no-pager
  systemctl status ${AUTO_IMPORT_TIMER} --no-pager
  systemctl status ${UPLOAD_WATCH_SERVICE} --no-pager
  systemctl status ${BEETS_WATCH_SERVICE} --no-pager
  tail -n 100 ${BEETS_CONFIG_DIR}/auto-import.log
  tail -n 100 ${BEETS_CONFIG_DIR}/import.log
EOF
        chmod 0600 "${CREDENTIALS_FILE}"
    )
}

print_result() {
    cat <<EOF

============================================================
Установка завершена
============================================================

Режим: ${DEPLOY_MODE}

Navidrome:
  https://${DOMAIN}/

Copyparty:
  https://${DOMAIN}/uploads/
  Логин: ${UPLOAD_LOGIN}
  Пароль: см. ${CREDENTIALS_FILE}

Tagr:
  https://${DOMAIN}/tags/
  Логин: ${TAGR_LOGIN}
  Пароль: см. ${CREDENTIALS_FILE}

Музыкальная библиотека:
  ${LIBRARY_DIR}

Проверка импорта:
  tail -f ${BEETS_CONFIG_DIR}/auto-import.log

Ручной запуск ожидающих файлов:
  sudo systemctl start ${AUTO_IMPORT_SERVICE}
EOF

    if [[ "${DEPLOY_MODE}" == "home" ]]; then
        cat <<EOF

Cloudflare Tunnel:
  systemctl status ${CLOUDFLARED_SERVICE} --no-pager
  journalctl -u ${CLOUDFLARED_SERVICE} -f
  Published application: ${DOMAIN} → http://127.0.0.1:${CADDY_ORIGIN_PORT}
EOF
        if (( PUBLIC_ROUTE_OK == 0 )); then
            warn "Публичный hostname пока не проверен. Проверьте Published application в Cloudflare."
        fi
    else
        cat <<EOF

VPS HTTPS:
  TCP 80/443 должны быть открыты снаружи.
  journalctl -u caddy -f
EOF
    fi

    cat <<EOF

Учётные данные:
  ${CREDENTIALS_FILE}

Диагностика:
  sudo bash $0 --diagnose

Ремонт импорта без переустановки:
  sudo bash $0 --repair-import

Удаление с сохранением библиотеки:
  sudo bash $0 --uninstall
EOF

    warn "После обновления очистите cookies ${DOMAIN} для /tags либо откройте /tags в приватном окне."
}

# ------------------------------------------------------------------------------
# Uninstall

# ------------------------------------------------------------------------------
# Uninstall

# ------------------------------------------------------------------------------
# Uninstall
# ------------------------------------------------------------------------------

detect_uninstall_owner() {
    if [[ -r "${INSTALL_STATE_FILE}" ]]; then
        load_install_state
        return
    fi

    warn "Файл состояния не найден; удаляются только каталоги конфигурации Music Cloud."
    set_run_user "root"
    UPLOAD_DIR="${DEFAULT_UPLOAD_DIR}"
    LIBRARY_DIR="${DEFAULT_LIBRARY_DIR}"
}

uninstall_application() {
    require_root
    detect_uninstall_owner

    cat <<EOF

Будут удалены:

  • контейнеры Music Cloud;
  • systemd watcher и timers;
  • конфигурация Caddy и, если использовался, Cloudflare Tunnel service;
  • ${STACK_DIR};
  • изолированные beets-окружение и конфиг Music Cloud.

Не удаляются: SSH, пользователи, Docker/Caddy/cloudflared как пакеты и выбранная
музыкальная библиотека:
  ${LIBRARY_DIR}

Каталог загрузки:
  ${UPLOAD_DIR}

EOF

    ask_yes_no "Удалить контейнеры и конфигурацию?" "n" || die "Операция отменена."

    systemctl disable --now "${AUTO_IMPORT_PATH}" 2>/dev/null || true
    systemctl disable --now "${AUTO_IMPORT_TIMER}" 2>/dev/null || true
    systemctl disable --now "${UPLOAD_WATCH_SERVICE}" 2>/dev/null || true
    systemctl disable --now "${LEGACY_AUTO_IMPORT_WATCH_SERVICE}" 2>/dev/null || true
    systemctl disable --now "${BEETS_UPDATE_TIMER}" 2>/dev/null || true
    systemctl disable --now "${BEETS_WATCH_SERVICE}" 2>/dev/null || true
    systemctl disable --now "${CLOUDFLARED_SERVICE}" 2>/dev/null || true

    rm -f \
        "/etc/systemd/system/${AUTO_IMPORT_PATH}" \
        "/etc/systemd/system/${AUTO_IMPORT_TIMER}" \
        "/etc/systemd/system/${AUTO_IMPORT_SERVICE}" \
        "/etc/systemd/system/${UPLOAD_WATCH_SERVICE}" \
        "/etc/systemd/system/${LEGACY_AUTO_IMPORT_WATCH_SERVICE}" \
        "/etc/systemd/system/${BEETS_UPDATE_TIMER}" \
        "/etc/systemd/system/${BEETS_UPDATE_SERVICE}" \
        "/etc/systemd/system/${BEETS_WATCH_SERVICE}" \
        "/etc/systemd/system/${CLOUDFLARED_SERVICE}" \
        "${DOCKER_STORAGE_DROPIN}"

    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    if [[ -f "${COMPOSE_FILE}" ]] && command -v docker >/dev/null 2>&1; then
        docker compose -f "${COMPOSE_FILE}" down --remove-orphans || true
    fi

    if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "${TAGR_BUILD_SWAP_FILE}"; then
        swapoff "${TAGR_BUILD_SWAP_FILE}" 2>/dev/null || true
    fi
    rm -f "${TAGR_BUILD_SWAP_FILE}"

    rm -f \
        "${AUTO_IMPORT_SCRIPT}" \
        "${UPLOAD_WATCH_SCRIPT}" \
        "${LEGACY_AUTO_IMPORT_WATCH_SCRIPT}" \
        "${DEDUPE_SCRIPT}" \
        "${BEETS_WRAPPER}" \
        "${BEETS_UPDATE_SCRIPT}" \
        "${BEETS_WATCH_SCRIPT}" \
        "${CADDY_SITE_FILE}" \
        "${CREDENTIALS_FILE}"

    rm -rf "${STACK_DIR}" "${STATE_DIR}"

    if command -v caddy >/dev/null 2>&1; then
        caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
        systemctl reload caddy 2>/dev/null || true
    fi

    if ask_yes_no "Удалить только каталог загрузки ${UPLOAD_DIR}?" "n"; then
        rm -rf --one-file-system "${UPLOAD_DIR}"
        ok "Каталог загрузки удалён."
    else
        warn "Каталог загрузки сохранён: ${UPLOAD_DIR}"
    fi

    rmdir "${DATA_DIR}" 2>/dev/null || true

    ok "Music Cloud удалён. Музыкальная библиотека сохранена: ${LIBRARY_DIR}"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

repair_import_automation() {
    require_root

    [[ -r "${INSTALL_STATE_FILE}" ]] ||
        die "Существующая установка не найдена: ${INSTALL_STATE_FILE}"

    load_install_state
    resolve_deployment_mode
    check_os
    install_base_packages
    create_directories

    # Reinstalling beets is intentional: this adds Pillow/ArtResizer, whose
    # absence lets recognition finish but makes fetchart/embedart fail before
    # files are moved from upload into the library.
    install_beets
    write_auto_import
    write_beets_update_timer
    save_install_state

    systemctl start "${AUTO_IMPORT_SERVICE}" || true

    ok "Механизм импорта восстановлен."
    systemctl status "${UPLOAD_WATCH_SERVICE}" --no-pager -l || true
    systemctl status "${AUTO_IMPORT_TIMER}" --no-pager -l || true
    printf '\nПоследние сообщения импорта:\n'
    tail -n 120 "${BEETS_CONFIG_DIR}/auto-import.log" 2>/dev/null || true
    printf '\nЕсли файлы остались, выполните: sudo bash %s --diagnose\n' "$0"
}

main_install() {
    require_root
    detect_run_user
    check_os
    resolve_deployment_mode
    show_intro
    collect_settings

    install_base_packages
    check_network_preflight

    if [[ "${DEPLOY_MODE}" == "home" ]]; then
        check_command_port "${CADDY_ORIGIN_PORT}" "локальный Caddy origin"
        check_command_port "${CLOUDFLARED_METRICS_PORT}" "метрики cloudflared"
    else
        check_command_port 80 "HTTP/Caddy"
        check_command_port 443 "HTTPS/Caddy"
    fi
    check_command_port 4533 "Navidrome"
    check_command_port 3923 "Copyparty"
    check_command_port 3000 "Tagr"

    install_docker
    install_caddy
    if [[ "${DEPLOY_MODE}" == "home" ]]; then
        install_cloudflared
    else
        disable_cloudflared_service
    fi

    create_directories
    save_install_state
    install_beets
    prepare_tagr_source
    write_runtime_secrets_and_configs
    unset TUNNEL_TOKEN
    write_compose
    write_auto_import
    write_beets_update_timer

    configure_firewall
    start_stack
    write_caddy_site
    write_cloudflared_service
    verify_installation

    save_credentials
    print_result
}

parse_arguments "$@"

case "${ACTION}" in
    install)
        main_install
        ;;
    uninstall)
        uninstall_application
        ;;
    diagnose)
        show_install_diagnostics
        ;;
    repair-import)
        repair_import_automation
        ;;
    help)
        cat <<EOF
Usage:
  sudo bash $0 [--mode auto|vps|home]
  sudo bash $0 --repair-import
  sudo bash $0 --diagnose
  sudo bash $0 --uninstall

Mode aliases:
  --vps   --home   --auto
EOF
        ;;
    *)
        die "Неизвестное действие: ${ACTION}"
        ;;
esac
