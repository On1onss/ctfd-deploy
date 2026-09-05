#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Безопасно грузим .env: не используем source, чтобы значения с пробелами не ломались
load_env() {
  local file="$1" line key val
  [ -f "$file" ] || return 0
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    export "$key=$val"
  done < "$file"
}
load_env "$ROOT_DIR/.env"

: "${NPM_URL:=http://localhost:81}"
: "${NPM_EMAIL:?Set NPM_EMAIL (and NPM_PASSWORD) in .env or environment}"
: "${NPM_PASSWORD:?Set NPM_PASSWORD (and NPM_EMAIL) in .env or environment}"
: "${BASE_DOMAIN:=ctf.local}"
: "${DEFAULT_FORWARD_PORT:=8000}"
: "${DEFAULT_FORWARD_SCHEME:=http}"
: "${CTFD_DOMAIN:="ctf.$BASE_DOMAIN"}"
: "${CTFD_FORWARD_HOST:=ctfd}"
: "${CTFD_FORWARD_PORT:=8000}"
: "${EXTERNAL_SCHEME:=http}"
: "${DNS_PROVIDER:=}"
: "${DNS_PROVIDER_CREDENTIALS:=}"

API="$NPM_URL/api"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }
}
require curl
require jq

get_token() {
  curl -sf -X POST "$API/tokens" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg i "$NPM_EMAIL" --arg s "$NPM_PASSWORD" \
        '{identity:$i, secret:$s}')" \
    | jq -r '.token'
}

# Выпускает/находит wildcard-сертификат *.BASE_DOMAIN через Let's Encrypt (DNS challenge)
ensure_wildcard_cert() {
  local wildcard="*.$BASE_DOMAIN"
  local certs existing_id
  certs="$(curl -sf "$API/nginx/certificates" -H "$AUTH")" || return 1

  existing_id="$(echo "$certs" | jq -r --arg d "$wildcard" \
    '.[] | select(.provider=="letsencrypt") | select(any(.domain_names[]; . == $d)) | .id' | head -n1)"

  if [ -n "$existing_id" ]; then
    echo "cert       wildcard $wildcard уже есть (cert #$existing_id)"
    WILDCARD_CERT_ID="$existing_id"
    return 0
  fi

  if [ -z "$DNS_PROVIDER" ] || [ -z "$DNS_PROVIDER_CREDENTIALS" ]; then
    echo "error: https выбран, но DNS_PROVIDER/DNS_PROVIDER_CREDENTIALS не заданы" >&2
    return 1
  fi

  echo "requesting LetsEncrypt wildcard $wildcard via $DNS_PROVIDER ..."
  local payload resp creds
  # Разворачиваем литерал \n из .env в реальные переносы строк
  creds="$(printf '%b' "${DNS_PROVIDER_CREDENTIALS//\\\\n/\\n}")"
  payload="$(jq -n \
    --arg p "$DNS_PROVIDER" \
    --arg c "$creds" \
    '{provider:"letsencrypt", domain_names:["x"], meta:{dns_challenge:true, dns_provider:$p, dns_provider_credentials:$c}}')"
  payload="$(echo "$payload" | jq --arg w "$wildcard" '.domain_names = [$w]')"

  resp="$(curl -sf -X POST "$API/nginx/certificates" -H "$AUTH" -H 'Content-Type: application/json' -d "$payload")" || return 1
  WILDCARD_CERT_ID="$(echo "$resp" | jq -r '.id')"
  echo "created   wildcard cert (cert #$WILDCARD_CERT_ID)"
}

upsert_proxy_host() {
  local forward_scheme="$1" forward_host="$2" forward_port="$3"
  shift 3
  local domains=("$@")

  local domain_json
  domain_json="$(printf '%s\n' "${domains[@]}" | jq -R . | jq -s -c .)"

  local payload
  if [ "$EXTERNAL_SCHEME" = "https" ] && [ -n "${WILDCARD_CERT_ID:-}" ]; then
    payload="$(jq -n \
      --argjson d "$domain_json" \
      --arg s "$forward_scheme" \
      --arg h "$forward_host" \
      --argjson p "$forward_port" \
      --argjson cert "$WILDCARD_CERT_ID" \
      '{domain_names:$d, forward_scheme:$s, forward_host:$h, forward_port:$p, enabled:true, certificate_id:$cert, ssl_forced:true, http2_support:true, block_exploits:true, caching_enabled:false, allow_websocket_upgrade:true}')"
  else
    payload="$(jq -n \
      --argjson d "$domain_json" \
      --arg s "$forward_scheme" \
      --arg h "$forward_host" \
      --argjson p "$forward_port" \
      '{domain_names:$d, forward_scheme:$s, forward_host:$h, forward_port:$p, enabled:true, block_exploits:true, caching_enabled:false, allow_websocket_upgrade:true}')"
  fi

  local existing
  existing="$(echo "$HOSTS" | jq -r --argjson d "$domain_json" \
    '.[] | select(any(.domain_names[]; . as $dn | $d | index($dn))) | .id' | head -n1)"

  if [ -n "$existing" ]; then
    curl -sf -X PUT "$API/nginx/proxy-hosts/$existing" -H "$AUTH" -H 'Content-Type: application/json' -d "$payload" >/dev/null
    echo "updated  $forward_host (host #$existing) -> ${domains[0]} -> $forward_host:$forward_port"
  else
    local response
    response="$(curl -sf -X POST "$API/nginx/proxy-hosts" -H "$AUTH" -H 'Content-Type: application/json' -d "$payload")"
    echo "created  $forward_host (host #$(echo "$response" | jq -r .id)) -> ${domains[0]} -> $forward_host:$forward_port"
  fi
}

AUTH="Authorization: Bearer $(get_token)"
HOSTS="$(curl -sf "$API/nginx/proxy-hosts" -H "$AUTH")"

# При https — выпускаем/находим wildcard-сертификат *.BASE_DOMAIN
WILDCARD_CERT_ID=""
if [ "$EXTERNAL_SCHEME" = "https" ]; then
  if ! ensure_wildcard_cert; then
    echo "error: не удалось обеспечить wildcard-сертификат, хосты создаются без SSL" >&2
  fi
fi

# CTFd itself
upsert_proxy_host "$DEFAULT_FORWARD_SCHEME" "$CTFD_FORWARD_HOST" "$CTFD_FORWARD_PORT" "$CTFD_DOMAIN"

# Tasks
published=0
for catdir in "$ROOT_DIR"/tasks/*/; do
  [ -d "$catdir" ] || continue
  category="$(basename "$catdir")"
  for dir in "$catdir"*/; do
    [ -d "$dir" ] || continue
    [ -f "$dir/Dockerfile" ] || continue
    [ -f "$dir/challenge.json" ] || continue
    name="$(basename "$dir")"

    forward_port="$DEFAULT_FORWARD_PORT"
    forward_scheme="$DEFAULT_FORWARD_SCHEME"
    forward_host="task-${category}-${name}"
    domains=("$name.$BASE_DOMAIN")

    # Per-task overrides, e.g. tasks/<category>/<name>/npm.json
    # { "forward_port": 8080, "forward_scheme": "https", "forward_host": "task-web-example", "domains": ["my.ctf.local"] }
    if [ -f "$dir/npm.json" ]; then
      forward_port="$(jq -r --arg d "$forward_port" '.forward_port // ($d | tonumber)' "$dir/npm.json")"
      forward_scheme="$(jq -r --arg d "$forward_scheme" '.forward_scheme // $d' "$dir/npm.json")"
      forward_host="$(jq -r --arg d "$forward_host" '.forward_host // $d' "$dir/npm.json")"
      mapfile -t overridden_domains < <(jq -r '.domains[] // empty' "$dir/npm.json")
      if [ "${#overridden_domains[@]:-0}" -gt 0 ]; then
        domains=("${overridden_domains[@]}")
      fi
      unset overridden_domains
    fi

    upsert_proxy_host "$forward_scheme" "$forward_host" "$forward_port" "${domains[@]}"
    published=$((published + 1))
  done
done

echo "done: ctfd + $published task(s) published via $NPM_URL"