#!/bin/bash
# =============================================================
#  Залогиненный запуск десктоп-приложения «Препресс-Планер».
#
#  1. Пароль для аккаунта запрашивается ОДИН раз и сохраняется в macOS
#     Keychain (служба prepressplan-launcher); повторно — только вход.
#  2. POST {PP_AUTH_URL}/auth/login → токен пишется в app/state/session.json
#     (тот же файл, который читает SessionStore при старте).
#  3. Приложение запускается с PP_AUTH_URL/PP_PAYMENTS_URL на прод.
#
#  Использование:
#    bash scripts/launch_logged_in.sh            # вход + запуск
#    bash scripts/launch_logged_in.sh --forget   # забыть сохранённый пароль
#
#  Политика 1/1: каждый запуск вытесняет прошлую сессию аккаунта.
#  Пароль в файлы репозитория и в git НЕ попадает (только Keychain).
# =============================================================
set -euo pipefail
cd "$(dirname "$0")/.."   # корень репозитория

EMAIL="${PP_ACCOUNT_EMAIL:-vladimirkarateev@mail.ru}"
AUTH_BASE="${PP_AUTH_URL:-https://prepressplan.ru/auth}"
PAY_BASE="${PP_PAYMENTS_URL:-https://prepressplan.ru/payments}"
STATE_DIR="app/state"
SERVICE="prepressplan-launcher"

has_keychain() { command -v security >/dev/null 2>&1; }

forget_password() {
  if has_keychain; then
    security delete-generic-password -s "$SERVICE" -a "$EMAIL" >/dev/null 2>&1 || true
    echo "Сохранённый пароль удалён из Keychain."
  fi
}

case "${1:-}" in
  --forget) forget_password; exit 0 ;;
  -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
  "") ;;
  *) echo "Неизвестный параметр: $1 (есть только --forget)" >&2; exit 2 ;;
esac

get_password() {
  if has_keychain; then
    local stored
    stored=$(security find-generic-password -s "$SERVICE" -a "$EMAIL" -w 2>/dev/null || true)
    if [ -n "$stored" ]; then printf '%s' "$stored"; return 0; fi
  fi
  local input
  printf 'Пароль для %s: ' "$EMAIL" >&2
  read -rsp "" input; echo >&2
  if [ -z "$input" ]; then echo "Пустой пароль." >&2; exit 1; fi
  if has_keychain; then
    security add-generic-password -U -s "$SERVICE" -a "$EMAIL" \
      -w "$input" >/dev/null
    echo "Пароль сохранён в Keychain ($SERVICE)." >&2
  fi
  printf '%s' "$input"
}

json_field() {  # $1 — json, $2 — поле (token/detail)
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    j = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
print(j.get(sys.argv[2], "") if isinstance(j, dict) else "")
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
  forget_password   # неверный пароль — не оставляем его в Keychain
  exit 1
fi

mkdir -p "$STATE_DIR"
printf '{"token":"%s","email":"%s"}' "$TOKEN" "$EMAIL" \
  > "$STATE_DIR/session.json"
echo "Сессия записана: $STATE_DIR/session.json ($EMAIL)"

export PP_AUTH_URL="$AUTH_BASE"
export PP_PAYMENTS_URL="$PAY_BASE"

APP=$(ls -d app/build/macos/Build/Products/Release/*.app 2>/dev/null | head -1 || true)
if [ -n "$APP" ]; then
  BIN=$(ls "$APP"/Contents/MacOS/* 2>/dev/null | head -1)
  echo "Запуск релиза: $APP"
  # CWD=app, чтобы приложение увидело state/session.json.
  ( cd app && exec "$BIN" )
else
  echo "Релиз-сборки нет (app/build/macos/…) — запускаю через flutter run." >&2
  ( cd app && exec flutter run -d macos )
fi
