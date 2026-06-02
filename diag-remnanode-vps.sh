#!/usr/bin/env bash
# ============================================================
# Remnawave Node — Full Diagnostics Script
# Version: 1.2 | Fixed
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
REMNAWAVE_CONTAINER="${REMNAWAVE_CONTAINER:-remnanode}"
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
section() {
    log ""
    log "${BOLD}${BLUE}══════════════════════════════════════════════════${RESET}"
    log "${BOLD}${BLUE}  $*${RESET}"
    log "${BOLD}${BLUE}══════════════════════════════════════════════════${RESET}"
}

require_tool() {
    command -v "$1" &>/dev/null || { warn "Утилита '$1' не найдена — пропускаем блок"; return 1; }
}

# Безопасное получение числа из команды
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

    # Uptime
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
    local oom_count
    oom_count=0
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
# 2. СЕТЬ — ПОТЕРЯ ПАКЕТОВ
# ════════════════════════════════════════════════════════════
check_network() {
    section "2. СЕТЬ"

    # ── Интерфейсы ──
    info "Сетевые интерфейсы:"
    ip -brief addr show | tee -a "$LOG_FILE"

    # ── Ping & packet loss ──
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

    # ── MTU проверка ──
    if require_tool ping; then
        info "Проверка MTU (тест фрагментации)..."
        local mtu_ok=true
        for size in 1400 1450 1472; do
            if ! ping -c 2 -M do -s "$size" "$PING_TARGET" &>/dev/null; then
                warn "MTU: пакеты размером $((size+28))B не проходят без фрагментации"
                mtu_ok=false
                break
            fi
        done
        $mtu_ok && ok "MTU 1500 — пакеты проходят нормально"
    fi

    # ── TCP BBR / буферы ──
    section "  TCP/UDP НАСТРОЙКИ ЯДРА"
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    info "Алгоритм TCP CC: $cc"
    [[ "$cc" != "bbr" ]] && warn "Рекомендуется BBR: sysctl -w net.ipv4.tcp_congestion_control=bbr"

    for param in \
        net.core.rmem_max \
        net.core.wmem_max \
        net.core.netdev_max_backlog \
        net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem \
        net.ipv4.udp_mem \
        net.ipv4.tcp_retries2 \
        net.ipv4.tcp_fin_timeout; do
        local val
        val=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
        info "$param = $val"
    done

    # ── Dropped пакеты на интерфейсах ──
    section "  RX/TX DROPPED ПАКЕТЫ"
    local found_drops=false
    while IFS= read -r iface; do
        local rx_drop tx_drop rx_err tx_err
        rx_drop=$(safe_int "$(cat "/sys/class/net/$iface/statistics/rx_dropped"  2>/dev/null || echo 0)")
        tx_drop=$(safe_int "$(cat "/sys/class/net/$iface/statistics/tx_dropped"  2>/dev/null || echo 0)")
        rx_err=$(safe_int  "$(cat "/sys/class/net/$iface/statistics/rx_errors"   2>/dev/null || echo 0)")
        tx_err=$(safe_int  "$(cat "/sys/class/net/$iface/statistics/tx_errors"   2>/dev/null || echo 0)")
        info "$iface → rx_drop=$rx_drop tx_drop=$tx_drop rx_err=$rx_err tx_err=$tx_err"
        if (( rx_drop > 100 || tx_drop > 100 || rx_err > 0 || tx_err > 0 )); then
            crit "$iface: высокое число dropped/errors!"
            found_drops=true
        fi
    done < <(ls /sys/class/net/ | grep -v lo)
    $found_drops || ok "Dropped пакеты на интерфейсах в норме"

    # ── ss / conntrack ──
    section "  СОЕДИНЕНИЯ"
    if require_tool ss; then
        local estab tw close_wait
        estab=$(safe_int "$(ss -ant | grep -c ESTAB || echo 0)")
        tw=$(safe_int     "$(ss -ant | grep -c TIME-WAIT || echo 0)")
        close_wait=$(safe_int "$(ss -ant | grep -c CLOSE-WAIT || echo 0)")
        info "Established: $estab | TIME-WAIT: $tw | CLOSE-WAIT: $close_wait"
        (( tw > 5000 ))        && warn "Много TIME-WAIT соединений ($tw)"
        (( close_wait > 500 )) && warn "Много CLOSE-WAIT соединений ($close_wait)"
    fi

    # conntrack переполнение
    local ct_cur ct_max
    ct_cur=$(safe_int "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)")
    ct_max=$(safe_int "$(cat /proc/sys/net/netfilter/nf_conntrack_max   2>/dev/null || echo 0)")
    if (( ct_max > 0 )); then
        local ct_pct
        ct_pct=$(awk "BEGIN{printf \"%.0f\", ($ct_cur/$ct_max)*100}")
        info "Conntrack: $ct_cur / $ct_max (${ct_pct}%)"
        (( ct_pct >= 80 )) && crit "Conntrack таблица заполнена на ${ct_pct}%! Пакеты будут дропаться!"
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

    # ── Статус контейнера ──
    info "Все контейнеры:"
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | tee -a "$LOG_FILE"

    if docker ps --format '{{.Names}}' | grep -q "^${REMNAWAVE_CONTAINER}$"; then
        ok "Контейнер '$REMNAWAVE_CONTAINER' запущен"
    else
        crit "Контейнер '$REMNAWAVE_CONTAINER' НЕ запущен!"
    fi

    # ── Ресурсы контейнера ──
    section "  РЕСУРСЫ КОНТЕЙНЕРОВ"
    docker stats --no-stream --format \
        "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}" \
        2>/dev/null | tee -a "$LOG_FILE"

    # ── Рестарты ──
    section "  РЕСТАРТЫ"
    local restarts
    restarts=$(docker inspect "$REMNAWAVE_CONTAINER" \
               --format '{{.RestartCount}}' 2>/dev/null || echo "0")
    restarts=$(safe_int "$restarts")
    info "Количество рестартов '$REMNAWAVE_CONTAINER': $restarts"
    if (( restarts > 5 )); then
        crit "Контейнер перезапускался $restarts раз!"
    fi

    # ── Последние логи ──
    section "  ЛОГИ КОНТЕЙНЕРА (последние 80 строк)"
    docker logs --tail=80 --timestamps "$REMNAWAVE_CONTAINER" 2>&1 \
        | tee -a "$LOG_FILE" || warn "Не удалось получить логи контейнера"

    # ── Ошибки в логах ──
    section "  ОШИБКИ В ЛОГАХ"
    local err_count
    err_count=$(safe_int "$(docker logs --tail=500 "$REMNAWAVE_CONTAINER" 2>&1 \
        | grep -ciE 'error|fatal|panic|timeout|refused|reset by peer|broken pipe|EOF' \
        || echo 0)")
    info "Найдено строк с ошибками (last 500): $err_count"
    (( err_count > 20 )) && crit "Много ошибок в логах контейнера: $err_count"

    # ── Сеть Docker ──
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

    # Конфиг — валидация
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
# 10. ИТОГОВЫЙ ОТЧЁТ
# ════════════════════════════════════════════════════════════
print_summary() {
    log ""
    log "${BOLD}${BLUE}╔══════════════════════════════════════════════════╗${RESET}"
    log "${BOLD}${BLUE}║           ИТОГИ ДИАГНОСТИКИ                      ║${RESET}"
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

    if (( CRIT > 0 )); then
        log "${BOLD}${CYAN}  ЧАСТЫЕ ПРИЧИНЫ ПОТЕРИ ПАКЕТОВ (checklist):${RESET}"
        log "  • Conntrack переполнен → увеличить nf_conntrack_max"
        log "  • MTU mismatch → установить MTU 1400-1450 на интерфейсе VPN"
        log "  • TCP CC не BBR → включить BBR + fq qdisc"
        log "  • RX/TX buffers малы → увеличить rmem_max / wmem_max"
        log "  • Контейнер падает → проверить логи и restart policy"
        log "  • Firewall DROP → проверить iptables/nftables"
        log ""
    fi
}

# ════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════
main() {
    # Создаём лог-файл
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/remnawave_diag_$(date +%Y%m%d_%H%M%S).log"

    # Ловушка на ошибки — не падаем, просто сообщаем
    trap 'log "${YELLOW}  ⚠ Нефатальная ошибка на строке $LINENO (команда: $BASH_COMMAND) — продолжаем...${RESET}"' ERR

    log "${BOLD}${BLUE}"
    log "  ██████╗ ███████╗███╗   ███╗███╗   ██╗ █████╗ "
    log "  ██╔══██╗██╔════╝████╗ ████║████╗  ██║██╔══██╗"
    log "  ██████╔╝█████╗  ██╔████╔██║██╔██╗ ██║███████║"
    log "  ██╔══██╗██╔══╝  ██║╚██╔╝██║██║╚██╗██║██╔══██║"
    log "  ██║  ██║███████╗██║ ╚═╝ ██║██║ ╚████║██║  ██║"
    log "  ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝"
    log "  NODE DIAGNOSTICS v1.2 — $(date)"
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
    print_summary
}

main "$@"