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
NGINX_CONF="/etc/nginx/nginx.conf"
CASCADE_STREAM_CONF="/etc/nginx/cascade-stream.conf"
CASCADE_EXITS_FILE="/etc/nginx/cascade-exits.list"
CASCADE_ENTRY_FILE="/etc/nginx/cascade-entry.domain"
CASCADE_DEFAULT_PORTS="443 8443"
CASCADE_CONNECT_TIMEOUT="4s"
# Сессия stream занимает 2 соединения (клиент + выход): 16384 ≈ 8192 сессий на воркер (ядро).
# При исчерпании лимита новые соединения не принимаются у всех пользователей входа
CASCADE_WORKER_CONNECTIONS=16384
CASCADE_RLIMIT_NOFILE=65535
# Буфер на каждое направление сессии (по умолчанию 16k): вдвое меньше памяти на сессию
CASCADE_PROXY_BUFFER="8k"
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
tune_conntrack() {
    local current max

    modprobe nf_conntrack 2>/dev/null || true
    current=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || true)
    if [[ -z "$current" ]]; then
        log_info "conntrack не используется, пропускаю настройку"
        return
    fi
    max=$(( current > CONNTRACK_MAX ? current : CONNTRACK_MAX ))

    log_info "Настройка conntrack: лимит ${current} → ${max}, укороченные таймауты..."
    # Модуль грузится до применения sysctl.d, иначе после перезагрузки настройки не применятся
    echo "nf_conntrack" > "$CONNTRACK_MODULES_CONF"
    echo "options nf_conntrack hashsize=$(( max / 4 ))" > "$CONNTRACK_MODPROBE_CONF"
    # established 1 ч: больше proxy_timeout nginx (30 мин) и idle xray (5 мин), живые соединения не рвутся
    cat > "$CONNTRACK_SYSCTL_CONF" << EOF
net.netfilter.nf_conntrack_max = ${max}
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30
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
    local cc qdisc

    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    log_info "Сейчас: congestion control = ${cc:-?}, qdisc = ${qdisc:-?}"

    if [[ "$cc" == bbr && "$qdisc" == fq && -f "$BBR_SYSCTL_CONF" ]]; then
        log_info "BBR уже включён"
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

    echo "Домены выходов через запятую или пробел (например kraw-pl-1.example.com,kraw-pl-2.example.com)"
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

# Системный DNS (обычно 127.0.0.53); публичные резолверы из РФ могут быть недоступны
cascade_resolvers() {
    local ns
    ns=$(awk '$1 == "nameserver" && $2 ~ /^[0-9.]+$/ { print $2 }' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')
    echo "${ns:-1.1.1.1 8.8.8.8}"
}

write_cascade_conf() {
    local port d resolvers
    resolvers=$(cascade_resolvers)

    {
        echo "# Сгенерировано remnanode-scripts.sh (каскад). Ручные правки будут перезаписаны"
        echo "stream {"
        echo "    resolver ${resolvers}valid=30s ipv6=off;"
        echo "    resolver_timeout 3s;"
        echo
        echo "    log_format cascade '\$remote_addr [\$time_local] port=\$server_port sni=\$ssl_preread_server_name '"
        echo "                       'up=\$upstream_addr st=\$status in=\$bytes_received out=\$bytes_sent t=\$session_time';"
        echo "    access_log ${CASCADE_LOG} cascade buffer=64k flush=5s;"
        for port in "${CASCADE_PORTS[@]}"; do
            echo
            echo "    map \$ssl_preread_server_name \$cascade_exit_${port} {"
            for d in "${CASCADE_EXITS[@]}"; do
                echo "        ${d} ${d}:${port};"
            done
            echo "        default 127.0.0.1:9;    # неизвестный SNI: соединение сбрасывается"
            echo "    }"
            echo
            echo "    server {"
            echo "        listen ${port} reuseport;"
            echo "        ssl_preread on;"
            echo "        proxy_pass \$cascade_exit_${port};"
            echo "        proxy_connect_timeout ${CASCADE_CONNECT_TIMEOUT};"
            echo "        proxy_next_upstream on;    # нода группы не отвечает — пробуем следующую A-запись"
            echo "        proxy_timeout 30m;"
            echo "        proxy_socket_keepalive on;"
            echo "        proxy_buffer_size ${CASCADE_PROXY_BUFFER};"
            echo "    }"
        done
        echo "}"
    } > "$CASCADE_STREAM_CONF"
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

# Резолвит выходы; несколько A-записей у одного имени — группа нод одного профиля
resolve_cascade_exits() {
    local d ips ip local_ips
    local_ips=" ${SERVER_IP} $(hostname -I 2>/dev/null) "

    declare -gA CASCADE_EXIT_IPS=()
    for d in "${CASCADE_EXITS[@]}"; do
        ips=$(getent ahostsv4 "$d" | awk '!seen[$1]++ { print $1 }' | tr '\n' ' ' | sed 's/ *$//')
        CASCADE_EXIT_IPS[$d]="$ips"
        if [[ -z "$ips" ]]; then
            log_warn "$d не резолвится — путь через него работать не будет, пока нет A-записи"
            continue
        fi
        for ip in $ips; do
            [[ "$local_ips" == *" $ip "* ]] \
                && log_error "$d указывает на этот сервер ($ip) — получится петля. Имя выхода должно указывать на выход, не на вход"
        done
        if [[ "$ips" == *" "* ]]; then
            log_info "$d → $ips (группа нод, DNS-балансировка по кругу)"
        else
            log_info "$d → $ips"
        fi
    done
}

setup_cascade() {
    local conf_backup="" main_backup port

    read_cascade_exits
    check_cascade_ports

    if ! command -v nginx >/dev/null || ! dpkg -s libnginx-mod-stream >/dev/null 2>&1; then
        log_info "Установка nginx и модуля stream..."
        apt update -q
        apt install -y -q nginx libnginx-mod-stream
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
    log_info "Запись $CASCADE_STREAM_CONF..."
    write_cascade_conf
    patch_nginx_conf

    if ! nginx -t; then
        mv "$main_backup" "$NGINX_CONF"
        if [[ -n "$conf_backup" ]]; then mv "$conf_backup" "$CASCADE_STREAM_CONF"; else rm -f "$CASCADE_STREAM_CONF"; fi
        log_error "Конфигурация nginx невалидна, изменения откачены"
    fi
    rm -f "$main_backup" "$conf_backup"

    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl reload-or-restart nginx
    printf '%s\n' "${CASCADE_EXITS[@]}" > "$CASCADE_EXITS_FILE"

    setup_cascade_logrotate

    ufw_allow_ssh
    for port in "${CASCADE_PORTS[@]}"; do
        log_info "UFW: открываю ${port}/tcp"
        ufw allow "${port}/tcp" comment 'cascade' >/dev/null
    done
    if ! ufw status | grep -q '^Status: active'; then
        log_info "Включение ufw..."
        ufw --force enable
    fi
    tune_conntrack

    check_cascade_exits
    check_cascade_capacity

    echo
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Вход каскада настроен${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "  Вход:      ${YELLOW}${CASCADE_ENTRY} → ${SERVER_IP}${NC}"
    echo -e "  Порты:     ${YELLOW}${CASCADE_PORTS[*]}${NC}"
    echo -e "  Выходы:    ${YELLOW}${CASCADE_EXITS[*]}${NC}"
    echo -e "  Журнал:    ${YELLOW}tail -f ${CASCADE_LOG}${NC}"
    echo -e "  Хостов в панели: ${YELLOW}$(( ${#CASCADE_EXITS[@]} * ${#CASCADE_PORTS[@]} ))${NC} (выход × порт): address = ${CASCADE_ENTRY}, sni = домен выхода,"
    echo -e "  inbound профиля выхода, overrideSniFromAddress выключен"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
}

# ─── Сценарии ─────────────────────────────────────────────────────────────────
run_issue() {
    read -rp "Введите домен (например sni.example.com): " DOMAIN
    [[ -z "$DOMAIN" ]] && log_error "Домен не может быть пустым"

    install_deps
    ensure_cf_creds
    ensure_server_ip

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
