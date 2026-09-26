#!/usr/bin/env bash
# Ночной бэкап серверного Hermes в приватный репозиторий GitHub.
#
#   main  — открытый снимок навыков, памяти, задач и настроек, секреты вычищены.
#           Копится история: видно, что и когда поменялось, любой день откатывается.
#   vault — последний полный архив со всеми секретами и базами, зашифрованный
#           открытым ключом владельца. Ветка перезаписывается: хранится только
#           свежий архив, а историю по дням держит Mac у себя.
#
# Ставится scripts/backup-setup.sh, запускается cron в 03:17. Вручную:
#   bash ~/.hermes/scripts/hermes-backup.sh
# Сбой — сообщение владельцу в Telegram напрямую ботом: Hermes может и лежать.
set -uo pipefail

HH="${HERMES_HOME:-$HOME/.hermes}"
PY="$HH/hermes-agent/venv/bin/python"
# HB_* переопределяют пути — только для проверки скрипта вне сервера.
TOOL="${HB_TOOL:-$HH/scripts/hermes_backup.py}"
PUBKEY="${HB_PUBKEY:-$HH/backup/backup_public.pem}"
REMOTE="${HB_REMOTE:-$(cat "$HH/backup/remote" 2>/dev/null)}"
WORK="$HOME/hermes-backup"
VAULT="$HOME/hermes-backup-vault"
KEY="${HB_KEY:-$HOME/.ssh/hermes_backup_deploy}"
export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$HOME/.ssh/known_hosts_github -o ConnectTimeout=30"
export GIT_AUTHOR_NAME="Hermes (сервер)" GIT_AUTHOR_EMAIL="hermes@server.local"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

alert() {
  [ -n "${HB_NO_ALERT:-}" ] && return 0
  local token chat
  token=$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$HH/.env" 2>/dev/null | cut -d= -f2- | tr -d "\"'")
  chat=$(grep -m1 '^TELEGRAM_ALLOWED_USERS=' "$HH/.env" 2>/dev/null | cut -d= -f2- | tr -d "\"' " | cut -d, -f1)
  [ -n "$token" ] && [ -n "$chat" ] || return 0
  # Токен уходит curl-у конфигом на stdin, а не аргументом: в ps его видеть незачем.
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" \
    | curl -sS -m 20 -K - -d "chat_id=$chat" --data-urlencode "text=💾 Бэкап Hermes не прошёл: $1" >/dev/null || true
}

fail() { log "СБОЙ: $1"; alert "$1"; exit 1; }

[ -n "$REMOTE" ] || fail "нет $HH/backup/remote — сначала scripts/backup-setup.sh"
[ -f "$KEY" ] || fail "нет ключа $KEY — сначала scripts/backup-setup.sh"
[ -x "$PY" ] && [ -f "$TOOL" ] && [ -f "$PUBKEY" ] || fail "не установлен hermes_backup.py или открытый ключ"

# --- main: открытый снимок с историей ----------------------------------------
mkdir -p "$WORK"
cd "$WORK" || fail "нет каталога $WORK"
[ -d .git ] || { git init -q -b main && git remote add origin "$REMOTE"; }
git remote set-url origin "$REMOTE"
git fetch -q origin main 2>/dev/null || true
# Первый запуск: встать на то, что уже лежит в репозитории (README с Mac), до снимка,
# иначе сброс ветки затёр бы только что снятые файлы.
if ! git rev-parse -q --verify HEAD >/dev/null && git rev-parse -q --verify origin/main >/dev/null; then
  git checkout -q -B main origin/main
fi
"$PY" "$TOOL" snapshot --home "$HH" --out "$WORK" || fail "снимок не собрался"
git add -A
if git diff --cached --quiet; then
  log "снимок: изменений нет"
else
  git commit -q -m "снимок $(date '+%F %H:%M')" || fail "не удалось закоммитить снимок"
  log "снимок: закоммичен $(git rev-parse --short HEAD)"
fi
git push -q origin main 2>&1 | tail -2
[ "${PIPESTATUS[0]}" = 0 ] || fail "push снимка не прошёл — ключ доступа к репозиторию добавлен?"

# --- vault: последний зашифрованный архив ------------------------------------
mkdir -p "$VAULT"
cd "$VAULT" || fail "нет каталога $VAULT"
"$PY" "$TOOL" vault --home "$HH" --pubkey "$PUBKEY" --out "$VAULT" || fail "хранилище не собралось"
cat > README.md <<'MD'
Зашифрованный полный архив серверного Hermes (.env, ключи, базы, навыки, память).
Открывается только закрытым ключом с Mac. Расшифровка — см. README ветки main.
MD
[ -d .git ] || { git init -q -b vault && git remote add origin "$REMOTE"; }
git remote set-url origin "$REMOTE"
# Сироту пересоздаём каждый раз: в репозитории живёт один архив, а не стопка
# полных копий секретов.
git branch -q -D vault-next 2>/dev/null || true
git checkout -q --orphan vault-next
git rm -rq --cached . 2>/dev/null || true
git add README.md VAULT.json vault.hbk.part*
git commit -q -m "архив $(date '+%F %H:%M')" || fail "не удалось закоммитить архив"
git branch -q -D vault 2>/dev/null || true
git branch -q -m vault
git push -q -f origin vault 2>&1 | tail -2
[ "${PIPESTATUS[0]}" = 0 ] || fail "push архива не прошёл"
git reflog expire --expire=now --all && git gc -q --prune=now
log "архив: отправлен ($(python3 -c "import json;d=json.load(open('VAULT.json'));print(d['size_mb'],'МБ,',len(d['parts']),'част.')" 2>/dev/null))"
log "бэкап завершён"
