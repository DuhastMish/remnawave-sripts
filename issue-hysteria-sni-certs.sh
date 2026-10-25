#!/bin/bash
set -e

# ─── Цвета ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ─── Пути ────────────────────────────────────────────────────────────────────
SECRETS_DIR="/etc/letsencrypt/secrets"
CF_CREDS_FILE="${SECRETS_DIR}/cloudflare.ini"
LE_EMAIL_FILE="${SECRETS_DIR}/le-email"
XRAY_SSL_DIR="/etc/xray/ssl"
REMNAWAVE_DIR="/opt/remnanode"
REMNANODE_LOG_DIR="/var/log/remnanode"
LOGROTATE_CONF="/etc/logrotate.d/remnanode"
SELFSTEAL_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh"
CF_API="https://api.cloudflare.com/client/v4"

# ─── Проверка root ────────────────────────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && log_error "Скрипт должен запускаться от root"

# ─── Зависимости ─────────────────────────────────────────────────────────────
install_deps() {
    if command -v certbot >/dev/null && command -v jq >/dev/null \
        && dpkg -s python3-certbot-dns-cloudflare >/dev/null 2>&1; then
        return
    fi
    log_info "Установка зависимостей..."
    apt update -q
    apt install -y -q certbot python3-certbot-dns-cloudflare jq curl
}

# ─── Cloudflare API ───────────────────────────────────────────────────────────
cf_api() {
    local method="$1" path="$2" data="$3"
    curl -s -X "$method" "${CF_API}${path}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        ${data:+--data "$data"}
}

# ─── Credentials ──────────────────────────────────────────────────────────────
load_creds() {
    CF_API_TOKEN=""
    LE_EMAIL=""
    [[ -f "$CF_CREDS_FILE" ]] && CF_API_TOKEN=$(sed -n 's/^dns_cloudflare_api_token *= *//p' "$CF_CREDS_FILE")
    [[ -f "$LE_EMAIL_FILE" ]] && LE_EMAIL=$(cat "$LE_EMAIL_FILE")
    return 0
}

save_creds() {
    mkdir -p "$SECRETS_DIR"
    echo "dns_cloudflare_api_token = ${CF_API_TOKEN}" > "$CF_CREDS_FILE"
    echo "$LE_EMAIL" > "$LE_EMAIL_FILE"
    chmod 600 "$CF_CREDS_FILE" "$LE_EMAIL_FILE"
    log_info "Credentials сохранены в $SECRETS_DIR"
}

verify_token() {
    local status
    status=$(cf_api GET "/user/tokens/verify" | jq -r '.result.status // empty')
    [[ "$status" == "active" ]] || log_error "Cloudflare API Token невалиден или неактивен"
}

# Запрашивает только недостающие данные; force=1 — запросить всё заново
ask_creds() {
    local force="$1"
    if [[ "$force" == 1 || -z "$LE_EMAIL" ]]; then
        read -rp "Введите email для Let's Encrypt: " LE_EMAIL
        [[ -z "$LE_EMAIL" ]] && log_error "Email не может быть пустым"
    fi
    if [[ "$force" == 1 || -z "$CF_API_TOKEN" ]]; then
        read -rsp "Введите Cloudflare API Token (Zone:DNS:Edit + Zone:Zone:Read): " CF_API_TOKEN
        echo
        [[ -z "$CF_API_TOKEN" ]] && log_error "Cloudflare API Token не может быть пустым"
    fi
    verify_token
    save_creds
}

# ─── IP сервера ───────────────────────────────────────────────────────────────
detect_ip() {
    local url ip
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me; do
        ip=$(curl -4 -s --max-time 5 "$url" | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            echo "$ip"
            return
        fi
    done
}

# ─── DNS: A-запись на текущий VPS ─────────────────────────────────────────────
update_dns() {
    local candidate="$DOMAIN" zone_id="" records id

    # Ищем ID зоны (только чтение): a.b.example.com → b.example.com → example.com
    while [[ "$candidate" == *.* ]]; do
        zone_id=$(cf_api GET "/zones?name=${candidate}" | jq -r '.result[0].id // empty')
        [[ -n "$zone_id" ]] && break
        candidate="${candidate#*.}"
    done
    [[ -z "$zone_id" ]] && log_error "Зона для $DOMAIN не найдена в Cloudflare (проверьте права токена)"
    [[ "$candidate" == "$DOMAIN" ]] && log_error "$DOMAIN — корневой домен зоны. Скрипт работает только с поддоменами"
    log_info "Зона Cloudflare: $candidate"

    # Удаляем старые A (и мешающие CNAME) записи — только с точным именем поддомена
    records=$(cf_api GET "/zones/${zone_id}/dns_records?name=${DOMAIN}&per_page=100" \
        | jq -r --arg name "$DOMAIN" \
            '.result[] | select(.name == $name and (.type == "A" or .type == "CNAME")) | "\(.id) \(.type) \(.content)"')
    while read -r id type content; do
        [[ -z "$id" ]] && continue
        log_warn "Удаляю $type $DOMAIN → $content"
        cf_api DELETE "/zones/${zone_id}/dns_records/${id}" | jq -e '.success' >/dev/null \
            || log_error "Не удалось удалить запись $id"
    done <<< "$records"

    # Создаём новую A-запись (без проксирования — нужен прямой TLS до VPS)
    log_info "Создаю A $DOMAIN → $SERVER_IP"
    cf_api POST "/zones/${zone_id}/dns_records" \
        "{\"type\":\"A\",\"name\":\"${DOMAIN}\",\"content\":\"${SERVER_IP}\",\"ttl\":60,\"proxied\":false}" \
        | jq -e '.success' >/dev/null || log_error "Не удалось создать A-запись"
}

# ─── Сертификат ───────────────────────────────────────────────────────────────
issue_cert() {
    log_info "Получение сертификата для домена: $DOMAIN"
    certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials "$CF_CREDS_FILE" \
        --dns-cloudflare-propagation-seconds 30 \
        -d "$DOMAIN" \
        --keep-until-expiring \
        --agree-tos \
        -m "$LE_EMAIL" \
        --non-interactive

    log_info "Копирование сертификатов в $XRAY_SSL_DIR..."
    mkdir -p "$XRAY_SSL_DIR"
    cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${XRAY_SSL_DIR}/cert.pem"
    cp "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"   "${XRAY_SSL_DIR}/cert.key"
    chmod 644 "${XRAY_SSL_DIR}/cert.pem"
    chmod 600 "${XRAY_SSL_DIR}/cert.key"

    log_info "Создание post-renewal hook для автоматического обновления..."
    mkdir -p /etc/letsencrypt/renewal-hooks/post
    cat > /etc/letsencrypt/renewal-hooks/post/copy-to-xray.sh << EOF
#!/bin/bash
cp /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ${XRAY_SSL_DIR}/cert.pem
cp /etc/letsencrypt/live/${DOMAIN}/privkey.pem   ${XRAY_SSL_DIR}/cert.key
chmod 644 ${XRAY_SSL_DIR}/cert.pem
chmod 600 ${XRAY_SSL_DIR}/cert.key
EOF
    chmod +x /etc/letsencrypt/renewal-hooks/post/copy-to-xray.sh
}

# ─── Selfsteal ────────────────────────────────────────────────────────────────
install_selfsteal() {
    log_info "Установка selfsteal для $DOMAIN..."
    bash <(curl -Ls "$SELFSTEAL_URL") @ install \
        --force \
        --domain "$DOMAIN" \
        --ssl-cert "${XRAY_SSL_DIR}/cert.pem" \
        --ssl-key "${XRAY_SSL_DIR}/cert.key"
}

# ─── Перезапуск remnawave ─────────────────────────────────────────────────────
restart_remnawave() {
    if [[ ! -f "${REMNAWAVE_DIR}/docker-compose.yml" ]]; then
        log_warn "${REMNAWAVE_DIR}/docker-compose.yml не найден, пропускаю перезапуск"
        return
    fi
    log_info "Перезапуск remnawave..."
    (cd "$REMNAWAVE_DIR" && docker compose down && docker compose up -d)
}

# ─── Logrotate ────────────────────────────────────────────────────────────────
# Добавляет volume с логами в сервис remnanode, если его там нет
add_log_volume() {
    local compose="${REMNAWAVE_DIR}/docker-compose.yml" backup rc=0

    if [[ ! -f "$compose" ]]; then
        log_warn "$compose не найден, пропускаю добавление volume для логов"
        return
    fi
    if grep -Eq "^[[:space:]]*-[[:space:]]*['\"]?${REMNANODE_LOG_DIR}:" "$compose"; then
        log_info "Volume ${REMNANODE_LOG_DIR} уже указан в $compose"
        return
    fi

    backup="${compose}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$compose" "$backup"
    log_info "Добавляю volume ${REMNANODE_LOG_DIR} в $compose (бэкап: $backup)..."

    # Ищем services → remnanode; дописываем элемент в его volumes или создаём volumes в конце сервиса
    awk -v vol="'${REMNANODE_LOG_DIR}:${REMNANODE_LOG_DIR}'" '
        function pad(n,   s) { s = ""; while (n-- > 0) s = s " "; return s }
        {
            ind = ($0 ~ /^[[:space:]]*(#.*)?$/) ? -1 : match($0, /[^ ]/) - 1
            if (ind == 0) top = $1

            if (state == "svc" && ind >= 0 && ind <= svc_ind) {
                print pad(key_ind) "volumes:"; print pad(key_ind + 2) "- " vol; state = "done"
            }
            if (state == "vols" && ind >= 0) {
                item_ind = ($0 ~ /^[[:space:]]*- /) ? ind : key_ind + 2
                print pad(item_ind) "- " vol; state = "done"
            }
            print

            if (state == "" && top == "services:" && ind > 0 && $0 ~ /^[[:space:]]+remnanode:[[:space:]]*$/) {
                state = "svc"; svc_ind = ind; key_ind = -1; next
            }
            if (state == "svc" && ind > svc_ind) {
                if (key_ind < 0) key_ind = ind
                if (ind == key_ind && $0 ~ /^[[:space:]]*volumes:/) {
                    if ($0 !~ /^[[:space:]]*volumes:[[:space:]]*(#.*)?$/) exit 2
                    state = "vols"
                }
            }
        }
        END {
            if (state == "svc")  { print pad(key_ind) "volumes:"; print pad(key_ind + 2) "- " vol }
            if (state == "vols") { print pad(key_ind + 2) "- " vol }
            if (state == "")     exit 3
        }
    ' "$backup" > "$compose" || rc=$?

    if [[ "$rc" -eq 0 ]] && ! (cd "$REMNAWAVE_DIR" && docker compose config -q); then
        rc=1
    fi
    if [[ "$rc" -ne 0 ]]; then
        mv "$backup" "$compose"
        case "$rc" in
            2) log_warn "volumes сервиса remnanode в inline-формате, добавьте вручную: - ${REMNANODE_LOG_DIR}:${REMNANODE_LOG_DIR}" ;;
            3) log_warn "Сервис remnanode не найден в $compose, добавьте volume вручную" ;;
            *) log_warn "docker-compose.yml после изменения невалиден, файл восстановлен из бэкапа" ;;
        esac
        return
    fi

    log_info "Volume добавлен"
    restart_remnawave
}

setup_logrotate() {
    log_info "Создание $REMNANODE_LOG_DIR..."
    mkdir -p "$REMNANODE_LOG_DIR"

    if ! command -v logrotate >/dev/null; then
        log_info "Установка logrotate..."
        apt update -q
        apt install -y -q logrotate
    fi

    log_info "Создание конфигурации $LOGROTATE_CONF..."
    cat > "$LOGROTATE_CONF" << EOF
${REMNANODE_LOG_DIR}/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF
    chmod 644 "$LOGROTATE_CONF"

    add_log_volume

    log_info "Проверка конфигурации logrotate..."
    logrotate -vf "$LOGROTATE_CONF" || log_error "logrotate завершился с ошибкой"

    log_info "Logrotate для remnanode настроен"
}

# ─── Сценарии ─────────────────────────────────────────────────────────────────
run_issue() {
    read -rp "Введите домен (например sni.example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && log_error "Домен не может быть пустым"

    install_deps
    load_creds
    if [[ -z "$CF_API_TOKEN" || -z "$LE_EMAIL" ]]; then
        log_warn "Cloudflare credentials не найдены, введите их"
        ask_creds 0
    else
        verify_token
        log_info "Используются сохранённые credentials ($LE_EMAIL)"
    fi

    SERVER_IP=$(detect_ip)
    if [[ -z "$SERVER_IP" ]]; then
        read -rp "Не удалось определить IP. Введите IP сервера: " SERVER_IP
        [[ -z "$SERVER_IP" ]] && log_error "IP не может быть пустым"
    fi
    log_info "IP сервера: $SERVER_IP"

    update_dns
    issue_cert
    install_selfsteal
    restart_remnawave

    echo
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Готово!${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "  Домен:       ${YELLOW}${DOMAIN} → ${SERVER_IP}${NC}"
    echo -e "  Сертификат:  ${YELLOW}${XRAY_SSL_DIR}/cert.pem${NC}"
    echo -e "  Ключ:        ${YELLOW}${XRAY_SSL_DIR}/cert.key${NC}"
    echo -e "  Обновление:  ${YELLOW}автоматически через certbot renew${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
}

run_auth() {
    install_deps
    load_creds
    ask_creds 1
}

# ─── Меню ─────────────────────────────────────────────────────────────────────
while true; do
    echo
    echo "1) Выпустить сертификат для домена (DNS + certbot + selfsteal + перезапуск)"
    echo "2) Указать Cloudflare авторизацию (email + API Token)"
    echo "3) Настроить logrotate для remnanode"
    echo "0) Выход"
    read -rp "Выберите действие [0-3]: " choice

    case "$choice" in
        1) run_issue ;;
        2) run_auth ;;
        3) setup_logrotate ;;
        0) exit 0 ;;
        *) log_warn "Неверный выбор" ;;
    esac
done
