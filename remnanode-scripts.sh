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
# Каталоги и контейнеры, которые создаёт selfsteal (Caddy — по умолчанию, nginx — с --nginx)
SELFSTEAL_CADDY_DIR="/opt/caddy"
SELFSTEAL_CADDY_CONTAINER="caddy-selfsteal"
SELFSTEAL_NGINX_DIR="/opt/nginx-selfsteal"
SELFSTEAL_DEFAULT_PORT=9443
CF_API="https://api.cloudflare.com/client/v4"
DOCKER_INSTALL_URL="https://get.docker.com"
TRAFFIC_GUARD_INSTALL_URL="https://raw.githubusercontent.com/dotX12/traffic-guard/master/install.sh"
TRAFFIC_GUARD_LISTS=(
    "https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list"
    "https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list"
)
UFW_OPEN_PORTS=(443/tcp 443/udp 4443/tcp 8443/tcp)
NGINX_CONF="/etc/nginx/nginx.conf"
CASCADE_STREAM_CONF="/etc/nginx/cascade-stream.conf"
CASCADE_EXITS_FILE="/etc/nginx/cascade-exits.list"
CASCADE_ENTRY_FILE="/etc/nginx/cascade-entry.domain"
# IP выходов узнаёт таймер (раз в минуту), а не nginx при каждом подключении:
# сбой DNS не рвёт сессии, при нём остаются прежние адреса
CASCADE_ENV_FILE="/etc/nginx/cascade.env"
CASCADE_STATE_FILE="/etc/nginx/cascade-exits.state"
CASCADE_REFRESH_BIN="/usr/local/sbin/cascade-refresh"
CASCADE_REFRESH_UNIT="cascade-refresh"
CASCADE_ABSENT_LIMIT=5                    # проверок подряд без A-записи, после которых выход исключается
CASCADE_DEFAULT_PORTS="443 8443"
CASCADE_CONNECT_TIMEOUT="4s"
# Лимиты входа считаются от размера сервера (cascade_compute_limits).
# Сессия stream занимает 2 соединения (клиент + выход); при исчерпании worker_connections
# новые соединения не принимаются у всех пользователей входа
CASCADE_MIN_WORKER_CONNECTIONS=16384
CASCADE_MAX_WORKER_CONNECTIONS=64000      # с запасом под worker_rlimit_nofile 65535
CASCADE_RLIMIT_NOFILE=65535
CASCADE_RAM_RESERVE_MB=512                # системе, nginx и прочему, не под сессии
CASCADE_SESSION_KB=64                     # память на сессию: буферы nginx 2×8k + сокеты ядра, с запасом
CASCADE_PORTS_SYSCTL_CONF="/etc/sysctl.d/92-cascade.conf"
# Буфер на каждое направление сессии (по умолчанию 16k): вдвое меньше памяти на сессию
CASCADE_PROXY_BUFFER="8k"
# Очередь ещё не принятых подключений на каждый воркер (reuseport); по умолчанию в nginx 511
CASCADE_LISTEN_BACKLOG=4096
# UDP-пересылка Hysteria2 по умолчанию: UDP 443 до входа режется, поэтому отдельный порт
CASCADE_UDP_DEFAULT_PORT=4443
CASCADE_UDP_DEFAULT_DOMAIN="sub.example.com"
NGINX_ERROR_LOG="/var/log/nginx/error.log"
# Отдельная папка: /var/log/nginx/*.log уже ротирует пакет nginx, второй конфиг дал бы duplicate log entry
CASCADE_LOG_DIR="/var/log/cascade"
CASCADE_LOG="${CASCADE_LOG_DIR}/cascade.log"
CASCADE_LOGROTATE_CONF="/etc/logrotate.d/cascade"
BBR_SYSCTL_CONF="/etc/sysctl.d/90-bbr.conf"
BBR_MODULES_CONF="/etc/modules-load.d/bbr.conf"
CONNTRACK_SYSCTL_CONF="/etc/sysctl.d/91-conntrack.conf"
CONNTRACK_MODULES_CONF="/etc/modules-load.d/nf_conntrack.conf"
CONNTRACK_MODPROBE_CONF="/etc/modprobe.d/nf_conntrack.conf"
CONNTRACK_MAX=262144

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

ensure_server_ip() {
    SERVER_IP=$(detect_ip)
    if [[ -z "$SERVER_IP" ]]; then
        read -rp "Не удалось определить IP. Введите IP сервера: " SERVER_IP
        [[ -z "$SERVER_IP" ]] && log_error "IP не может быть пустым"
    fi
    log_info "IP сервера: $SERVER_IP"
}

ensure_cf_creds() {
    load_creds
    if [[ -z "$CF_API_TOKEN" || -z "$LE_EMAIL" ]]; then
        log_warn "Cloudflare credentials не найдены, введите их"
        ask_creds 0
    else
        verify_token
        log_info "Используются сохранённые credentials ($LE_EMAIL)"
    fi
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

    # Старые A/AAAA (и мешающие CNAME) записи — только с точным именем поддомена.
    # Иначе имя резолвится сразу в несколько адресов, включая старый сервер
    records=$(cf_api GET "/zones/${zone_id}/dns_records?name=${DOMAIN}&per_page=100" \
        | jq -r --arg name "$DOMAIN" \
            '.result[] | select(.name == $name and (.type == "A" or .type == "AAAA" or .type == "CNAME")) | "\(.id) \(.type) \(.content)"')

    if [[ "$records" =~ ^[^[:space:]]+\ A\ ${SERVER_IP//./\\.}$ ]]; then
        log_info "A $DOMAIN → $SERVER_IP уже указана, других записей нет"
        return
    fi

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
# Разбирает "a.example.com, B.example.com,a.example.com" в DOMAINS: без пробелов, в нижнем
# регистре, без дублей. Первый — основной (DOMAIN), остальные — дополнительные (EXTRA_DOMAINS)
parse_domains() {
    local d parts=()
    DOMAINS=()
    # read -ra, а не for in $(...): иначе "*.example.com" раскрылся бы в имена файлов
    read -ra parts <<< "$(tr ',;' '  ' <<< "$1" | tr '[:upper:]' '[:lower:]')"
    for d in "${parts[@]}"; do
        d="${d%.}"
        (( ${#d} <= 253 )) && [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$ ]] \
            || log_error "Некорректный домен: $d"
        [[ " ${DOMAINS[*]} " == *" $d "* ]] || DOMAINS+=("$d")
    done
    (( ${#DOMAINS[@]} > 0 )) || log_error "Домен не может быть пустым"
    DOMAIN="${DOMAINS[0]}"
    EXTRA_DOMAINS=("${DOMAINS[@]:1}")
}

issue_cert() {
    local args=() d
    for d in "${DOMAINS[@]}"; do args+=(-d "$d"); done

    log_info "Получение сертификата: основной $DOMAIN${EXTRA_DOMAINS[*]:+, дополнительные: ${EXTRA_DOMAINS[*]}}"
    # --cert-name держит сертификат в live/<основной>; --expand добавляет новые имена
    # в существующий сертификат, а не создаёт второй
    certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials "$CF_CREDS_FILE" \
        --dns-cloudflare-propagation-seconds 30 \
        --cert-name "$DOMAIN" \
        "${args[@]}" \
        --expand \
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

# Отдаёт ли сайт на $1 (host:port) для SNI $2 именно наш сертификат.
# Простого ответа мало: на неизвестное имя Caddy отвечает своим самоподписанным (tls internal)
selfsteal_serves_our_cert() {
    local want got
    want=$(openssl x509 -in "${XRAY_SSL_DIR}/cert.pem" -noout -fingerprint -sha256 2>/dev/null)
    got=$(timeout 8 openssl s_client -connect "$1" -servername "$2" </dev/null 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null)
    [[ -n "$got" && "$got" == "$want" ]]
}

# Код HTTP-ответа сайта selfsteal на $1 (host:port) для имени $2
selfsteal_http_code() {
    curl -sk -o /dev/null -w '%{http_code}' --max-time 8 \
        --resolve "${2}:${1##*:}:${1%:*}" "https://${2}:${1##*:}/" 2>/dev/null
}

# Имя обслуживает сайт: наш сертификат и тот же ответ, что у основного домена ($3).
# Сертификата мало: Caddy подбирает его по SAN для любого имени, но без своего сайта
# запрос уходит в общий блок «:порт { respond 204 }» — пустой ответ вместо сайта
selfsteal_serves_name() {
    selfsteal_serves_our_cert "$1" "$2" && [[ "$(selfsteal_http_code "$1" "$2")" == "$3" ]]
}

# selfsteal принимает только один --domain. В Caddy дополнительные имена добавляются в адрес
# сайта через запятую: https://{$SELF_STEAL_DOMAIN}, https://доп {. Повторный запуск
# пересобирает строку заново, поэтому дублей не будет
add_selfsteal_caddy_names() {
    local caddyfile="${SELFSTEAL_CADDY_DIR}/Caddyfile" line backup tmp n matches
    local site_re='^https://\{\$SELF_STEAL_DOMAIN\}(, https://[^ ,{]+)* \{$'

    if [[ ! -f "$caddyfile" ]]; then
        if [[ -d "$SELFSTEAL_NGINX_DIR" ]]; then
            log_warn "selfsteal работает на nginx (сокет + proxy_protocol) — автоматически добавить имена нельзя."
            log_warn "Добавьте их вручную в server_name в ${SELFSTEAL_NGINX_DIR}/conf.d/selfsteal.conf"
        else
            log_warn "$caddyfile не найден — не могу добавить дополнительные имена в selfsteal"
        fi
        return 1
    fi

    matches=$(grep -cE "$site_re" "$caddyfile" || true)
    if [[ "$matches" != 1 ]]; then
        log_warn "В $caddyfile не найден ожидаемый адрес сайта https://{\$SELF_STEAL_DOMAIN} — формат selfsteal изменился, конфиг не трогаю"
        return 1
    fi

    line='https://{$SELF_STEAL_DOMAIN}'
    for n in "${EXTRA_DOMAINS[@]}"; do line+=", https://${n}"; done
    line+=' {'

    backup=$(mktemp "${caddyfile}.bak.$(date +%Y%m%d%H%M%S).XXXX")
    cp -p "$caddyfile" "$backup"
    tmp=$(mktemp)
    # Через ENVIRON: awk -v превратил бы \$ в якорь $
    SITE_RE="$site_re" NEW_LINE="$line" awk '$0 ~ ENVIRON["SITE_RE"] { print ENVIRON["NEW_LINE"]; next } { print }' \
        "$caddyfile" > "$tmp"
    # Caddyfile примонтирован в контейнер отдельным файлом: пишем поверх, сохраняя inode,
    # иначе контейнер продолжит видеть старое содержимое
    cat "$tmp" > "$caddyfile"
    rm -f "$tmp"
    log_info "Добавляю в Caddyfile selfsteal имена: ${EXTRA_DOMAINS[*]} (бэкап: $backup)"

    if ! docker exec "$SELFSTEAL_CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
        cat "$backup" > "$caddyfile"
        log_warn "Caddy не принял изменённый Caddyfile (или контейнер $SELFSTEAL_CADDY_CONTAINER не запущен) — конфиг восстановлен из бэкапа"
        return 1
    fi
    rm -f "$backup"

    docker restart "$SELFSTEAL_CADDY_CONTAINER" >/dev/null \
        || { log_warn "Не удалось перезапустить $SELFSTEAL_CADDY_CONTAINER"; return 1; }
}

# Отдаёт ли selfsteal сайт на дополнительные имена так же, как на основной; если нет — добавляет их в Caddy
check_selfsteal_names() {
    local port addr ref n i missing=()

    port=$(sed -n 's/^SELF_STEAL_PORT=//p' "${SELFSTEAL_CADDY_DIR}/.env" 2>/dev/null)
    addr="127.0.0.1:${port:-$SELFSTEAL_DEFAULT_PORT}"

    ref=$(selfsteal_http_code "$addr" "$DOMAIN")
    if ! selfsteal_serves_our_cert "$addr" "$DOMAIN" || [[ -z "$ref" || "$ref" == 000 ]]; then
        log_warn "selfsteal на $addr не отвечает на основной домен $DOMAIN — проверку доп. имён пропускаю"
        return 0
    fi

    for n in "${EXTRA_DOMAINS[@]}"; do
        selfsteal_serves_name "$addr" "$n" "$ref" || missing+=("$n")
    done
    if (( ${#missing[@]} == 0 )); then
        log_info "selfsteal на $addr отдаёт сайт для всех дополнительных имён"
        return 0
    fi

    log_info "selfsteal не отдаёт сайт (наш сертификат и ответ $ref) для: ${missing[*]}"
    add_selfsteal_caddy_names || return 0

    for n in "${missing[@]}"; do
        for i in $(seq 15); do
            ref=$(selfsteal_http_code "$addr" "$DOMAIN")
            selfsteal_serves_name "$addr" "$n" "$ref" && break
            sleep 1
        done
        if selfsteal_serves_name "$addr" "$n" "$ref"; then
            log_info "selfsteal: $n — OK"
        else
            log_warn "selfsteal по-прежнему не отдаёт сайт для $n"
        fi
    done
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
ensure_logrotate() {
    if ! command -v logrotate >/dev/null; then
        log_info "Установка logrotate..."
        apt update -q
        apt install -y -q logrotate
    fi
}

# Один файл в двух конфигах logrotate — ошибка, из-за которой ротация этих логов не идёт
check_logrotate_conflicts() {
    local dups
    dups=$(logrotate -d /etc/logrotate.conf 2>&1 | grep -i 'duplicate log entry' || true)
    if [[ -n "$dups" ]]; then
        echo "$dups"
        log_error "Найдены пересекающиеся конфиги logrotate, исправьте их"
    fi
}

setup_logrotate() {
    log_info "Создание $REMNANODE_LOG_DIR..."
    mkdir -p "$REMNANODE_LOG_DIR"

    ensure_logrotate

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
    check_logrotate_conflicts
    logrotate -vf "$LOGROTATE_CONF" || log_error "logrotate завершился с ошибкой"

    log_info "Logrotate для remnanode настроен"
}

# ─── Traffic-guard + UFW ──────────────────────────────────────────────────────
# Ставит ufw и открывает SSH (22 и фактический порт sshd), чтобы не потерять доступ
ufw_allow_ssh() {
    local ssh_ports port

    if ! command -v ufw >/dev/null; then
        log_info "Установка ufw..."
        apt update -q
        apt install -y -q ufw
    fi

    ssh_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' || true)
    for port in $(printf '%s\n' 22 $ssh_ports | sort -un); do
        log_info "UFW: открываю ${port}/tcp (SSH)"
        ufw allow "${port}/tcp" comment 'SSH' >/dev/null
    done
}

setup_firewall() {
    local port panel_ip url tg_args=() i

    ufw_allow_ssh

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
    tune_conntrack

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

    ensure_logrotate
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

# ─── Conntrack ────────────────────────────────────────────────────────────────
# ufw отслеживает каждое соединение. При заполнении таблицы ядро молча отбрасывает новые
# соединения (dmesg: "nf_conntrack: table full"). По умолчанию пропавшее соединение живёт
# в таблице 5 суток, а TIME_WAIT — 2 минуты, поэтому на прокси таблица забивается за часы
# Необязательный аргумент — желаемый лимит (по умолчанию CONNTRACK_MAX); текущий больший не уменьшается
tune_conntrack() {
    local current max want="${1:-$CONNTRACK_MAX}"

    modprobe nf_conntrack 2>/dev/null || true
    current=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || true)
    if [[ -z "$current" ]]; then
        log_info "conntrack не используется, пропускаю настройку"
        return
    fi
    max=$(( current > want ? current : want ))

    log_info "Настройка conntrack: лимит ${current} → ${max}, укороченные таймауты..."
    # Модуль грузится до применения sysctl.d, иначе после перезагрузки настройки не применятся
    echo "nf_conntrack" > "$CONNTRACK_MODULES_CONF"
    echo "options nf_conntrack hashsize=$(( max / 4 ))" > "$CONNTRACK_MODPROBE_CONF"
    # established 1 ч: больше proxy_timeout nginx (30 мин) и idle xray (5 мин), живые соединения не рвутся
    cat > "$CONNTRACK_SYSCTL_CONF" << EOF
net.netfilter.nf_conntrack_max = ${max}
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30
# Закрытие соединения — стандартные значения: медленные (мобильные) клиенты и выходы досылают
# FIN и данные позже 30 с, и при коротких таймаутах ufw выбрасывает эти «хвосты»
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
# Не считать INVALID пакеты вне отслеживаемого TCP-окна (перестановки, повторы на больших потоках):
# иначе ufw выбрасывает данные живых сессий (ctstate INVALID → DROP)
net.netfilter.nf_conntrack_tcp_be_liberal = 1
EOF
    chmod 644 "$CONNTRACK_SYSCTL_CONF" "$CONNTRACK_MODULES_CONF" "$CONNTRACK_MODPROBE_CONF"

    echo $(( max / 4 )) > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
    sysctl -q -p "$CONNTRACK_SYSCTL_CONF" || log_warn "sysctl conntrack применился не полностью"

    log_info "conntrack: занято $(sysctl -n net.netfilter.nf_conntrack_count) из $(sysctl -n net.netfilter.nf_conntrack_max)"
    if dmesg 2>/dev/null | grep -q 'nf_conntrack: table full'; then
        log_warn "В dmesg есть 'table full' — таблица переполнялась до настройки. Повторится — проверьте: dmesg -T | grep conntrack"
    fi
}

# ─── BBR ──────────────────────────────────────────────────────────────────────
setup_bbr() {
    local cc qdisc mtu

    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    mtu=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || true)
    log_info "Сейчас: congestion control = ${cc:-?}, qdisc = ${qdisc:-?}, mtu_probing = ${mtu:-?}"

    if [[ "$cc" == bbr && "$qdisc" == fq && "$mtu" == 1 && -f "$BBR_SYSCTL_CONF" ]]; then
        log_info "BBR и MTU probing уже включены"
        return
    fi

    modprobe tcp_bbr 2>/dev/null || true
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        log_error "Ядро $(uname -r) не поддерживает BBR (нужно ядро 4.9+, на OpenVZ/LXC модуль ядра не загрузить)"
    fi

    log_info "Запись $BBR_SYSCTL_CONF..."
    echo "tcp_bbr" > "$BBR_MODULES_CONF"
    cat > "$BBR_SYSCTL_CONF" << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# ICMP "слишком большой пакет" часто режут (ТСПУ, мобильные сети): без этого соединение
# зависает на крупных пакетах, а TCP с probing сам находит рабочий размер
net.ipv4.tcp_mtu_probing = 1
EOF
    chmod 644 "$BBR_SYSCTL_CONF" "$BBR_MODULES_CONF"

    sysctl -q -p "$BBR_SYSCTL_CONF" || log_warn "sysctl применился не полностью"

    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    if [[ "$cc" != bbr ]]; then
        rm -f "$BBR_SYSCTL_CONF" "$BBR_MODULES_CONF"
        log_error "BBR не включился (congestion control = ${cc:-?}), настройки удалены"
    fi

    # default_qdisc действует на новые интерфейсы; BBR и без fq работает (своя пейсинг-логика ядра 4.13+)
    log_info "BBR включён для новых соединений. qdisc fq применится к интерфейсам после перезагрузки"
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

# ─── Каскад: РФ-вход (nginx stream + ssl_preread) ─────────────────────────────
# Читает домены выходов: каждый домен — это SNI выхода и A-запись на его IP
read_cascade_exits() {
    local saved="" input d
    [[ -f "$CASCADE_ENTRY_FILE" ]] && saved=$(cat "$CASCADE_ENTRY_FILE")

    # На этот домен ссылаются хосты в панели; при переезде входа меняется только его A-запись
    read -rp "Домен входа (например ru-1.example.com)${saved:+ [$saved]}: " input
    CASCADE_ENTRY=$(echo "${input:-$saved}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    [[ "$CASCADE_ENTRY" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
        || log_error "Некорректный домен входа: ${CASCADE_ENTRY:-пусто}"

    saved=""
    [[ -f "$CASCADE_EXITS_FILE" ]] && saved=$(tr '\n' ' ' < "$CASCADE_EXITS_FILE" | sed 's/ *$//')

    echo "Домены выходов через запятую или пробел (например sub-1.example.com,sub-2.example.com)"
    read -rp "Выходы${saved:+ [$saved]}: " input
    input="${input:-$saved}"
    [[ -z "$input" ]] && log_error "Список выходов не может быть пустым"

    CASCADE_EXITS=()
    for d in $(echo "$input" | tr ',;' '  ' | tr '[:upper:]' '[:lower:]' | tr ' ' '\n' | awk 'NF && !seen[$0]++'); do
        [[ "$d" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
            || log_error "Некорректный домен: $d"
        [[ "$d" == "$CASCADE_ENTRY" ]] && log_error "$d — домен самого входа, его нельзя указывать среди выходов (петля)"
        CASCADE_EXITS+=("$d")
    done

    read -rp "Порты для пересылки [$CASCADE_DEFAULT_PORTS]: " input
    CASCADE_PORTS=()
    for d in $(echo "${input:-$CASCADE_DEFAULT_PORTS}" | tr ',;' '  '); do
        [[ "$d" =~ ^[0-9]+$ && "$d" -ge 1 && "$d" -le 65535 ]] || log_error "Некорректный порт: $d"
        CASCADE_PORTS+=("$d")
    done

    read_cascade_udp_map
}

# UDP-пересылка (Hysteria2): пары "порт:домен[,порт:домен]" → upstream домена на порт 443.
# UDP 443 до входа часто режется, поэтому по умолчанию отдельный порт. При установке
# спрашивается; если CASCADE_UDP_MAP уже есть в cascade.env, значение не перезаписывается
# (правится в файле, пустое значение — UDP выключен)
read_cascade_udp_map() {
    local line uport ud

    line=$(grep -m1 '^CASCADE_UDP_MAP=' "$CASCADE_ENV_FILE" 2>/dev/null || true)
    if [[ -n "$line" ]]; then
        CASCADE_UDP_MAP=$(sed -n 's/^CASCADE_UDP_MAP="\(.*\)"$/\1/p' <<< "$line")
        log_info "UDP-карта из $CASCADE_ENV_FILE: ${CASCADE_UDP_MAP:-пусто, UDP выключен} (не перезаписываю, правится в файле)"
    else
        echo "UDP-пересылка Hysteria2: UDP 443 до входа часто режется, поэтому нужен отдельный порт"
        read -rp "UDP-порт [${CASCADE_UDP_DEFAULT_PORT}] ('-' — без UDP): " uport
        if [[ "$uport" == "-" ]]; then
            CASCADE_UDP_MAP=""
            return
        fi
        read -rp "Выход для UDP [${CASCADE_UDP_DEFAULT_DOMAIN}]: " ud
        CASCADE_UDP_MAP="${uport:-$CASCADE_UDP_DEFAULT_PORT}:${ud:-$CASCADE_UDP_DEFAULT_DOMAIN}"
    fi

    check_cascade_udp_map
}

# Проверяет и нормализует CASCADE_UDP_MAP (через запятую, нижний регистр)
check_cascade_udp_map() {
    local pair uport ud users pairs=() ports=" "

    for pair in $(tr ',;' '  ' <<< "$CASCADE_UDP_MAP" | tr '[:upper:]' '[:lower:]'); do
        uport="${pair%%:*}" ud="${pair#*:}"
        [[ "$pair" == *:* && "$uport" =~ ^[0-9]+$ ]] && (( uport >= 1 && uport <= 65535 )) \
            || log_error "Некорректная UDP-пара: $pair (нужно порт:домен, порт 1–65535)"
        [[ "$ud" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
            || log_error "Некорректный домен в UDP-паре: $pair"
        [[ "$ports" == *" $uport "* ]] && log_error "UDP-порт $uport повторяется в карте: $CASCADE_UDP_MAP"
        ports+="$uport "

        users=$(ss -Hulnp "sport = :${uport}" 2>/dev/null | grep -o 'users:(("[^"]*"' | cut -d'"' -f2 | sort -u | tr '\n' ' ')
        [[ -n "$users" && "$users" != "nginx " ]] && log_error "UDP-порт $uport занят: ${users}— выберите другой"

        (( uport == 443 )) && log_warn "$pair: UDP 443 часто режется по пути до входа, рекомендуется ${CASCADE_UDP_DEFAULT_PORT}"
        [[ " ${CASCADE_EXITS[*]} " == *" $ud "* && " ${CASCADE_PORTS[*]} " == *" 443 "* ]] \
            || log_warn "$pair: нужен выход $ud в списке и TCP-порт 443 (общий upstream), иначе пара будет пропущена"
        pairs+=("${uport}:${ud}")
    done

    CASCADE_UDP_MAP=$(IFS=,; echo "${pairs[*]}")
}

# ufw: открывает UDP-порты карты, а правила cascade-udp для портов не из карты удаляет
# (с конца списка, чтобы номера правил не съезжали)
sync_cascade_udp_ufw() {
    local pair num port keep=" "

    for pair in $(tr ',' ' ' <<< "${CASCADE_UDP_MAP:-}"); do
        keep+="${pair%%:*} "
        log_info "UFW: открываю ${pair%%:*}/udp (${pair#*:})"
        ufw allow "${pair%%:*}/udp" comment 'cascade-udp' >/dev/null
    done

    ufw status numbered 2>/dev/null \
        | sed -nE 's/^\[ *([0-9]+)\] ([0-9]+)\/udp.*# cascade-udp[[:space:]]*$/\1 \2/p' \
        | sort -rn | while read -r num port; do
            [[ "$keep" == *" $port "* ]] && continue
            log_info "UFW: удаляю устаревшее правило ${port}/udp (cascade-udp)"
            ufw --force delete "$num" >/dev/null
        done
}

# Порт должен быть свободен или занят самим nginx (повторный запуск)
check_cascade_ports() {
    local port users
    for port in "${CASCADE_PORTS[@]}"; do
        users=$(ss -Hltnp "sport = :${port}" 2>/dev/null | grep -o 'users:(("[^"]*"' | cut -d'"' -f2 | sort -u | tr '\n' ' ')
        if [[ -n "$users" && "$users" != "nginx " ]]; then
            log_error "Порт ${port}/tcp занят: ${users}. Вход каскада нельзя ставить рядом с сервисом на этом порту (например, xray ноды)"
        fi
    done
}

# Статус имени в DNS: "ok IP..." | "absent" (NXDOMAIN или нет A-записи) | "failed" (таймаут, SERVFAIL)
cascade_lookup() {
    local out status ips
    out=$(dig +time=2 +tries=2 +noall +comments +answer "$1" A 2>/dev/null)
    status=$(grep -oP 'status: \K\w+' <<< "$out" | head -1)
    ips=$(awk '$4 == "A" { print $5 }' <<< "$out" | sort -u | tr '\n' ' ')
    if [[ "$status" == NOERROR && -n "$ips" ]]; then
        echo "ok $ips"
    elif [[ "$status" == NXDOMAIN || "$status" == NOERROR ]]; then
        echo "absent"
    else
        echo "failed"
    fi
}

# Ставит cascade-refresh и таймер systemd. Скрипт генерирует конфиг nginx с IP выходов
# в upstream-блоках; запускается раз в минуту и при первичной установке (--no-reload)
install_cascade_refresh() {
    cat > "$CASCADE_ENV_FILE" << EOF
CASCADE_PORTS="${CASCADE_PORTS[*]}"
CASCADE_LOG="${CASCADE_LOG}"
CASCADE_CONNECT_TIMEOUT="${CASCADE_CONNECT_TIMEOUT}"
CASCADE_PROXY_BUFFER="${CASCADE_PROXY_BUFFER}"
CASCADE_LISTEN_BACKLOG=${CASCADE_LISTEN_BACKLOG}
CASCADE_ABSENT_LIMIT=${CASCADE_ABSENT_LIMIT}
CASCADE_STREAM_CONF="${CASCADE_STREAM_CONF}"
CASCADE_EXITS_FILE="${CASCADE_EXITS_FILE}"
CASCADE_STATE_FILE="${CASCADE_STATE_FILE}"
# UDP-порты (Hysteria2) → upstream домена на порт 443: "порт:домен[,порт:домен]"; пусто — UDP выключен.
# Пункт 8 это значение не перезаписывает
CASCADE_UDP_MAP="${CASCADE_UDP_MAP:-}"
EOF

    # Скрипт перезаписывается при каждом запуске пункта 8 (переход на новую версию);
    # cascade-exits.list и cascade-exits.state он только читает и обновляет
    cat > "$CASCADE_REFRESH_BIN" << 'EOF'
#!/bin/bash
# Сгенерировано remnanode-scripts.sh (пункт 8). Узнаёт IP выходов каскада и обновляет конфиг nginx.
# При сбое DNS оставляет прежние адреса; выход без A-записи исключается только после
# CASCADE_ABSENT_LIMIT проверок подряд. Журнал: journalctl -u cascade-refresh
#   cascade-refresh              — обновить, при изменении адресов проверить конфиг и сделать reload
#   cascade-refresh --no-reload  — только записать конфиг (первичная установка)
set -u
source /etc/nginx/cascade.env

lookup() {
    local out status ips
    out=$(dig +time=2 +tries=2 +noall +comments +answer "$1" A 2>/dev/null)
    status=$(grep -oP 'status: \K\w+' <<< "$out" | head -1)
    # sort -V: порядок ответа dig меняется, а файл и reload от этого меняться не должны
    ips=$(awk '$4 == "A" { print $5 }' <<< "$out" | sort -u -V | tr '\n' ' ')
    if [[ "$status" == NOERROR && -n "$ips" ]]; then echo "ok $ips"
    elif [[ "$status" == NXDOMAIN || "$status" == NOERROR ]]; then echo "absent"
    else echo "failed"; fi
}

declare -A last misses cur
if [[ -f "$CASCADE_STATE_FILE" ]]; then
    while read -r d m ips; do misses[$d]=$m; last[$d]=$ips; done < "$CASCADE_STATE_FILE"
fi
local_ips=" $(hostname -I 2>/dev/null) "
state=""

for d in $(cat "$CASCADE_EXITS_FILE"); do
    read -r res ips <<< "$(lookup "$d")"
    m=${misses[$d]:-0}
    case "$res" in
        ok)
            for ip in $ips; do
                if [[ "$local_ips" == *" $ip "* ]]; then
                    echo "$d указывает на этот сервер ($ip) — петля, выход пропущен" >&2
                    ips=""
                fi
            done
            [[ -n "$ips" ]] && cur[$d]=$ips
            m=0
            ;;
        absent)
            m=$(( m + 1 ))
            if [[ -n "${last[$d]:-}" && $m -lt $CASCADE_ABSENT_LIMIT ]]; then
                cur[$d]=${last[$d]}
                echo "$d: нет A-записи (${m}/${CASCADE_ABSENT_LIMIT}), пока оставляю ${last[$d]}" >&2
            elif [[ -n "${last[$d]:-}" || $m -eq 1 ]]; then
                echo "$d: нет A-записи — выход исключён" >&2
            fi
            ;;
        failed)
            if [[ -n "${last[$d]:-}" ]]; then
                cur[$d]=${last[$d]}
                echo "$d: DNS не ответил, оставляю ${last[$d]}" >&2
            else
                echo "$d: DNS не ответил, адресов ещё нет — выход пропущен" >&2
            fi
            ;;
    esac
    state+="$d $m ${cur[$d]:-}"$'\n'
done

upstream_name() { echo "cascade_$(tr -c 'a-zA-Z0-9' '_' <<< "$1" | sed 's/_*$//')_$2"; }

tmp=$(mktemp "${CASCADE_STREAM_CONF}.XXXX")
{
    echo "# Сгенерировано cascade-refresh. Ручные правки будут перезаписаны"
    echo "stream {"
    echo "    log_format cascade '\$remote_addr [\$time_local] port=\$server_port sni=\$ssl_preread_server_name '"
    echo "                       'up=\$upstream_addr st=\$status in=\$bytes_received out=\$bytes_sent t=\$session_time';"
    echo "    access_log ${CASCADE_LOG} cascade buffer=64k flush=5s;"
    for port in $CASCADE_PORTS; do
        for d in $(cat "$CASCADE_EXITS_FILE"); do
            [[ -n "${cur[$d]:-}" ]] || continue
            echo
            echo "    upstream $(upstream_name "$d" "$port") {"
            # Клиент держится одной ноды группы (стабильный внешний IP). Без consistent:
            # кольцо ketama строится из адресов вместе с портом, и TCP/gRPC/UDP одного клиента
            # ушли бы на разные ноды. Обычный hash выбирает по номеру в списке — списки IP
            # для всех портов домена одинаковые и в одном порядке (sort -u -V)
            echo "        hash \$remote_addr;"
            for ip in $(tr ' ' '\n' <<< "${cur[$d]}" | sort -u -V); do
                echo "        server ${ip}:${port} max_fails=2 fail_timeout=15s;"
            done
            echo "    }"
        done
        echo
        echo "    map \$ssl_preread_server_name \$cascade_exit_${port} {"
        for d in $(cat "$CASCADE_EXITS_FILE"); do
            [[ -n "${cur[$d]:-}" ]] && echo "        ${d} $(upstream_name "$d" "$port");"
        done
        echo "        default 127.0.0.1:9;    # неизвестный SNI: соединение сбрасывается"
        echo "    }"
        echo
        echo "    server {"
        echo "        listen ${port} reuseport backlog=${CASCADE_LISTEN_BACKLOG};"
        echo "        ssl_preread on;"
        echo "        proxy_pass \$cascade_exit_${port};"
        echo "        proxy_connect_timeout ${CASCADE_CONNECT_TIMEOUT};"
        echo "        proxy_next_upstream on;    # нода группы не отвечает — пробуем следующую"
        echo "        proxy_timeout 30m;"
        echo "        proxy_socket_keepalive on;"
        echo "        proxy_buffer_size ${CASCADE_PROXY_BUFFER};"
        echo "    }"
    done

    # UDP (Hysteria2): тот же upstream домена на порт 443 — SNI в QUIC не прочитать, выход задаёт порт.
    # Неверная пара пропускается с предупреждением, а не роняет nginx
    udp_ports=" "
    for pair in $(tr ',' ' ' <<< "${CASCADE_UDP_MAP:-}"); do
        uport="${pair%%:*}" ud="${pair#*:}"
        if [[ "$pair" != *:* || ! "$uport" =~ ^[0-9]+$ ]] || (( uport < 1 || uport > 65535 )); then
            echo "CASCADE_UDP_MAP: неверная пара '$pair' — пропущена" >&2
            continue
        fi
        if [[ "$udp_ports" == *" $uport "* ]]; then
            echo "CASCADE_UDP_MAP: UDP-порт $uport повторяется — пара '$pair' пропущена" >&2
            continue
        fi
        users=$(ss -Hulnp "sport = :${uport}" 2>/dev/null | grep -o 'users:(("[^"]*"' | cut -d'"' -f2 | sort -u | tr '\n' ' ')
        if [[ -n "$users" && "$users" != "nginx " ]]; then
            echo "CASCADE_UDP_MAP: UDP-порт $uport занят (${users% }) — пара '$pair' пропущена" >&2
            continue
        fi
        if [[ " $CASCADE_PORTS " != *" 443 "* || -z "${cur[$ud]:-}" ]]; then
            echo "CASCADE_UDP_MAP: нет upstream $(upstream_name "$ud" 443) — UDP-порт $uport пропущен" >&2
            continue
        fi
        udp_ports+="$uport "
        echo
        echo "    server {"
        echo "        listen ${uport} udp reuseport;"
        echo "        proxy_pass $(upstream_name "$ud" 443);"
        echo "        proxy_timeout 120s;"
        echo "    }"
    done
    echo "}"
} > "$tmp"
chmod 644 "$tmp"
printf '%s' "$state" > "$CASCADE_STATE_FILE"

# hash без consistent даёт одну ноду на все порты только при одинаковых списках IP
awk '/^    upstream cascade_/ { name = $2; sub(/_[0-9]+$/, "", name); list = ""; inside = 1; next }
     inside && /^        server / { split($2, a, ":"); list = list a[1] " "; next }
     inside && /^    }/ { if (name in ref && ref[name] != list) print name; else ref[name] = list; inside = 0 }' "$tmp" \
    | sort -u | while read -r name; do
        echo "${name}: списки IP отличаются между портами — TCP/UDP одного клиента могут уйти на разные ноды" >&2
    done

if cmp -s "$tmp" "$CASCADE_STREAM_CONF"; then
    rm -f "$tmp"
    exit 0
fi
if [[ "${1:-}" == --no-reload ]]; then
    mv "$tmp" "$CASCADE_STREAM_CONF"
    exit 0
fi

bak=$(mktemp "${CASCADE_STREAM_CONF}.bak.XXXX")
cp -p "$CASCADE_STREAM_CONF" "$bak" 2>/dev/null || true
mv "$tmp" "$CASCADE_STREAM_CONF"
if nginx -t -q 2>/dev/null; then
    systemctl reload nginx
    echo "адреса выходов изменились, nginx перезагружен" >&2
    rm -f "$bak"
else
    mv "$bak" "$CASCADE_STREAM_CONF"
    echo "новый конфиг невалиден, оставлен прежний" >&2
    exit 1
fi
EOF
    chmod 755 "$CASCADE_REFRESH_BIN"

    cat > "/etc/systemd/system/${CASCADE_REFRESH_UNIT}.service" << EOF
[Unit]
Description=Обновление IP выходов каскада в nginx
After=network-online.target nginx.service

[Service]
Type=oneshot
ExecStart=${CASCADE_REFRESH_BIN}
EOF
    cat > "/etc/systemd/system/${CASCADE_REFRESH_UNIT}.timer" << EOF
[Unit]
Description=Обновление IP выходов каскада раз в минуту

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
}

# Лимиты от размера сервера: память на сессии делится между воркерами (воркер = ядро).
# Задаёт CASCADE_WORKER_CONNECTIONS и CASCADE_CONNTRACK_MAX
cascade_compute_limits() {
    local ram_mb cores total per_worker current ct ct_cap

    ram_mb=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
    cores=$(nproc 2>/dev/null || echo 1)

    total=$(( (ram_mb - CASCADE_RAM_RESERVE_MB) * 1024 / CASCADE_SESSION_KB * 2 ))
    per_worker=$(( total > 0 ? total / cores : 0 ))
    (( per_worker < CASCADE_MIN_WORKER_CONNECTIONS )) && per_worker=$CASCADE_MIN_WORKER_CONNECTIONS
    (( per_worker > CASCADE_MAX_WORKER_CONNECTIONS )) && per_worker=$CASCADE_MAX_WORKER_CONNECTIONS

    # Поднятое вручную значение не уменьшаем
    current=$(sed -n -E 's/^[[:space:]]*worker_connections[[:space:]]+([0-9]+);.*/\1/p' "$NGINX_CONF" | head -1)
    (( ${current:-0} > per_worker && current <= CASCADE_MAX_WORKER_CONNECTIONS )) && per_worker=$current
    CASCADE_WORKER_CONNECTIONS=$per_worker

    # Запись conntrack на каждое соединение плюс закрытые (TIME_WAIT); не больше ~8% памяти (≈320 байт на запись)
    ct=$(( per_worker * cores * 2 ))
    ct_cap=$(( ram_mb * 256 ))
    (( ct > ct_cap )) && ct=$ct_cap
    (( ct < CONNTRACK_MAX )) && ct=$CONNTRACK_MAX
    CASCADE_CONNTRACK_MAX=$ct

    log_info "Сервер: ${cores} ядер, ${ram_mb} МБ → worker_connections ${per_worker} на ядро (~$(( per_worker / 2 * cores )) сессий), conntrack ${ct}"
}

# Исходящих портов к одному IP:порту выхода по умолчанию ~28 тыс. (32768–60999) — расширяем до ~55 тыс.
# tcp_tw_reuse=1 позволяет повторно брать порты исходящих соединений из TIME_WAIT
# tcp_mtu_probing — как в пункте 7, чтобы вход получил его и без отдельного запуска BBR.
# somaxconn — потолок очереди listen (backlog в конфиге каскада); больший не уменьшаем
setup_cascade_sysctl() {
    local somaxconn
    somaxconn=$(sysctl -n net.core.somaxconn 2>/dev/null || echo 0)
    (( somaxconn < CASCADE_LISTEN_BACKLOG )) && somaxconn=$CASCADE_LISTEN_BACKLOG

    cat > "$CASCADE_PORTS_SYSCTL_CONF" << EOF
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = ${somaxconn}
EOF
    chmod 644 "$CASCADE_PORTS_SYSCTL_CONF"
    sysctl -q -p "$CASCADE_PORTS_SYSCTL_CONF" || log_warn "sysctl $CASCADE_PORTS_SYSCTL_CONF применился не полностью"
}

# Подключает stream-конфиг в nginx.conf и поднимает лимиты соединений
patch_nginx_conf() {
    if ! grep -q "include ${CASCADE_STREAM_CONF};" "$NGINX_CONF"; then
        printf '\ninclude %s;\n' "$CASCADE_STREAM_CONF" >> "$NGINX_CONF"
    fi
    local nofile
    nofile=$(sed -n -E 's/^[[:space:]]*worker_rlimit_nofile[[:space:]]+([0-9]+);.*/\1/p' "$NGINX_CONF" | head -1)
    if [[ -z "$nofile" ]]; then
        sed -i -E "0,/^[[:space:]]*worker_processes/s//worker_rlimit_nofile ${CASCADE_RLIMIT_NOFILE};\n&/" "$NGINX_CONF"
    elif (( nofile < CASCADE_RLIMIT_NOFILE )); then
        sed -i -E "s/^([[:space:]]*worker_rlimit_nofile)[[:space:]]+[0-9]+;/\1 ${CASCADE_RLIMIT_NOFILE};/" "$NGINX_CONF"
    fi
    # Один воркер на ядро: лимит соединений растёт вместе с ядрами
    sed -i -E 's/^([[:space:]]*worker_processes)[[:space:]]+[0-9]+;/\1 auto;/' "$NGINX_CONF"
    sed -i -E "s/^([[:space:]]*worker_connections)[[:space:]]+[0-9]+;/\1 ${CASCADE_WORKER_CONNECTIONS};/" "$NGINX_CONF"
}

# Упирался ли вход в лимит соединений и сколько сессий держит сейчас
check_cascade_capacity() {
    local workers sessions capacity hits=0
    workers=$(nproc 2>/dev/null || echo 1)
    capacity=$(( CASCADE_WORKER_CONNECTIONS / 2 * workers ))
    sessions=$(ss -Htn state established "( $(printf 'sport = :%s or ' "${CASCADE_PORTS[@]}" | sed 's/ or $//') )" 2>/dev/null | wc -l)
    log_info "Сессий сейчас: ${sessions}, ёмкость входа: ~${capacity} (${workers} ядер × ${CASCADE_WORKER_CONNECTIONS} / 2)"

    [[ -f "$NGINX_ERROR_LOG" ]] && hits=$(grep -c 'worker_connections are not enough' "$NGINX_ERROR_LOG" || true)
    if (( hits > 0 )); then
        log_warn "В $NGINX_ERROR_LOG ${hits} раз(а) 'worker_connections are not enough' — вход упирался в лимит, в эти моменты новые подключения не открывались"
        log_warn "Если это повторится после текущей настройки — нужен вход с большим числом ядер или второй вход"
    fi
}

# Печатает subject сертификата, если TLS-рукопожатие с этим SNI прошло
tls_subject() {
    timeout 8 openssl s_client -connect "$1" -servername "$2" </dev/null 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null || true
}

check_cascade_exits() {
    local d port ip subject ips
    log_info "Проверка рукопожатия через вход (127.0.0.1)..."
    for d in "${CASCADE_EXITS[@]}"; do
        for port in "${CASCADE_PORTS[@]}"; do
            subject=$(tls_subject "127.0.0.1:${port}" "$d")
            if [[ -n "$subject" ]]; then
                echo -e "  ${GREEN}OK${NC}    $d:$port  ($subject)"
            else
                echo -e "  ${RED}FAIL${NC}  $d:$port  — нет ответа (DNS, файрвол выхода, порт $port на выходе)"
            fi
        done

        # Группа нод одного профиля: вход чередует их по кругу, поэтому проверяем каждую
        read -ra ips <<< "${CASCADE_EXIT_IPS[$d]}"
        (( ${#ips[@]} > 1 )) || continue
        for ip in "${ips[@]}"; do
            subject=$(tls_subject "${ip}:${CASCADE_PORTS[0]}" "$d")
            if [[ -n "$subject" ]]; then
                echo -e "        ${GREEN}OK${NC}    нода $ip"
            else
                echo -e "        ${RED}FAIL${NC}  нода $ip — недоступна, вход будет переключаться с неё на другие с задержкой ${CASCADE_CONNECT_TIMEOUT}"
            fi
        done
    done
}

# Лог каскада ротирует nginx через reopen (без copytruncate: буфер nginx не теряет строки)
setup_cascade_logrotate() {
    local nginx_bin
    nginx_bin=$(command -v nginx)

    ensure_logrotate

    log_info "Создание конфигурации $CASCADE_LOGROTATE_CONF..."
    cat > "$CASCADE_LOGROTATE_CONF" << EOF
${CASCADE_LOG_DIR}/*.log {
    size 50M
    rotate 5
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        ${nginx_bin} -s reopen >/dev/null 2>&1 || true
    endscript
}
EOF
    chmod 644 "$CASCADE_LOGROTATE_CONF"

    check_logrotate_conflicts
    logrotate -d "$CASCADE_LOGROTATE_CONF" >/dev/null 2>&1 || log_error "Конфигурация $CASCADE_LOGROTATE_CONF невалидна"
    log_info "Logrotate для каскада настроен"
}

# Резолвит выходы; несколько A-записей у одного имени — группа нод одного профиля.
# Имена без A-записи исключаются из списка, при сбое DNS выход остаётся (адрес подставит таймер)
resolve_cascade_exits() {
    local d res ips ip local_ips kept=()
    local_ips=" ${SERVER_IP} $(hostname -I 2>/dev/null) "

    declare -gA CASCADE_EXIT_IPS=()
    for d in "${CASCADE_EXITS[@]}"; do
        read -r res ips <<< "$(cascade_lookup "$d")"
        ips="${ips% }"
        if [[ "$res" == absent ]]; then
            log_warn "$d: нет A-записи — выход исключён из списка"
            continue
        fi
        kept+=("$d")
        CASCADE_EXIT_IPS[$d]="$ips"
        if [[ "$res" == failed ]]; then
            log_warn "$d: DNS не ответил — выход оставлен, адрес подставится при следующей проверке"
            continue
        fi
        for ip in $ips; do
            [[ "$local_ips" == *" $ip "* ]] \
                && log_error "$d указывает на этот сервер ($ip) — получится петля. Имя выхода должно указывать на выход, не на вход"
        done
        if [[ "$ips" == *" "* ]]; then
            log_info "$d → $ips (группа нод, балансировка по кругу)"
        else
            log_info "$d → $ips"
        fi
    done

    (( ${#kept[@]} > 0 )) || log_error "Ни у одного выхода нет A-записи — нечего настраивать"
    CASCADE_EXITS=("${kept[@]}")
}

setup_cascade() {
    local conf_backup="" main_backup port

    read_cascade_exits
    check_cascade_ports

    if ! command -v nginx >/dev/null || ! dpkg -s libnginx-mod-stream >/dev/null 2>&1 || ! command -v dig >/dev/null; then
        log_info "Установка nginx, модуля stream и dig..."
        apt update -q
        apt install -y -q nginx libnginx-mod-stream dnsutils
    fi
    nginx -V 2>&1 | grep -q ssl_preread || log_error "nginx собран без ssl_preread, установите nginx из репозитория nginx.org"

    ensure_server_ip
    resolve_cascade_exits

    if ! command -v jq >/dev/null; then
        apt update -q
        apt install -y -q jq curl
    fi
    ensure_cf_creds
    DOMAIN="$CASCADE_ENTRY"
    update_dns
    echo "$CASCADE_ENTRY" > "$CASCADE_ENTRY_FILE"

    main_backup=$(mktemp "${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S).XXXX")
    cp -p "$NGINX_CONF" "$main_backup"
    if [[ -f "$CASCADE_STREAM_CONF" ]]; then
        conf_backup=$(mktemp "${CASCADE_STREAM_CONF}.bak.$(date +%Y%m%d%H%M%S).XXXX")
        cp -p "$CASCADE_STREAM_CONF" "$conf_backup"
    fi

    mkdir -p "$CASCADE_LOG_DIR"
    cascade_compute_limits
    printf '%s\n' "${CASCADE_EXITS[@]}" > "$CASCADE_EXITS_FILE"
    install_cascade_refresh
    log_info "Запись $CASCADE_STREAM_CONF..."
    "$CASCADE_REFRESH_BIN" --no-reload
    patch_nginx_conf

    if ! nginx -t; then
        mv "$main_backup" "$NGINX_CONF"
        if [[ -n "$conf_backup" ]]; then mv "$conf_backup" "$CASCADE_STREAM_CONF"; else rm -f "$CASCADE_STREAM_CONF"; fi
        log_error "Конфигурация nginx невалидна, изменения откачены"
    fi
    rm -f "$main_backup" "$conf_backup"

    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl reload-or-restart nginx
    systemctl enable --now "${CASCADE_REFRESH_UNIT}.timer" >/dev/null 2>&1 \
        || log_warn "Не удалось включить ${CASCADE_REFRESH_UNIT}.timer — IP выходов не будут обновляться автоматически"

    log_info "Upstream'ы в загруженной конфигурации nginx:"
    nginx -T 2>/dev/null | grep -A3 "upstream cascade_" || log_warn "upstream cascade_ не найдены — проверьте журнал: journalctl -u ${CASCADE_REFRESH_UNIT}"

    setup_cascade_logrotate

    ufw_allow_ssh
    for port in "${CASCADE_PORTS[@]}"; do
        log_info "UFW: открываю ${port}/tcp"
        ufw allow "${port}/tcp" comment 'cascade' >/dev/null
    done
    sync_cascade_udp_ufw
    if ! ufw status | grep -q '^Status: active'; then
        log_info "Включение ufw..."
        ufw --force enable
    fi
    tune_conntrack "$CASCADE_CONNTRACK_MAX"
    setup_cascade_sysctl

    check_cascade_exits
    check_cascade_capacity

    echo
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Вход каскада настроен${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "  Вход:      ${YELLOW}${CASCADE_ENTRY} → ${SERVER_IP}${NC}"
    echo -e "  Порты:     ${YELLOW}${CASCADE_PORTS[*]}${NC}"
    [[ -n "${CASCADE_UDP_MAP:-}" ]] && echo -e "  UDP:       ${YELLOW}${CASCADE_UDP_MAP}${NC} (порт:выход, upstream на 443)"
    echo -e "  Выходы:    ${YELLOW}${CASCADE_EXITS[*]}${NC}"
    echo -e "  Журнал:    ${YELLOW}tail -f ${CASCADE_LOG}${NC}"
    echo -e "  IP выходов: ${YELLOW}обновляются раз в минуту, журнал: journalctl -u ${CASCADE_REFRESH_UNIT}${NC}"
    echo -e "  Хостов в панели: ${YELLOW}$(( ${#CASCADE_EXITS[@]} * ${#CASCADE_PORTS[@]} ))${NC} (выход × порт): address = ${CASCADE_ENTRY}, sni = домен выхода,"
    echo -e "  inbound профиля выхода, overrideSniFromAddress выключен"
    echo -e "${GREEN}════════════════════════════════════════${NC}"

    if [[ -n "${CASCADE_UDP_MAP:-}" ]]; then
        echo
        log_info "UDP-сокеты nginx:"
        ss -ulnp | grep nginx || log_warn "nginx не слушает UDP — проверьте journalctl -u ${CASCADE_REFRESH_UNIT}"
        log_info "UDP-listen в конфигурации nginx:"
        nginx -T 2>/dev/null | grep -E '^\s*listen .* udp'
        log_info "Проверка с клиента (на входе смотреть: tcpdump -ni any udp port <порт>):"
        for port in $(tr ',' ' ' <<< "$CASCADE_UDP_MAP"); do
            echo "  echo test | nc -u -w1 ${SERVER_IP} ${port%%:*}"
        done
    fi
}

# ─── Сценарии ─────────────────────────────────────────────────────────────────
run_issue() {
    local input
    echo "Домены через запятую: первый — основной (его A-запись укажет на этот сервер),"
    echo "остальные — дополнительные имена сертификата (их DNS-записи не меняются)"
    read -rp "Домены (например sni.example.com или sni-1.example.com,sni.example.com): " input
    parse_domains "$input"

    install_deps
    ensure_cf_creds
    ensure_server_ip

    # Только основной домен: у дополнительных может быть пул A-записей, одна запись его сломает
    update_dns
    issue_cert
    install_selfsteal
    (( ${#EXTRA_DOMAINS[@]} > 0 )) && check_selfsteal_names
    add_compose_volume "${XRAY_SSL_DIR}:${XRAY_SSL_DIR}:ro" || true
    restart_remnawave

    echo
    log_info "Имена в сертификате:"
    openssl x509 -in "${XRAY_SSL_DIR}/cert.pem" -noout -ext subjectAltName

    echo
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Готово!${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "  Домен:       ${YELLOW}${DOMAIN} → ${SERVER_IP}${NC}"
    (( ${#EXTRA_DOMAINS[@]} > 0 )) && echo -e "  Доп. имена:  ${YELLOW}${EXTRA_DOMAINS[*]}${NC} (DNS не менялся)"
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
    echo "7) Включить BBR (ускорение TCP на длинных каналах)"
    echo "8) Развернуть вход каскада на РФ-сервере (DNS входа + nginx → выходы по SNI)"
    echo
    echo "9) Указать Cloudflare авторизацию (email + API Token)"
    echo "0) Выход"
    read -rp "Выберите действие [0-9]: " choice

    case "$choice" in
        1) install_remnanode ;;
        2) run_issue ;;
        3) setup_logrotate ;;
        4) setup_geo_files ;;
        5) setup_firewall ;;
        6) cleanup_disk ;;
        7) setup_bbr ;;
        8) setup_cascade ;;
        9) run_auth ;;
        0) exit 0 ;;
        *) log_warn "Неверный выбор" ;;
    esac
done
