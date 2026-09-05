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

: "${CTFD_URL:=http://localhost:8000}"
: "${CTF_ADMIN_NAME:?Set CTF_ADMIN_NAME (and CTF_ADMIN_EMAIL/PASSWORD) in .env or environment}"
: "${CTF_ADMIN_EMAIL:?Set CTF_ADMIN_EMAIL (and CTF_ADMIN_NAME/PASSWORD) in .env or environment}"
: "${CTF_ADMIN_PASSWORD:?Set CTF_ADMIN_PASSWORD (and CTF_ADMIN_NAME/EMAIL) in .env or environment}"
: "${CTF_NAME:=CTF}"
: "${CTF_DESCRIPTION:=}"
: "${CTF_MODE:=users}"
: "${CTF_CHALLENGE_VISIBILITY:=private}"
: "${CTF_ACCOUNT_VISIBILITY:=public}"
: "${CTF_SCORE_VISIBILITY:=public}"
: "${CTF_REGISTRATION_VISIBILITY:=public}"
: "${CTF_THEME:=core-beta}"

BASE_URL="$CTFD_URL"
JAR="$(mktemp)"
CSRF=""
trap 'rm -f "$JAR"' EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }
}
require curl
require jq

api_get() {
  curl -sf -b "$JAR" -c "$JAR" "$BASE_URL/api/v1$1" 2>/dev/null || echo '{"success":false}'
}

api_post() {
  local headers=()
  [ -n "$CSRF" ] && headers=(-H "CSRF-Token: $CSRF")
  curl -sf -b "$JAR" -c "$JAR" -X POST \
    -H 'Content-Type: application/json' \
    "${headers[@]}" \
    -d "$2" \
    "$BASE_URL/api/v1$1" 2>/dev/null || echo '{"success":false}'
}

get_csrf() {
  # Берём CSRF nonce со страницы (кладётся в сессионную cookie при GET)
  local page="$1"
  local html nonce
  html="$(curl -sf -b "$JAR" -c "$JAR" "$BASE_URL$page")" || return 1
  nonce="$(echo "$html" | sed -n 's/.*csrfNonce[^"]*"\([^"]*\)".*/\1/p' | head -n1)"
  [ -n "$nonce" ] || return 1
  CSRF="$nonce"
}

is_setup() {
  # CTFd редиректит на главную, когда setup выполнен
  code="$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" -c "$JAR" "$BASE_URL/setup")"
  [ "$code" != "200" ]
}

do_setup() {
  echo "running CTFd initial setup ($CTF_NAME, mode=$CTF_MODE)"
  # Берём CSRF nonce из страницы /setup (сервер кладёт его в сессионную cookie)
  if ! get_csrf "/setup"; then
    echo "error: не удалось получить CSRF nonce со страницы /setup" >&2
    return 1
  fi
  curl -sf -b "$JAR" -c "$JAR" -X POST "$BASE_URL/setup" \
    --data-urlencode "nonce=$CSRF" \
    --data-urlencode "ctf_name=$CTF_NAME" \
    --data-urlencode "ctf_description=$CTF_DESCRIPTION" \
    --data-urlencode "user_mode=$CTF_MODE" \
    --data-urlencode "challenge_visibility=$CTF_CHALLENGE_VISIBILITY" \
    --data-urlencode "account_visibility=$CTF_ACCOUNT_VISIBILITY" \
    --data-urlencode "score_visibility=$CTF_SCORE_VISIBILITY" \
    --data-urlencode "registration_visibility=$CTF_REGISTRATION_VISIBILITY" \
    --data-urlencode "name=$CTF_ADMIN_NAME" \
    --data-urlencode "email=$CTF_ADMIN_EMAIL" \
    --data-urlencode "password=$CTF_ADMIN_PASSWORD" \
    --data-urlencode "ctf_theme=$CTF_THEME" \
    >/dev/null
}

do_login() {
  # Берём CSRF nonce со страницы /login, затем шлём POST с ним
  if ! get_csrf "/login"; then
    echo "error: не удалось получить CSRF nonce со страницы /login" >&2
    return 1
  fi
  curl -sf -b "$JAR" -c "$JAR" -X POST "$BASE_URL/login" \
    --data-urlencode "nonce=$CSRF" \
    --data-urlencode "name=$CTF_ADMIN_EMAIL" \
    --data-urlencode "password=$CTF_ADMIN_PASSWORD" \
    >/dev/null
}

# --- Setup, если ещё не сделан ---
if ! is_setup; then
  do_setup
  # setup логинит автоматически; если нет — логинимся явно
  if is_setup; then
    do_login
  fi
else
  do_login
fi

# После логина nonce обновляется (session regenerate) — перечитываем актуальный
get_csrf "/login" || true

# --- Проверка, что мы админ ---
if ! api_get "/challenges?view=admin" | jq -e '.success == true' >/dev/null; then
  echo "error: не удалось авторизоваться в CTFd как админ ($CTF_ADMIN_EMAIL)" >&2
  exit 1
fi

# --- Существующие челленджи (по имени) ---
existing="$(api_get "/challenges?view=admin" | jq -r '.data[]?.name')"

created=0
for catdir in "$ROOT_DIR"/tasks/*/; do
  [ -d "$catdir" ] || continue
  category="$(basename "$catdir")"
  for dir in "$catdir"*/; do
    [ -d "$dir" ] || continue
    [ -f "$dir/challenge.json" ] || continue

    name="$(jq -r '.name // empty' "$dir/challenge.json")"
    name="${name:-$(basename "$dir")}"
    value="$(jq -r '.value // 100' "$dir/challenge.json")"
    ctype="$(jq -r '.type // "standard"' "$dir/challenge.json")"
    state="$(jq -r '.state // "visible"' "$dir/challenge.json")"
    desc="$(jq -r '.description // ""' "$dir/challenge.json")"
    flag="$(jq -r '.flag // empty' "$dir/challenge.json")"
    conn="$(jq -r '.connection_info // empty' "$dir/challenge.json")"
    ch_category="$(jq -r --arg d "$category" '.category // $d' "$dir/challenge.json")"
    mapfile -t tags < <(jq -r '.tags[]? // empty' "$dir/challenge.json")

    # флаг можно хранить и в отдельном файле
    if [ -z "$flag" ] && [ -f "$dir/flag.txt" ]; then
      flag="$(tr -d '\r\n' < "$dir/flag.txt")"
    fi

    if echo "$existing" | grep -qx "$name"; then
      echo "exists    $name ($ch_category)"
      continue
    fi

    payload="$(jq -n \
      --arg name "$name" \
      --arg desc "$desc" \
      --argjson value "$value" \
      --arg cat "$ch_category" \
      --arg type "$ctype" \
      --arg state "$state" \
      --arg conn "$conn" \
      '{name:$name, description:$desc, value:$value, category:$cat, type:$type, state:$state, connection_info:$conn}')"

    resp="$(api_post "/challenges" "$payload")"
    if ! echo "$resp" | jq -e '.success == true' >/dev/null; then
      echo "failed    $name: $(echo "$resp" | jq -c '.errors // .' )" >&2
      continue
    fi
    challenge_id="$(echo "$resp" | jq -r '.data.id')"

    # флаг
    if [ -n "$flag" ]; then
      api_post "/flags" "$(jq -n --argjson cid "$challenge_id" --arg f "$flag" '{challenge_id:$cid, content:$f, type:"static"}')" \
        >/dev/null
    fi

    # теги
    for t in "${tags[@]}"; do
      api_post "/tags" "$(jq -n --argjson cid "$challenge_id" --arg v "$t" '{challenge_id:$cid, value:$v}')" >/dev/null
    done

    echo "created   $name ($ch_category, $value pts, id=$challenge_id)"
    created=$((created + 1))
  done
done

echo "done: $created challenge(s) created in CTFd at $CTFD_URL"