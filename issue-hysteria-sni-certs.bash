#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

if [[ $# -eq 2 ]]; then
    DOMAIN="$1"
    CF_API_TOKEN="$2"
else
    read -rp "Введите домен (например sni.example.com): " DOMAIN
    read -rsp "Введите Cloudflare API Token: " CF_API_TOKEN
    echo
fi

[[ -z "$DOMAIN" ]]        && log_error "Домен не может быть пустым"
[[ -z "$CF_API_TOKEN" ]]  && log_error "Cloudflare API Token не может быть пустым"

[[ "$EUID" -ne 0 ]] && log_error "Скрипт должен запускаться от root"

log_info "Обновление пакетов и установка зависимостей..."
apt update -q
apt install -y -q certbot python3-certbot-dns-cloudflare

log_info "Создание файла Cloudflare credentials..."
mkdir -p /etc/letsencrypt/secrets
CF_CREDS_FILE="/etc/letsencrypt/secrets/cloudflare.ini"

cat > "$CF_CREDS_FILE" << EOF
dns_cloudflare_api_token = ${CF_API_TOKEN}
EOF

chmod 600 "$CF_CREDS_FILE"
log_info "Credentials сохранены в $CF_CREDS_FILE"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "caddy-selfsteal"; then
    log_warn "Останавливаю caddy-selfsteal..."
    docker stop caddy-selfsteal
fi

log_info "Получение сертификата для домена: $DOMAIN"

certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$CF_CREDS_FILE" \
    --dns-cloudflare-propagation-seconds 30 \
    -d "$DOMAIN" \
    --agree-tos \
    -m "admin@${DOMAIN}" \
    --non-interactive

log_info "Копирование сертификатов в /etc/xray/ssl..."
mkdir -p /etc/xray/ssl

cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" /etc/xray/ssl/cert.pem
cp "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"   /etc/xray/ssl/cert.key

log_info "Выставление прав на сертификаты..."
chmod 644 /etc/xray/ssl/cert.pem
chmod 600 /etc/xray/ssl/cert.key

log_info "Создание post-renewal hook для автоматического обновления..."
cat > /etc/letsencrypt/renewal-hooks/post/copy-to-xray.sh << EOF
#!/bin/bash
cp /etc/letsencrypt/live/${DOMAIN}/fullchain.pem /etc/xray/ssl/cert.pem
cp /etc/letsencrypt/live/${DOMAIN}/privkey.pem   /etc/xray/ssl/cert.key
chmod 644 /etc/xray/ssl/cert.pem
chmod 600 /etc/xray/ssl/cert.key
EOF

chmod +x /etc/letsencrypt/renewal-hooks/post/copy-to-xray.sh
log_info "Hook сохранён: при обновлении сертификат автоматически скопируется в /etc/xray/ssl"

if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "caddy-selfsteal"; then
    log_info "Запускаю caddy-selfsteal обратно..."
    docker start caddy-selfsteal
fi

echo
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  Готово!${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "  Домен:       ${YELLOW}${DOMAIN}${NC}"
echo -e "  Сертификат:  ${YELLOW}/etc/xray/ssl/cert.pem${NC}"
echo -e "  Ключ:        ${YELLOW}/etc/xray/ssl/cert.key${NC}"
echo -e "  Обновление:  ${YELLOW}автоматически через certbot renew${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"