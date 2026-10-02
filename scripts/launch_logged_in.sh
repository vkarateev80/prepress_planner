#!/bin/bash
# =============================================================
#  Залогиненный запуск десктоп-приложения «Препресс-Планер»
#  (macOS и Linux).
#
#  1. Пароль для аккаунта запрашивается ОДИН раз и сохраняется в
#     хранилище ОС: macOS — Keychain (security), Linux — Secret
#     Service (secret-tool); повторно — только вход.
#  2. POST {PP_AUTH_URL}/auth/login → токен пишется в
#     app/state/session.json (читает SessionStore при старте).
#  3. Приложение запускается с PP_AUTH_URL/PP_PAYMENTS_URL на прод.
#
#  Использование:
#    bash scripts/launch_logged_in.sh            # вход + запуск
#    bash scripts/launch_logged_in.sh --forget   # забыть сохранённый пароль
#
#  Политика 1/1: каждый запуск вытесняет прошлую сессию аккаунта.
#  Пароль в файлы репозитория и в git НЕ попадает (только хранилище ОС).
# =============================================================
set -euo pipefail
cd "$(dirname "$0")/.."   # корень репозитория
ROOT="$PWD"

EMAIL="${PP_ACCOUNT_EMAIL:-vladimirkarateev@mail.ru}"
AUTH_BASE="${PP_AUTH_URL:-https://prepressplan.ru/auth}"
PAY_BASE="${PP_PAYMENTS_URL:-https://prepressplan.ru/payments}"
STATE_DIR="app/state"
SERVICE="prepressplan-launcher"
OS=$(uname -s)   # Darwin | Linux

# --- хранилище пароля (macOS Keychain / Linux Secret Service) ---

has_secret_store() {
  if [ "$OS" = Darwin ]; then command -v security >/dev/null 2>&1
  else command -v secret-tool >/dev/null 2>&1
  fi
}

secret_get() {
  if [ "$OS" = Darwin ]; then
    security find-generic-password -s "$SERVICE" -a "$EMAIL" -w 2>/dev/null || true
  else
    secret-tool lookup service "$SERVICE" username "$EMAIL" 2>/dev/null || true
  fi
}

secret_put() {  # $1 — пароль
  if [ "$OS" = Darwin ]; then
    security add-generic-password -U -s "$SERVICE" -a "$EMAIL" -w "$1" >/dev/null
    echo "Пароль сохранён в Keychain ($SERVICE)." >&2
  else
    printf '%s' "$1" | secret-tool store --label="$SERVICE" \
      service "$SERVICE" username "$EMAIL"
    echo "Пароль сохранён в Secret Service ($SERVICE)." >&2
  fi
}

secret_del() {
  if [ "$OS" = Darwin ]; then
    security delete-generic-password -s "$SERVICE" -a "$EMAIL" >/dev/null 2>&1 || true
    echo "Сохранённый пароль удалён из Keychain."
  else
    secret-tool clear service "$SERVICE" username "$EMAIL" >/dev/null 2>&1 || true
    echo "Сохранённый пароль удалён из Secret Service."
  fi
}

forget_password() {
  if has_secret_store; then secret_del; fi
}

case "${1:-}" in
  --forget) forget_password; exit 0 ;;
  -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
  "") ;;
  *) echo "Неизвестный параметр: $1 (есть только --forget)" >&2; exit 2 ;;
esac

get_password() {
  if has_secret_store; then
    local stored
    stored=$(secret_get)
    if [ -n "$stored" ]; then printf '%s' "$stored"; return 0; fi
  fi
  local input
  printf 'Пароль для %s: ' "$EMAIL" >&2
  read -rsp "" input; echo >&2
  if [ -z "$input" ]; then echo "Пустой пароль." >&2; exit 1; fi
  if has_secret_store; then secret_put "$input"; fi
  printf '%s' "$input"
}

json_field() {  # $1 — json, $2 — поле (token/detail)
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    j = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
print(j.get(sys.argv[1], "") if isinstance(j, dict) else "")
' "$2"
}

PASSWORD=$(get_password)
PAYLOAD=$(EMAIL="$EMAIL" PASSWORD="$PASSWORD" python3 -c '
import json, os
print(json.dumps({"email": os.environ["EMAIL"], "password": os.environ["PASSWORD"]}))
')

if ! RESP=$(curl -sS --max-time 25 -X POST "$AUTH_BASE/login" \
      -H 'Content-Type: application/json' --data "$PAYLOAD"); then
  echo "Сервер авторизации недоступен: $AUTH_BASE/login" >&2
  exit 1
fi
TOKEN=$(json_field "$RESP" token)
if [ -z "$TOKEN" ]; then
  echo "Вход не удался: $(json_field "$RESP" detail)" >&2
  forget_password   # неверный пароль — не оставляем его в хранилище
  exit 1
fi

mkdir -p "$STATE_DIR"
printf '{"token":"%s","email":"%s"}' "$TOKEN" "$EMAIL" \
  > "$STATE_DIR/session.json"
echo "Сессия записана: $STATE_DIR/session.json ($EMAIL)"

export PP_AUTH_URL="$AUTH_BASE"
export PP_PAYMENTS_URL="$PAY_BASE"

# --- запуск приложения (релиз, иначе flutter run) ---

if [ "$OS" = Darwin ]; then
  APP=$(ls -d "$ROOT"/app/build/macos/Build/Products/Release/*.app 2>/dev/null | head -1 || true)
  if [ -n "$APP" ]; then
    BIN=$(ls "$APP"/Contents/MacOS/* 2>/dev/null | head -1)
    echo "Запуск релиза: $APP"
    # CWD=app, чтобы приложение увидело state/session.json.
    ( cd app && exec "$BIN" )
  else
    echo "Релиз-сборки нет (app/build/macos/…) — запускаю через flutter run." >&2
    ( cd app && exec flutter run -d macos )
  fi
else
  BIN=$(ls -d "$ROOT"/app/build/linux/*/release/binary 2>/dev/null | head -1 || true)
  if [ -n "$BIN" ]; then
    echo "Запуск релиза: $BIN"
    # CWD=app, чтобы приложение увидело state/session.json.
    ( cd app && exec "$BIN" )
  else
    echo "Релиз-сборки нет (app/build/linux/*/release/binary) — запускаю через flutter run." >&2
    ( cd app && exec flutter run -d linux )
  fi
fi
