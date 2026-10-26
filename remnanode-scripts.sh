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
XRAY_SHARE_DIR="/usr/local/share/xray"
GEO_FILES=(geo-zapret.dat ip-zapret.dat)
NODE_PORT=2222
SELFSTEAL_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh"
CF_API="https://api.cloudflare.com/client/v4"
DOCKER_INSTALL_URL="https://get.docker.com"
TRAFFIC_GUARD_INSTALL_URL="https://raw.githubusercontent.com/dotX12/traffic-guard/master/install.sh"
TRAFFIC_GUARD_LISTS=(
    "https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list"
    "https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list"
)
UFW_OPEN_PORTS=(443/tcp 443/udp 4443/tcp 8443/tcp)

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

# ─── Volumes в docker-compose ноды ────────────────────────────────────────────
# Добавляет volume (например /a:/a:ro) в сервис remnanode, если путь ещё не смонтирован.
# Возвращает 0, только если файл изменён (нужен перезапуск ноды)
add_compose_volume() {
    local mapping="$1" host_path="${1%%:*}"
    local compose="${REMNAWAVE_DIR}/docker-compose.yml" backup rc=0

    if [[ ! -f "$compose" ]]; then
        log_warn "$compose не найден, пропускаю добавление volume ${host_path}"
        return 1
    fi
    if grep -Eq "^[[:space:]]*-[[:space:]]*['\"]?${host_path}:" "$compose"; then
        log_info "Volume ${host_path} уже указан в $compose"
        return 1
    fi

    backup=$(mktemp "${compose}.bak.$(date +%Y%m%d%H%M%S).XXXX")
    cp -p "$compose" "$backup"
    log_info "Добавляю volume ${mapping} в $compose (бэкап: $backup)..."

    # Ищем services → remnanode; дописываем элемент в его volumes или создаём volumes в конце сервиса
    awk -v vol="'${mapping}'" '
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
            2) log_warn "volumes сервиса remnanode в inline-формате, добавьте вручную: - ${mapping}" ;;
            3) log_warn "Сервис remnanode не найден в $compose, добавьте вручную: - ${mapping}" ;;
            *) log_warn "docker-compose.yml после изменения невалиден, файл восстановлен из бэкапа" ;;
        esac
        return 1
    fi

    log_info "Volume ${mapping} добавлен"
}

# ─── Geo-файлы ────────────────────────────────────────────────────────────────
# Монтирует geo-файлы в ноду
setup_geo_files() {
    local name changed=0

    for name in "${GEO_FILES[@]}"; do
        add_compose_volume "./${name}:${XRAY_SHARE_DIR}/${name}" && changed=1
    done

    if [[ "$changed" == 1 ]]; then
        restart_remnawave
    fi
}

# ─── Logrotate ────────────────────────────────────────────────────────────────
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

    if add_compose_volume "${REMNANODE_LOG_DIR}:${REMNANODE_LOG_DIR}"; then
        restart_remnawave
    fi

    log_info "Проверка конфигурации logrotate..."
    logrotate -vf "$LOGROTATE_CONF" || log_error "logrotate завершился с ошибкой"

    log_info "Logrotate для remnanode настроен"
}

# ─── Traffic-guard + UFW ──────────────────────────────────────────────────────
setup_firewall() {
    local ssh_ports port panel_ip url tg_args=() i

    if ! command -v ufw >/dev/null; then
        log_info "Установка ufw..."
        apt update -q
        apt install -y -q ufw
    fi

    # SSH открываем первым, чтобы не потерять доступ к серверу
    ssh_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' || true)
    for port in $(printf '%s\n' 22 $ssh_ports | sort -un); do
        log_info "UFW: открываю ${port}/tcp (SSH)"
        ufw allow "${port}/tcp" comment 'SSH' >/dev/null
    done

    if ! command -v traffic-guard >/dev/null; then
        log_info "Установка traffic-guard..."
        curl -fsSL "$TRAFFIC_GUARD_INSTALL_URL" | bash
    fi

    for url in "${TRAFFIC_GUARD_LISTS[@]}"; do
        tg_args+=(-u "$url")
    done
    log_info "Применение списков traffic-guard..."
    traffic-guard full "${tg_args[@]}" || log_error "traffic-guard завершился с ошибкой"

    for port in "${UFW_OPEN_PORTS[@]}"; do
        log_info "UFW: открываю ${port}"
        ufw allow "$port" >/dev/null
    done

    # Порт ноды нужен панели; без него после включения ufw нода станет offline
    read -rp "IP панели для доступа к порту ${NODE_PORT} (пусто — открыть для всех): " panel_ip
    if [[ -n "$panel_ip" ]]; then
        [[ "$panel_ip" =~ ^[0-9a-fA-F.:/]+$ ]] || log_error "Некорректный IP: $panel_ip"
        log_info "UFW: открываю ${NODE_PORT}/tcp только для $panel_ip"
        ufw allow from "$panel_ip" to any port "$NODE_PORT" proto tcp comment 'remnanode' >/dev/null
    else
        log_warn "UFW: открываю ${NODE_PORT}/tcp для всех"
        ufw allow "${NODE_PORT}/tcp" comment 'remnanode' >/dev/null
    fi

    if ! ufw status | grep -q '^Status: active'; then
        log_info "Включение ufw..."
        ufw --force enable
    fi

    ufw status verbose
    log_info "Traffic-guard и UFW настроены"
}

# ─── Очистка диска ────────────────────────────────────────────────────────────
show_disk_usage() {
    local dir
    for dir in / /var /var/log; do
        log_info "Крупнейшие директории в $dir:"
        du -h -x --max-depth=1 "$dir" 2>/dev/null | sort -rh | head -20
    done
}

cleanup_disk() {
    local before after answer f snapname revision

    before=$(df -k --output=avail / | tail -1)
    df -h /
    show_disk_usage

    log_info "Очистка журналов systemd..."
    journalctl --disk-usage
    journalctl --vacuum-size=200M || log_warn "journalctl --vacuum-size завершился с ошибкой"
    journalctl --vacuum-time=3d   || log_warn "journalctl --vacuum-time завершился с ошибкой"

    log_info "Очистка кэша apt и неиспользуемых пакетов..."
    apt clean
    apt autoremove --purge -y || log_warn "apt autoremove завершился с ошибкой"

    if command -v docker >/dev/null; then
        docker system df
        # Удаляет и volumes остановленных контейнеров — данные в них пропадут
        read -rp "Удалить ВСЕ неиспользуемые Docker-образы, контейнеры, сети и volumes? [y/N]: " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            docker system prune -a --volumes -f || log_warn "docker system prune завершился с ошибкой"
        else
            log_info "Пропускаю очистку Docker"
        fi
    fi

    if ! command -v logrotate >/dev/null; then
        log_info "Установка logrotate..."
        apt update -q
        apt install -y -q logrotate
    fi
    log_info "Принудительная ротация логов..."
    # logrotate.conf подключает logrotate.d/ вместе с глобальными настройками (su и т.п.)
    logrotate -vf /etc/logrotate.conf || log_warn "logrotate завершился с ошибкой"

    if command -v snap >/dev/null; then
        log_info "Удаление старых ревизий snap..."
        snap list --all | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
            snap remove "$snapname" --revision="$revision" || log_warn "Не удалось удалить $snapname ($revision)"
        done
    fi

    log_info "Очистка системных логов..."
    for f in /var/log/syslog /var/log/kern.log; do
        if [[ -f "$f" ]]; then
            truncate -s 0 "$f"
        fi
    done
    rm -f /var/log/syslog.*.gz /var/log/kern.log.*.gz /var/log/auth.log.*.gz

    if [[ -d "$REMNANODE_LOG_DIR" ]]; then
        log_info "Удаление логов remnanode старше 7 дней..."
        find "$REMNANODE_LOG_DIR" -type f -mtime +7 -exec ls -lh {} \;
        find "$REMNANODE_LOG_DIR" -type f -mtime +7 -delete
    fi

    after=$(df -k --output=avail / | tail -1)
    df -h /
    log_info "Очистка завершена, освобождено: $(( (after - before) / 1024 )) MB"
}

# ─── Установка ноды ───────────────────────────────────────────────────────────
# Принимает SECRET_KEY как есть, с префиксом SECRET_KEY= и/или в кавычках
read_secret_key() {
    # -e (readline): длинный токен не обрезается лимитом терминала в 4096 символов
    read -erp "Вставьте SECRET_KEY ноды из панели: " SECRET_KEY
    SECRET_KEY=$(printf '%s' "$SECRET_KEY" | tr -d '[:space:]')
    SECRET_KEY="${SECRET_KEY#SECRET_KEY=}"
    SECRET_KEY="${SECRET_KEY//\"/}"
    SECRET_KEY="${SECRET_KEY//\'/}"

    [[ -z "$SECRET_KEY" ]] && log_error "SECRET_KEY не может быть пустым"
    [[ "$SECRET_KEY" =~ ^eyJ[A-Za-z0-9+/=_-]+$ ]] || log_error "SECRET_KEY имеет неверный формат"
    if command -v python3 >/dev/null && ! python3 -c '
import base64, json, sys
s = sys.argv[1]
json.loads(base64.b64decode(s + "=" * (-len(s) % 4)))
' "$SECRET_KEY" 2>/dev/null; then
        log_error "SECRET_KEY не декодируется — вероятно, скопирован не полностью"
    fi
}

install_remnanode() {
    local compose="${REMNAWAVE_DIR}/docker-compose.yml" backup

    read_secret_key

    if ! command -v docker >/dev/null; then
        log_info "Установка Docker..."
        curl -fsSL "$DOCKER_INSTALL_URL" | sh
    fi

    mkdir -p "$REMNAWAVE_DIR"

    if [[ -f "$compose" ]]; then
        # Не перезаписываем файл целиком, чтобы сохранить добавленные volumes
        grep -q 'SECRET_KEY=' "$compose" || log_error "В $compose нет SECRET_KEY, обновите его вручную"
        backup=$(mktemp "${compose}.bak.$(date +%Y%m%d%H%M%S).XXXX")
        cp -p "$compose" "$backup"
        log_info "$compose уже существует, обновляю только SECRET_KEY (бэкап: $backup)..."
        sed -i -E "s|^([[:space:]]*-[[:space:]]*)SECRET_KEY=.*|\1SECRET_KEY=\"${SECRET_KEY}\"|" "$compose"
    else
        log_info "Создание $compose..."
        cat > "$compose" << EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=${NODE_PORT}
      - SECRET_KEY="${SECRET_KEY}"
EOF
    fi
    chmod 600 "$compose"

    log_info "Запуск remnanode..."
    (cd "$REMNAWAVE_DIR" && docker compose up -d)
    sleep 5
    (cd "$REMNAWAVE_DIR" && docker compose logs -t --tail 30)

    log_info "Нода запущена. Логи в реальном времени: cd ${REMNAWAVE_DIR} && docker compose logs -f -t"
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
    add_compose_volume "${XRAY_SSL_DIR}:${XRAY_SSL_DIR}:ro" || true
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
    echo "1) Установить remnanode (Docker + docker-compose.yml + запуск)"
    echo "2) Выпустить сертификат для домена (DNS + certbot + selfsteal + volume + перезапуск)"
    echo "3) Настроить logrotate для remnanode"
    echo "4) Подключить geo-файлы (geo-zapret.dat, ip-zapret.dat) к ноде"
    echo "5) Спрятать от сканеров и открыть порты (traffic-guard + ufw)"
    echo "6) Очистить диск (журналы, apt, docker, логи)"
    echo
    echo "9) Указать Cloudflare авторизацию (email + API Token)"
    echo "0) Выход"
    read -rp "Выберите действие [0-6, 9]: " choice

    case "$choice" in
        1) install_remnanode ;;
        2) run_issue ;;
        3) setup_logrotate ;;
        4) setup_geo_files ;;
        5) setup_firewall ;;
        6) cleanup_disk ;;
        9) run_auth ;;
        0) exit 0 ;;
        *) log_warn "Неверный выбор" ;;
    esac
done
