#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- System dependencies ---
sudo apt update
sudo apt install -y git curl jq python3

# --- Docker check ---
if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker not found. Install it first (https://docs.docker.com/engine/install/)." >&2
  exit 1
fi

# --- Clone repos (если ещё нет) ---
[ -d CTFd ] || git clone https://github.com/CTFd/CTFd.git

# --- Спрашиваем BASE_DOMAIN (по умолчанию localhost) ---
# Приоритет: аргумент скрипта > переменная окружения > промпт > localhost
if [ "$#" -gt 0 ]; then
  BASE_DOMAIN="$1"
elif [ -n "${BASE_DOMAIN:-}" ]; then
  :
elif [ -t 0 ]; then
  read -r -p "BASE_DOMAIN [localhost]: " BASE_DOMAIN || true
fi
BASE_DOMAIN="${BASE_DOMAIN:-localhost}"
echo "Using BASE_DOMAIN=${BASE_DOMAIN}"

# forward scheme к контейнерам всегда http (TLS терминирует NPM)
FORWARD_SCHEME="http"

# --- Спрашиваем внешнюю схему (http|https, по умолчанию http) ---
# Схема, по которой пользователи обращаются к NPM извне
# Приоритет: переменная окружения > промпт > http
if [ -n "${EXTERNAL_SCHEME:-}" ]; then
  EXTERNAL_SCHEME="${EXTERNAL_SCHEME,,}"
else
  EXTERNAL_SCHEME=""
  if [ -t 0 ]; then
    read -r -p "External scheme (для пользователей) [http]: " EXTERNAL_SCHEME || true
  fi
  EXTERNAL_SCHEME="${EXTERNAL_SCHEME,,}"
fi
EXTERNAL_SCHEME="${EXTERNAL_SCHEME:-http}"
case "$EXTERNAL_SCHEME" in
  http|https) ;;
  *) echo "error: EXTERNAL_SCHEME должен быть http или https, получено '$EXTERNAL_SCHEME'" >&2; exit 1 ;;
esac
echo "Using EXTERNAL_SCHEME=${EXTERNAL_SCHEME}"

if [ "$EXTERNAL_SCHEME" = "https" ]; then
  # Проверяем, есть ли свои сертификаты локально (certs/ или явные пути)
  USE_CUSTOM_CERT=""
  if [ -n "${CERT_FILE:-}" ] && [ -n "${CERT_KEY_FILE:-}" ]; then
    USE_CUSTOM_CERT=1
  elif [ -f certs/fullchain.pem ] && [ -f certs/privkey.pem ]; then
    echo
    echo "  Найдены локальные сертификаты в ./certs:"
    echo "    fullchain.pem, privkey.pem"
    if [ -t 0 ]; then
      read -r -p "Использовать свои сертификаты? [Y/n]: " USE_CUSTOM_CERT || true
    fi
    USE_CUSTOM_CERT="$(echo "${USE_CUSTOM_CERT:-y}" | tr '[:upper:]' '[:lower:]')"
    if [ "$USE_CUSTOM_CERT" = "y" ] || [ "$USE_CUSTOM_CERT" = "yes" ]; then
      USE_CUSTOM_CERT=1
    else
      USE_CUSTOM_CERT=""
    fi
  fi

  if [ -n "$USE_CUSTOM_CERT" ]; then
    CERT_FILE="${CERT_FILE:-certs/fullchain.pem}"
    CERT_KEY_FILE="${CERT_KEY_FILE:-certs/privkey.pem}"
    CERT_CHAIN_FILE="${CERT_CHAIN_FILE:-certs/chain.pem}"
    [ -f "$CERT_FILE" ] || { echo "error: $CERT_FILE не найден" >&2; exit 1; }
    [ -f "$CERT_KEY_FILE" ] || { echo "error: $CERT_KEY_FILE не найден" >&2; exit 1; }
    [ -f "$CERT_CHAIN_FILE" ] || CERT_CHAIN_FILE=""
    echo
    echo "  Используются свои сертификаты:"
    echo "    cert : $CERT_FILE"
    echo "    key  : $CERT_KEY_FILE"
    [ -n "$CERT_CHAIN_FILE" ] && echo "    chain: $CERT_CHAIN_FILE"
    echo
  else
    # Список провайдеров из NPM (key: Name)
    echo
    echo "Доступные DNS-провайдеры (для wildcard-сертификата *.${BASE_DOMAIN}):"
    echo "  cloudflare: Cloudflare, duckdns: DuckDNS, digitalocean: DigitalOcean,"
    echo "  cloudns: ClouDNS, dnspod: DNSPod, route53: Route 53 (Amazon),"
    echo "  godaddy: GoDaddy, namecheap: Namecheap, ovh: OVH, hetzner: Hetzner,"
    echo "  vultr: Vultr, linode: Linode, gandi: Gandi Live DNS, porkbun: Porkbun,"
    echo "  ... полный список см. в .env.example"
    if [ -t 0 ]; then
      read -r -p "DNS provider [cloudflare]: " DNS_PROVIDER || true
    fi
    DNS_PROVIDER="${DNS_PROVIDER:-cloudflare}"
    DNS_PROVIDER="$(echo "$DNS_PROVIDER" | tr '[:upper:]' '[:lower:]')"
    if [ -t 0 ]; then
      read -r -p "DNS provider credentials (одной строкой; для нескольких полей используй \n, напр. dns_username=u\ndns_password=p): " DNS_PROVIDER_CREDENTIALS || true
    fi
    if [ -z "$DNS_PROVIDER_CREDENTIALS" ]; then
      echo "error: для https нужны DNS_PROVIDER_CREDENTIALS (или задай env-переменную)" >&2
      exit 1
    fi
    # Для выпуска сертификата LE нужен валидный email (NPM использует email админа)
    if [ -z "${NPM_EMAIL:-}" ]; then
      if [ -t 0 ]; then
        read -r -p "Email для Let's Encrypt (валидный, для ACME): " NPM_EMAIL || true
      fi
      if [ -z "$NPM_EMAIL" ]; then
        echo "error: для https нужен валидный email для Let's Encrypt (NPM_EMAIL)" >&2
        exit 1
      fi
    fi
    echo
    echo "  Wildcard-сертификат *.${BASE_DOMAIN} будет выпущен автоматически через"
    echo "  Let's Encrypt (DNS challenge) после старта NPM (email: ${NPM_EMAIL})."
    echo
  fi
fi

# --- Генерируем .env, если его нет ---
if [ ! -f .env ]; then
  NPM_EMAIL="${NPM_EMAIL:-admin-$(tr -dc 'a-z0-9' </dev/urandom | head -c 12 || true)@ctf.local}"
  NPM_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
  CTF_ADMIN_EMAIL="ctf-$(tr -dc 'a-z0-9' </dev/urandom | head -c 12 || true)@ctf.local"
  CTF_ADMIN_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"

  sed -e "s|^[#[:space:]]*NPM_EMAIL=.*|NPM_EMAIL=${NPM_EMAIL}|" \
      -e "s|NPM_PASSWORD=.*|NPM_PASSWORD=${NPM_PASSWORD}|" \
      -e "s|CTF_ADMIN_EMAIL=.*|CTF_ADMIN_EMAIL=${CTF_ADMIN_EMAIL}|" \
      -e "s|CTF_ADMIN_PASSWORD=.*|CTF_ADMIN_PASSWORD=${CTF_ADMIN_PASSWORD}|" \
      -e "s|^[#[:space:]]*BASE_DOMAIN=.*|BASE_DOMAIN=${BASE_DOMAIN}|" \
      -e "s|DEFAULT_FORWARD_SCHEME=.*|DEFAULT_FORWARD_SCHEME=${FORWARD_SCHEME}|" \
      -e "s|^[#[:space:]]*EXTERNAL_SCHEME=.*|EXTERNAL_SCHEME=${EXTERNAL_SCHEME}|" \
      -e "s|^[#[:space:]]*USE_CUSTOM_CERT=.*|USE_CUSTOM_CERT=${USE_CUSTOM_CERT:-}|" \
      -e "s|^[#[:space:]]*CERT_FILE=.*|CERT_FILE=${CERT_FILE:-}|" \
      -e "s|^[#[:space:]]*CERT_KEY_FILE=.*|CERT_KEY_FILE=${CERT_KEY_FILE:-}|" \
      -e "s|^[#[:space:]]*CERT_CHAIN_FILE=.*|CERT_CHAIN_FILE=${CERT_CHAIN_FILE:-}|" \
      -e "s|^[#[:space:]]*DNS_PROVIDER=.*|DNS_PROVIDER=${DNS_PROVIDER:-}|" \
      -e "s|^[#[:space:]]*DNS_PROVIDER_CREDENTIALS=.*|DNS_PROVIDER_CREDENTIALS=${DNS_PROVIDER_CREDENTIALS:-}|" \
      .env.example > .env

  echo
  echo "Credentials saved to .env"
  echo "  NPM admin:    ${NPM_EMAIL} / ${NPM_PASSWORD}"
  echo "  CTFd admin:   ${CTF_ADMIN_EMAIL} / ${CTF_ADMIN_PASSWORD}"
else
  # Обновляем BASE_DOMAIN и схемы в существующем .env
  if grep -q '^BASE_DOMAIN=' .env; then
    sed -i "s|^BASE_DOMAIN=.*|BASE_DOMAIN=${BASE_DOMAIN}|" .env
  else
    echo "BASE_DOMAIN=${BASE_DOMAIN}" >> .env
  fi
  if grep -q '^DEFAULT_FORWARD_SCHEME=' .env; then
    sed -i "s|^DEFAULT_FORWARD_SCHEME=.*|DEFAULT_FORWARD_SCHEME=${FORWARD_SCHEME}|" .env
  else
    echo "DEFAULT_FORWARD_SCHEME=${FORWARD_SCHEME}" >> .env
  fi
  if grep -q '^EXTERNAL_SCHEME=' .env; then
    sed -i "s|^EXTERNAL_SCHEME=.*|EXTERNAL_SCHEME=${EXTERNAL_SCHEME}|" .env
  else
    echo "EXTERNAL_SCHEME=${EXTERNAL_SCHEME}" >> .env
  fi
  if grep -q '^DNS_PROVIDER=' .env; then
    sed -i "s|^DNS_PROVIDER=.*|DNS_PROVIDER=${DNS_PROVIDER:-}|" .env
  else
    echo "DNS_PROVIDER=${DNS_PROVIDER:-}" >> .env
  fi
  if grep -q '^DNS_PROVIDER_CREDENTIALS=' .env; then
    sed -i "s|^DNS_PROVIDER_CREDENTIALS=.*|DNS_PROVIDER_CREDENTIALS=${DNS_PROVIDER_CREDENTIALS:-}|" .env
  else
    echo "DNS_PROVIDER_CREDENTIALS=${DNS_PROVIDER_CREDENTIALS:-}" >> .env
  fi
  for var in USE_CUSTOM_CERT CERT_FILE CERT_KEY_FILE CERT_CHAIN_FILE; do
    val="$(eval echo "\${$var:-}")"
    if grep -q "^$var=" .env; then
      sed -i "s|^$var=.*|$var=${val}|" .env
    else
      echo "$var=${val}" >> .env
    fi
  done
  echo ".env already exists, updated BASE_DOMAIN=${BASE_DOMAIN}, DEFAULT_FORWARD_SCHEME=${FORWARD_SCHEME}, EXTERNAL_SCHEME=${EXTERNAL_SCHEME}, DNS_PROVIDER=${DNS_PROVIDER:-}"
fi

# --- Генерируем секцию тасок в docker-compose.yml ---
./scripts/sync-tasks.sh

# --- Поднимаем стек ---
# tasks-sync выполнит sync-tasks.sh, ctfd-sync — setup CTFd и sync-ctfd.sh,
# npm-sync — sync-npm-hosts.sh
docker compose up -d --build

# --- Публикуем таски в NPM ---
# Ждём, пока NPM поднимется
for i in $(seq 1 60); do
  if curl -sf -o /dev/null http://localhost:81; then
    break
  fi
  sleep 2
done
./scripts/sync-npm-hosts.sh
