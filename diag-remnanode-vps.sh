#!/usr/bin/env bash
# ============================================================
# Remnawave Node — Full Diagnostics Script
# Version: 1.4
# ============================================================

set -uo pipefail

# ─── Цвета ───────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Конфиг ──────────────────────────────────────────────────
LOG_FILE="/var/log/remnawave_diag_$(date +%Y%m%d_%H%M%S).log"
REMNAWAVE_CONTAINER="${REMNAWAVE_CONTAINER:-remnawave-node}"
REMNAWAVE_PORT="${REMNAWAVE_PORT:-2222}"
XRAY_BINARY="/usr/local/bin/xray"
PACKET_LOSS_THRESHOLD=5
PING_TARGET="${PING_TARGET:-8.8.8.8}"
DISK_THRESHOLD=85
RAM_THRESHOLD=90
CPU_THRESHOLD=90

# ─── Счётчики ────────────────────────────────────────────────
WARN=0
CRIT=0

# ─── Утилиты вывода ──────────────────────────────────────────
log()  { echo -e "$*" | tee -a "$LOG_FILE"; }
ok()   { log "${GREEN}  ✔ $*${RESET}"; }
warn() { log "${YELLOW}  ⚠ WARNING: $*${RESET}"; WARN=$(( WARN + 1 )); }
crit() { log "${RED}  ✖ CRITICAL: $*${RESET}"; CRIT=$(( CRIT + 1 )); }
info() { log "${CYAN}  ➜ $*${RESET}"; }
fix()  { log "${YELLOW}  ℹ FIX: $*${RESET}"; }
section() {
    log ""
    log "${BOLD}${BLUE}══════════════════════════════════════════════════${RESET}"
    log "${BOLD}${BLUE}  $*${RESET}"
    log "${BOLD}${BLUE}══════════════════════════════════════════════════${RESET}"
}

require_tool() {
    command -v "$1" &>/dev/null || { warn "Утилита '$1' не найдена — пропускаем блок"; return 1; }
}

safe_int() {
    local val
    val=$(echo "${1:-0}" | head -1 | tr -d '[:space:]')
    [[ "$val" =~ ^[0-9]+$ ]] && echo "$val" || echo 0
}

# ════════════════════════════════════════════════════════════
# 1. СИСТЕМА
# ════════════════════════════════════════════════════════════
check_system() {
    section "1. СИСТЕМНЫЕ РЕСУРСЫ"

    info "Uptime: $(uptime -p 2>/dev/null || uptime)"

    # ── CPU ──
    local load1 cores cpu_pct
    load1=$(awk '{print $1}' /proc/loadavg)
    cores=$(nproc)
    cpu_pct=$(awk "BEGIN{printf \"%.0f\", ($load1/$cores)*100}")
    info "Load avg (1m): $load1 | Cores: $cores | CPU usage ≈ ${cpu_pct}%"
    if (( cpu_pct >= CPU_THRESHOLD )); then
        crit "CPU перегружен: ${cpu_pct}% (порог ${CPU_THRESHOLD}%)"
    else
        ok "CPU в норме: ${cpu_pct}%"
    fi

    # ── RAM ──
    local ram_total ram_used ram_pct
    ram_total=$(free -m | awk '/^Mem:/{print $2}')
    ram_used=$(free -m  | awk '/^Mem:/{print $3}')
    ram_pct=$(awk "BEGIN{printf \"%.0f\", ($ram_used/$ram_total)*100}")
    info "RAM: ${ram_used}MB / ${ram_total}MB (${ram_pct}%)"
    if (( ram_pct >= RAM_THRESHOLD )); then
        crit "RAM почти полна: ${ram_pct}% (порог ${RAM_THRESHOLD}%)"
    else
        ok "RAM в норме: ${ram_pct}%"
    fi

    # ── Swap ──
    local swap_total swap_used
    swap_total=$(free -m | awk '/^Swap:/{print $2}')
    swap_used=$(free -m  | awk '/^Swap:/{print $3}')
    if (( swap_total > 0 )); then
        info "Swap: ${swap_used}MB / ${swap_total}MB"
        if (( swap_used > swap_total / 2 )); then
            warn "Высокое использование Swap — возможна нехватка RAM"
        fi
    else
        warn "Swap не настроен — риск OOM при пиках"
    fi

    # ── Диск ──
    section "  ДИСК"
    while IFS= read -r line; do
        local pct mnt
        pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
        mnt=$(echo "$line" | awk '{print $6}')
        pct=$(safe_int "$pct")
        info "$line"
        if (( pct >= DISK_THRESHOLD )); then
            crit "Диск $mnt заполнен на ${pct}% (порог ${DISK_THRESHOLD}%)"
        fi
    done < <(df -h | awk 'NR>1 && $6 ~ /^\// {print}')

    # ── Inode ──
    while IFS= read -r line; do
        local ipct imnt
        ipct=$(echo "$line" | awk '{print $5}' | tr -d '%')
        imnt=$(echo "$line" | awk '{print $6}')
        ipct=$(safe_int "$ipct")
        if (( ipct >= 90 )); then
            crit "Inode $imnt заполнены на ${ipct}%"
        fi
    done < <(df -i | awk 'NR>1 && $5+0 >= 90 {print}')

    # ── OOM Killer ──
    section "  OOM / KERNEL ERRORS"
    local oom_count=0
    if [ -f /var/log/kern.log ]; then
        oom_count=$(safe_int "$(grep -c 'Out of memory' /var/log/kern.log 2>/dev/null || echo 0)")
    elif command -v journalctl &>/dev/null; then
        oom_count=$(safe_int "$(journalctl -k --no-pager -q 2>/dev/null \
            | grep -c 'Out of memory' || echo 0)")
    fi
    if (( oom_count > 0 )); then
        crit "OOM Killer срабатывал $oom_count раз(а) — смотри логи ядра!"
    else
        ok "OOM событий не найдено"
    fi
}

# ════════════════════════════════════════════════════════════
# 2. СЕТЬ
# ════════════════════════════════════════════════════════════
check_network() {
    section "2. СЕТЬ"

    info "Сетевые интерфейсы:"
    ip -brief addr show | tee -a "$LOG_FILE"

    if require_tool ping; then
        local loss
        loss=$(ping -c 20 -i 0.2 -W 2 "$PING_TARGET" 2>&1 \
               | grep -oP '\d+(?=% packet loss)' | head -1 || echo "100")
        loss=$(safe_int "$loss")
        info "Ping $PING_TARGET — потеря пакетов: ${loss}%"
        if (( loss >= PACKET_LOSS_THRESHOLD )); then
            crit "Потеря пакетов: ${loss}% (порог ${PACKET_LOSS_THRESHOLD}%)"
        else
            ok "Потеря пакетов: ${loss}%"
        fi
    fi

    # ── Routing ──
    section "  МАРШРУТИЗАЦИЯ"
    info "Таблица маршрутов:"
    ip route show | tee -a "$LOG_FILE"
    ip -6 route show 2>/dev/null | tee -a "$LOG_FILE" || true
}

# ════════════════════════════════════════════════════════════
# 3. FIREWALL
# ════════════════════════════════════════════════════════════
check_firewall() {
    section "3. FIREWALL / IPTABLES"

    if require_tool iptables; then
        info "iptables INPUT chain:"
        iptables -L INPUT -nv --line-numbers 2>/dev/null | tee -a "$LOG_FILE" || true

        if iptables -L INPUT -nv 2>/dev/null | grep -qE "DROP|REJECT"; then
            warn "Обнаружены DROP/REJECT правила в INPUT — проверьте порт $REMNAWAVE_PORT"
        fi
    fi

    if require_tool nft; then
        info "nftables ruleset (краткий вывод):"
        nft list ruleset 2>/dev/null | head -60 | tee -a "$LOG_FILE" || true
    fi

    if require_tool ufw; then
        info "UFW статус:"
        ufw status numbered 2>/dev/null | tee -a "$LOG_FILE" || true
    fi
}

# ════════════════════════════════════════════════════════════
# 4. DOCKER / КОНТЕЙНЕР
# ════════════════════════════════════════════════════════════
check_docker() {
    section "4. DOCKER"

    require_tool docker || return

    info "Все контейнеры:"
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | tee -a "$LOG_FILE"

    if docker ps --format '{{.Names}}' | grep -q "^${REMNAWAVE_CONTAINER}$"; then
        ok "Контейнер '$REMNAWAVE_CONTAINER' запущен"
    else
        crit "Контейнер '$REMNAWAVE_CONTAINER' НЕ запущен!"
    fi

    section "  РЕСУРСЫ КОНТЕЙНЕРОВ"
    docker stats --no-stream --format \
        "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}" \
        2>/dev/null | tee -a "$LOG_FILE"

    section "  РЕСТАРТЫ"
    local restarts
    restarts=$(safe_int "$(docker inspect "$REMNAWAVE_CONTAINER" \
               --format '{{.RestartCount}}' 2>/dev/null || echo 0)")
    info "Количество рестартов '$REMNAWAVE_CONTAINER': $restarts"
    if (( restarts > 5 )); then
        crit "Контейнер перезапускался $restarts раз!"
    fi

    section "  ЛОГИ КОНТЕЙНЕРА (последние 80 строк)"
    docker logs --tail=80 --timestamps "$REMNAWAVE_CONTAINER" 2>&1 \
        | tee -a "$LOG_FILE" || warn "Не удалось получить логи контейнера"

    section "  ОШИБКИ В ЛОГАХ"
    local err_count
    err_count=$(safe_int "$(docker logs --tail=500 "$REMNAWAVE_CONTAINER" 2>&1 \
        | grep -ciE 'error|fatal|panic|timeout|refused|reset by peer|broken pipe|EOF' \
        || echo 0)")
    info "Найдено строк с ошибками (last 500): $err_count"
    (( err_count > 20 )) && crit "Много ошибок в логах контейнера: $err_count"

    section "  DOCKER NETWORK"
    local net_id
    net_id=$(docker inspect "$REMNAWAVE_CONTAINER" \
        --format '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' 2>/dev/null || echo "")
    if [[ -n "$net_id" ]]; then
        docker network inspect "$net_id" 2>/dev/null \
            | python3 -m json.tool 2>/dev/null | head -50 | tee -a "$LOG_FILE" || true
    fi
}

# ════════════════════════════════════════════════════════════
# 5. XRAY / ЯДРО НОДЫ
# ════════════════════════════════════════════════════════════
check_xray() {
    section "5. XRAY CORE"

    if docker exec "$REMNAWAVE_CONTAINER" xray version &>/dev/null; then
        local ver
        ver=$(docker exec "$REMNAWAVE_CONTAINER" xray version 2>/dev/null | head -1)
        info "Версия Xray (в контейнере): $ver"
    elif [ -x "$XRAY_BINARY" ]; then
        info "Версия Xray (host): $($XRAY_BINARY version | head -1)"
    else
        warn "xray binary не найден — проверьте путь"
    fi

    local cfg_path
    cfg_path=$(docker inspect "$REMNAWAVE_CONTAINER" \
               --format '{{range .Mounts}}{{if eq .Destination "/etc/xray"}}{{.Source}}{{end}}{{end}}' \
               2>/dev/null || echo "")
    if [[ -n "$cfg_path" && -f "$cfg_path/config.json" ]]; then
        info "Конфиг найден: $cfg_path/config.json"
        if python3 -m json.tool "$cfg_path/config.json" > /dev/null 2>&1; then
            ok "config.json — валидный JSON"
        else
            crit "config.json — НЕВАЛИДНЫЙ JSON!"
        fi
    else
        info "Путь к конфигу xray не определён автоматически"
    fi
}

# ════════════════════════════════════════════════════════════
# 6. ПОРТ НОДЫ
# ════════════════════════════════════════════════════════════
check_ports() {
    section "6. ПОРТЫ"

    info "Прослушиваемые порты (ss):"
    ss -tlnup | tee -a "$LOG_FILE"

    if ss -tlnup | grep -q ":${REMNAWAVE_PORT}"; then
        ok "Порт $REMNAWAVE_PORT слушается"
    else
        crit "Порт $REMNAWAVE_PORT НЕ слушается!"
    fi

    for port in 80 443 8080 8443; do
        if ss -tlnup | grep -q ":$port "; then
            info "Порт $port — ЗАНЯТ"
        fi
    done
}

# ════════════════════════════════════════════════════════════
# 7. TLS / СЕРТИФИКАТЫ
# ════════════════════════════════════════════════════════════
check_tls() {
    section "7. TLS / СЕРТИФИКАТЫ"

    require_tool openssl || return

    local cert_dirs=("/etc/ssl" "/etc/letsencrypt/live" "/opt/remnawave" "/var/lib/remnawave")
    local found_cert=false

    for dir in "${cert_dirs[@]}"; do
        if [ ! -d "$dir" ]; then continue; fi
        while IFS= read -r cert; do
            local expiry days_left
            expiry=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2 || echo "")
            if [[ -n "$expiry" ]]; then
                found_cert=true
                days_left=$(( ( $(date -d "$expiry" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
                info "Сертификат $cert истекает: $expiry (через $days_left дней)"
                if (( days_left < 14 )); then
                    crit "Сертификат $cert истекает через $days_left дней!"
                elif (( days_left < 30 )); then
                    warn "Сертификат $cert истекает через $days_left дней"
                else
                    ok "Сертификат $cert в порядке ($days_left дней)"
                fi
            fi
        done < <(find "$dir" -name "*.crt" -o -name "fullchain.pem" 2>/dev/null)
    done

    $found_cert || info "Сертификаты в стандартных путях не найдены"

    if ss -tlnup | grep -q ":443"; then
        info "Тест TLS handshake на localhost:443..."
        echo | timeout 5 openssl s_client -connect "127.0.0.1:443" -brief 2>&1 \
            | head -5 | tee -a "$LOG_FILE" || warn "TLS handshake не удался"
    fi
}

# ════════════════════════════════════════════════════════════
# 8. СИСТЕМНЫЕ ЛОГИ
# ════════════════════════════════════════════════════════════
check_system_logs() {
    section "8. СИСТЕМНЫЕ ЛОГИ"

    if command -v journalctl &>/dev/null; then
        info "Kernel сетевые ошибки (последние 30 мин):"
        journalctl -k --since "30 min ago" --no-pager -q 2>/dev/null \
            | grep -iE "dropped|error|fail|nf_conntrack|NETERR" \
            | tail -30 | tee -a "$LOG_FILE" || true

        info "Segfaults / OOM (последние 24ч):"
        journalctl --since "24h ago" --no-pager -q 2>/dev/null \
            | grep -iE "segfault|oom.killer|killed process" \
            | tail -20 | tee -a "$LOG_FILE" || true
    else
        warn "journalctl недоступен — пропускаем системные логи"
    fi

    info "I/O ошибки (dmesg):"
    dmesg 2>/dev/null | grep -iE "I/O error|EXT4-fs error|XFS" \
        | tail -10 | tee -a "$LOG_FILE" || true
}

# ════════════════════════════════════════════════════════════
# 9. LATENCY ТРАССИРОВКА
# ════════════════════════════════════════════════════════════
check_latency() {
    section "9. ТРАССИРОВКА МАРШРУТА"

    if command -v mtr &>/dev/null; then
        info "MTR отчёт до $PING_TARGET:"
        mtr --report --report-cycles 10 -n "$PING_TARGET" 2>/dev/null \
            | tee -a "$LOG_FILE" || warn "mtr завершился с ошибкой"
    elif command -v traceroute &>/dev/null; then
        info "Traceroute до $PING_TARGET (макс 15 хопов):"
        traceroute -n -w 2 -m 15 "$PING_TARGET" 2>/dev/null \
            | tee -a "$LOG_FILE" || warn "traceroute завершился с ошибкой"
    else
        warn "Ни mtr, ни traceroute не найдены — пропускаем трассировку"
    fi
}

# ════════════════════════════════════════════════════════════
# 10. ПРОВЕРКА ТИПИЧНЫХ ПРИЧИН ПОТЕРИ ПАКЕТОВ
# ════════════════════════════════════════════════════════════
check_packet_loss_reasons() {
    section "10. ПРОВЕРКА ПРИЧИН ПОТЕРИ ПАКЕТОВ"

    # ────────────────────────────────────────────────────────
    # 10.1 CONNTRACK
    # ────────────────────────────────────────────────────────
    log ""
    log "${BOLD}  [10.1] Conntrack (таблица соединений)${RESET}"

    local ct_cur ct_max ct_pct
    ct_cur=$(safe_int "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)")
    ct_max=$(safe_int "$(cat /proc/sys/net/netfilter/nf_conntrack_max   2>/dev/null || echo 0)")

    if (( ct_max == 0 )); then
        warn "Conntrack модуль не загружен или недоступен"
    else
        ct_pct=$(awk "BEGIN{printf \"%.0f\", ($ct_cur/$ct_max)*100}")
        info "Текущее количество соединений: $ct_cur"
        info "Максимум соединений (max):     $ct_max"
        info "Заполнено:                     ${ct_pct}%"

        if (( ct_pct >= 90 )); then
            crit "Conntrack ПЕРЕПОЛНЕН на ${ct_pct}% — новые пакеты ДРОПАЮТСЯ прямо сейчас!"
            fix "Нужно увеличить: sysctl -w net.netfilter.nf_conntrack_max=524288"
        elif (( ct_pct >= 70 )); then
            warn "Conntrack заполнен на ${ct_pct}% — приближается к лимиту"
            fix "Рекомендуется увеличить nf_conntrack_max до 524288"
        else
            ok "Conntrack в норме: ${ct_cur}/${ct_max} (${ct_pct}%)"
        fi

        # Проверка таймаутов — слишком большие значения держат старые соединения
        local tcp_est_timeout
        tcp_est_timeout=$(safe_int "$(sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established 2>/dev/null || echo 0)")
        info "Таймаут established соединений: ${tcp_est_timeout}s"
        if (( tcp_est_timeout > 3600 )); then
            warn "Таймаут established слишком большой (${tcp_est_timeout}s) — старые соединения занимают место"
            fix "Рекомендуется: sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=600"
        else
            ok "Таймаут established соединений в норме: ${tcp_est_timeout}s"
        fi
    fi

    # ────────────────────────────────────────────────────────
    # 10.2 MTU
    # ────────────────────────────────────────────────────────
    log ""
    log "${BOLD}  [10.2] MTU (максимальный размер пакета)${RESET}"

    # Показываем MTU всех интерфейсов
    info "MTU всех сетевых интерфейсов:"
    while IFS= read -r iface; do
        local mtu
        mtu=$(safe_int "$(cat "/sys/class/net/$iface/mtu" 2>/dev/null || echo 0)")
        info "  $iface → MTU = $mtu"
        if [[ "$iface" =~ ^(tun|wg|vp|ppp) ]]; then
            if (( mtu > 1450 )); then
                warn "VPN-интерфейс $iface имеет MTU=$mtu — может вызывать фрагментацию пакетов"
                fix "Рекомендуется установить MTU 1400-1450: ip link set dev $iface mtu 1400"
            else
                ok "VPN-интерфейс $iface MTU=$mtu — в допустимом диапазоне"
            fi
        fi
    done < <(ls /sys/class/net/ | grep -v lo)

    # Практический тест — пингуем с разными размерами пакетов
    info "Практический тест MTU (пинг без фрагментации):"
    local mtu_max_ok=0
    for size in 1200 1300 1350 1400 1420 1450 1472; do
        if ping -c 2 -W 2 -M do -s "$size" "$PING_TARGET" &>/dev/null; then
            mtu_max_ok=$size
        else
            info "  Размер $((size+28))B (payload=${size}B) — НЕ проходит"
            break
        fi
        info "  Размер $((size+28))B (payload=${size}B) — OK"
    done

    if (( mtu_max_ok > 0 )); then
        info "Максимальный рабочий MTU: $((mtu_max_ok+28))B"
        if (( mtu_max_ok < 1400 )); then
            crit "MTU очень низкий — максимум $((mtu_max_ok+28))B. Высокая вероятность проблем с пакетами!"
        elif (( mtu_max_ok < 1450 )); then
            warn "MTU ограничен до $((mtu_max_ok+28))B — пакеты крупнее будут фрагментироваться"
        else
            ok "MTU в норме — пакеты до $((mtu_max_ok+28))B проходят свободно"
        fi
    fi

    # ────────────────────────────────────────────────────────
    # 10.3 TCP BBR + fq qdisc
    # ────────────────────────────────────────────────────────
    log ""
    log "${BOLD}  [10.3] TCP Congestion Control + очередь пакетов${RESET}"

    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    info "Текущий алгоритм управления перегрузкой TCP: $cc"

    if [[ "$cc" == "bbr" ]]; then
        ok "TCP BBR включён — оптимально для VPN"
    else
        warn "Используется '$cc' вместо BBR — при потерях пакетов скорость упадёт сильнее"
        fix "Команда для включения BBR: sysctl -w net.ipv4.tcp_congestion_control=bbr"

        # Проверяем доступен ли BBR вообще
        if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
            info "BBR доступен в системе, но не активирован"
        else
            warn "BBR может быть недоступен — ядро старше 4.9 или модуль не загружен"
        fi
    fi

    # Проверка qdisc
    local qdisc_info
    if require_tool tc; then
        info "Текущая дисциплина очереди пакетов (qdisc):"
        tc qdisc show 2>/dev/null | tee -a "$LOG_FILE" || true

        local default_qdisc
        default_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
        info "Default qdisc: $default_qdisc"

        if [[ "$default_qdisc" == "fq" || "$default_qdisc" == "fq_codel" ]]; then
            ok "Qdisc '$default_qdisc' — подходит для работы с BBR"
        else
            warn "Qdisc '$default_qdisc' — рекомендуется 'fq' вместе с BBR"
            fix "Команда: sysctl -w net.core.default_qdisc=fq"
        fi
    fi

    # ────────────────────────────────────────────────────────
    # 10.4 RX/TX БУФЕРЫ
    # ────────────────────────────────────────────────────────
    log ""
    log "${BOLD}  [10.4] Сетевые буферы RX/TX${RESET}"

    # Минимальные рекомендуемые значения
    local rmem_max wmem_max
    rmem_max=$(safe_int "$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)")
    wmem_max=$(safe_int "$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)")

    info "net.core.rmem_max (буфер приёма):  $rmem_max байт ($(( rmem_max / 1024 / 1024 ))MB)"
    info "net.core.wmem_max (буфер отправки): $wmem_max байт ($(( wmem_max / 1024 / 1024 ))MB)"

    # rmem_max
    if (( rmem_max < 16777216 )); then
        crit "Буфер приёма (rmem_max) слишком мал: $rmem_max байт — пакеты будут теряться при высокой нагрузке"
        fix "Рекомендуется: sysctl -w net.core.rmem_max=134217728"
    elif (( rmem_max < 67108864 )); then
        warn "Буфер приёма (rmem_max) небольшой: $rmem_max байт"
        fix "Рекомендуется увеличить до 134217728"
    else
        ok "Буфер приёма rmem_max в норме: $rmem_max байт"
    fi

    # wmem_max
    if (( wmem_max < 16777216 )); then
        crit "Буфер отправки (wmem_max) слишком мал: $wmem_max байт — пакеты будут теряться при высокой нагрузке"
        fix "Рекомендуется: sysctl -w net.core.wmem_max=134217728"
    elif (( wmem_max < 67108864 )); then
        warn "Буфер отправки (wmem_max) небольшой: $wmem_max байт"
        fix "Рекомендуется увеличить до 134217728"
    else
        ok "Буфер отправки wmem_max в норме: $wmem_max байт"
    fi

    # Дополнительные буферные параметры
    local backlog netdev_backlog
    backlog=$(safe_int     "$(sysctl -n net.core.somaxconn         2>/dev/null || echo 0)")
    netdev_backlog=$(safe_int "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo 0)")

    info "net.core.somaxconn (очередь TCP):          $backlog"
    info "net.core.netdev_max_backlog (очередь NIC): $netdev_backlog"

    (( backlog < 1024 )) && warn "somaxconn=$backlog мал — увеличь до 65535" \
                         || ok "somaxconn=$backlog в норме"
    (( netdev_backlog < 5000 )) && warn "netdev_max_backlog=$netdev_backlog мал — увеличь до 50000" \
                                || ok "netdev_max_backlog=$netdev_backlog в норме"

    # Dropped пакеты на интерфейсах
    log ""
    log "${BOLD}  Dropped пакеты на сетевых интерфейсах:${RESET}"
    local found_drops=false
    while IFS= read -r iface; do
        local rx_drop tx_drop rx_err tx_err
        rx_drop=$(safe_int "$(cat "/sys/class/net/$iface/statistics/rx_dropped"  2>/dev/null || echo 0)")
        tx_drop=$(safe_int "$(cat "/sys/class/net/$iface/statistics/tx_dropped"  2>/dev/null || echo 0)")
        rx_err=$(safe_int  "$(cat "/sys/class/net/$iface/statistics/rx_errors"   2>/dev/null || echo 0)")
        tx_err=$(safe_int  "$(cat "/sys/class/net/$iface/statistics/tx_errors"   2>/dev/null || echo 0)")
        info "$iface → rx_drop=$rx_drop  tx_drop=$tx_drop  rx_err=$rx_err  tx_err=$tx_err"
        if (( rx_drop > 100 || tx_drop > 100 || rx_err > 0 || tx_err > 0 )); then
            crit "$iface: обнаружены потери пакетов на уровне сетевого интерфейса!"
            fix "Возможные причины: буферы малы, перегрузка NIC, неверный MTU"
            found_drops=true
        fi
    done < <(ls /sys/class/net/ | grep -v lo)
    $found_drops || ok "Dropped пакеты на интерфейсах в норме"

    # ────────────────────────────────────────────────────────
    # 10.5 КОНТЕЙНЕР — СТАБИЛЬНОСТЬ
    # ────────────────────────────────────────────────────────
    log ""
    log "${BOLD}  [10.5] Стабильность контейнера${RESET}"

    require_tool docker || return

    # Статус
    local container_status
    container_status=$(docker inspect "$REMNAWAVE_CONTAINER" \
        --format '{{.State.Status}}' 2>/dev/null || echo "not_found")
    info "Статус контейнера: $container_status"

    if [[ "$container_status" != "running" ]]; then
        crit "Контейнер не запущен! Статус: $container_status"
    fi

    # Рестарты
    local restarts
    restarts=$(safe_int "$(docker inspect "$REMNAWAVE_CONTAINER" \
        --format '{{.RestartCount}}' 2>/dev/null || echo 0)")
    info "Количество рестартов: $restarts"
    if (( restarts > 10 )); then
        crit "Контейнер перезапускался $restarts раз — явная нестабильность!"
        fix "Смотри логи: docker logs --tail=100 $REMNAWAVE_CONTAINER"
    elif (( restarts > 3 )); then
        warn "Контейнер перезапускался $restarts раз"
    else
        ok "Количество рестартов в норме: $restarts"
    fi

    # Restart policy
    local restart_policy
    restart_policy=$(docker inspect "$REMNAWAVE_CONTAINER" \
        --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "unknown")
    info "Политика перезапуска (restart policy): $restart_policy"
    if [[ "$restart_policy" == "no" || "$restart_policy" == "" ]]; then
        warn "Restart policy = '$restart_policy' — контейнер не поднимется автоматически после падения!"
        fix "Рекомендуется: docker update --restart=unless-stopped $REMNAWAVE_CONTAINER"
    else
        ok "Restart policy: $restart_policy"
    fi

    # Время последнего старта
    local started_at
    started_at=$(docker inspect "$REMNAWAVE_CONTAINER" \
        --format '{{.State.StartedAt}}' 2>/dev/null || echo "unknown")
    info "Последний запуск контейнера: $started_at"

    # OOM Kill внутри контейнера
    local oom_killed
    oom_killed=$(docker inspect "$REMNAWAVE_CONTAINER" \
        --format '{{.State.OOMKilled}}' 2>/dev/null || echo "false")
    if [[ "$oom_killed" == "true" ]]; then
        crit "Контейнер был убит OOM Killer — не хватает памяти!"
        fix "Увеличь лимит памяти контейнера или добавь Swap на сервер"
    else
        ok "OOM Kill контейнера: не зафиксирован"
    fi

    # Ошибки в логах контейнера
    local err_count timeout_count refused_count
    err_count=$(safe_int "$(docker logs --tail=500 "$REMNAWAVE_CONTAINER" 2>&1 \
        | grep -ciE 'error|fatal|panic' || echo 0)")
    timeout_count=$(safe_int "$(docker logs --tail=500 "$REMNAWAVE_CONTAINER" 2>&1 \
        | grep -ciE 'timeout|timed out' || echo 0)")
    refused_count=$(safe_int "$(docker logs --tail=500 "$REMNAWAVE_CONTAINER" 2>&1 \
        | grep -ciE 'refused|reset by peer|broken pipe|EOF' || echo 0)")

    info "Ошибок в логах (error/fatal/panic): $err_count"
    info "Таймаутов в логах:                  $timeout_count"
    info "Обрывов соединений в логах:         $refused_count"

    (( err_count > 20 ))     && crit "Много критических ошибок в логах: $err_count" \
                              || ok "Критических ошибок в логах: $err_count"
    (( timeout_count > 10 )) && warn "Много таймаутов в логах: $timeout_count" \
                              || ok "Таймаутов в логах: $timeout_count"
    (( refused_count > 10 )) && warn "Много обрывов соединений в логах: $refused_count" \
                              || ok "Обрывов соединений в логах: $refused_count"

    # ────────────────────────────────────────────────────────
    # 10.6 FIREWALL — БЛОКИРОВКИ
    # ────────────────────────────────────────────────────────
    log ""
    log "${BOLD}  [10.6] Firewall — блокировки трафика${RESET}"

    # iptables — считаем DROP/REJECT правила с ненулевыми счётчиками пакетов
    if require_tool iptables; then
        local drop_rules_with_hits
        drop_rules_with_hits=$(iptables -L INPUT -nv 2>/dev/null \
            | awk '$1+0 > 0 && /DROP|REJECT/ {print}' || true)

        if [[ -n "$drop_rules_with_hits" ]]; then
            crit "Найдены активные DROP/REJECT правила с реальными срабатываниями:"
            echo "$drop_rules_with_hits" | while IFS= read -r rule; do
                log "${RED}    $rule${RESET}"
            done
            fix "Эти правила реально блокируют пакеты — проверь не попадает ли под них VPN-трафик"
        else
            ok "DROP/REJECT правил с реальными срабатываниями не обнаружено"
        fi

        # Проверяем конкретно порт ноды
        if iptables -L INPUT -nv 2>/dev/null | grep -qE "DROP|REJECT"; then
            # Ищем явные разрешения для порта ноды
            if iptables -L INPUT -nv 2>/dev/null | grep -q "$REMNAWAVE_PORT"; then
                ok "Порт $REMNAWAVE_PORT явно упомянут в правилах iptables"
            else
                warn "Порт $REMNAWAVE_PORT не найден в правилах iptables — может блокироваться по умолчанию"
                fix "Проверь: iptables -L INPUT -nv | grep $REMNAWAVE_PORT"
            fi
        fi

        # Политика по умолчанию для INPUT
        local input_policy
        input_policy=$(iptables -L INPUT 2>/dev/null | head -1 | grep -oP 'policy \K\w+' || echo "unknown")
        info "Политика INPUT по умолчанию: $input_policy"
        if [[ "$input_policy" == "DROP" ]]; then
            warn "Политика INPUT = DROP — весь трафик без явного разрешения блокируется"
            fix "Убедись что порт $REMNAWAVE_PORT разрешён: iptables -I INPUT -p tcp --dport $REMNAWAVE_PORT -j ACCEPT"
        else
            ok "Политика INPUT = $input_policy — трафик не блокируется по умолчанию"
        fi

        # FORWARD цепочка (важна для Docker)
        local forward_policy
        forward_policy=$(iptables -L FORWARD 2>/dev/null | head -1 | grep -oP 'policy \K\w+' || echo "unknown")
        info "Политика FORWARD по умолчанию: $forward_policy"
        if [[ "$forward_policy" == "DROP" ]]; then
            warn "Политика FORWARD = DROP — может блокировать трафик Docker-контейнеров!"
            fix "Docker требует: iptables -P FORWARD ACCEPT"
        else
            ok "Политика FORWARD = $forward_policy — Docker-трафик не блокируется"
        fi
    fi

    # nftables
    if command -v nft &>/dev/null; then
        local nft_drops
        nft_drops=$(nft list ruleset 2>/dev/null | grep -ciE 'drop|reject' || echo 0)
        nft_drops=$(safe_int "$nft_drops")
        info "Правил drop/reject в nftables: $nft_drops"
        if (( nft_drops > 0 )); then
            warn "В nftables есть $nft_drops drop/reject правил — проверь вручную: nft list ruleset"
        else
            ok "Drop/reject правил в nftables не обнаружено"
        fi
    fi

    # UFW
    if command -v ufw &>/dev/null; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
        info "UFW статус: $ufw_status"
        if [[ "$ufw_status" == "active" ]]; then
            if ufw status 2>/dev/null | grep -qE "ALLOW.*$REMNAWAVE_PORT|$REMNAWAVE_PORT.*ALLOW"; then
                ok "UFW активен и порт $REMNAWAVE_PORT разрешён"
            else
                crit "UFW активен, но порт $REMNAWAVE_PORT НЕ найден в разрешённых!"
                fix "Добавь правило: ufw allow $REMNAWAVE_PORT/tcp && ufw allow $REMNAWAVE_PORT/udp"
            fi
        else
            ok "UFW неактивен — не блокирует трафик"
        fi
    fi
}

# ════════════════════════════════════════════════════════════
# 11. ИТОГОВЫЙ ОТЧЁТ
# ════════════════════════════════════════════════════════════
print_summary() {
    log ""
    log "${BOLD}${BLUE}╔══════════════════════════════════════════════════╗${RESET}"
    log "${BOLD}${BLUE}║              ИТОГИ ДИАГНОСТИКИ                   ║${RESET}"
    log "${BOLD}${BLUE}╚══════════════════════════════════════════════════╝${RESET}"
    log ""

    if (( CRIT == 0 && WARN == 0 )); then
        log "${GREEN}${BOLD}  ✔ Всё в порядке! Проблем не обнаружено.${RESET}"
    else
        (( CRIT > 0 )) && log "${RED}${BOLD}  ✖ КРИТИЧЕСКИХ ПРОБЛЕМ: $CRIT${RESET}"
        (( WARN > 0 )) && log "${YELLOW}${BOLD}  ⚠ ПРЕДУПРЕЖДЕНИЙ:      $WARN${RESET}"
    fi

    log ""
    log "  📄 Полный отчёт сохранён: ${BOLD}$LOG_FILE${RESET}"
    log ""
}

# ════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════
main() {
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/remnawave_diag_$(date +%Y%m%d_%H%M%S).log"

    trap 'log "${YELLOW}  ⚠ Нефатальная ошибка на строке $LINENO (команда: $BASH_COMMAND) — продолжаем...${RESET}"' ERR

    log "${BOLD}${BLUE}"
    log "  ██████╗ ███████╗███╗   ███╗███╗   ██╗ █████╗ "
    log "  ██╔══██╗██╔════╝████╗ ████║████╗  ██║██╔══██╗"
    log "  ██████╔╝█████╗  ██╔████╔██║██╔██╗ ██║███████║"
    log "  ██╔══██╗██╔══╝  ██║╚██╔╝██║██║╚██╗██║██╔══██║"
    log "  ██║  ██║███████╗██║ ╚═╝ ██║██║ ╚████║██║  ██║"
    log "  ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝"
    log "  NODE DIAGNOSTICS v1.4 — $(date)"
    log "${RESET}"

    check_system
    check_network
    check_firewall
    check_docker
    check_xray
    check_ports
    check_tls
    check_system_logs
    check_latency
    check_packet_loss_reasons
    print_summary
}

main "$@"