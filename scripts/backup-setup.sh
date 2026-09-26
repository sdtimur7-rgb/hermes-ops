#!/usr/bin/env bash
# Разовая установка ночного бэкапа серверного Hermes. От пользователя hermes, без root:
#   cd /home/hermes/ops && git pull && bash scripts/backup-setup.sh
# Повторный запуск безопасен: ключ не пересоздаётся, строка cron не дублируется.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HH="${HERMES_HOME:-$HOME/.hermes}"
PY="$HH/hermes-agent/venv/bin/python"
REPO="sdtimur7-rgb/hermes-server-backup"
KEY="$HOME/.ssh/hermes_backup_deploy"
log() { printf '\n== %s\n' "$*"; }

log "1/5 Установка"
[ "$(id -u)" != 0 ] || { echo "запускать от пользователя hermes, не от root: иначе всё ляжет в /root"; exit 1; }
[ -x "$PY" ] || { echo "нет $PY — Hermes не установлен"; exit 1; }
"$PY" -c "import cryptography" 2>/dev/null || { echo "в venv Hermes нет библиотеки cryptography"; exit 1; }
command -v git >/dev/null && command -v ssh >/dev/null || { echo "нужны git и ssh"; exit 1; }
mkdir -p "$HH/scripts" "$HH/backup" "$HH/logs" "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
cp "$HERE/backup/hermes_backup.py" "$HH/scripts/hermes_backup.py"
cp "$HERE/agent-scripts/hermes-backup.sh" "$HH/scripts/hermes-backup.sh" && chmod +x "$HH/scripts/hermes-backup.sh"
cp "$HERE/backup/backup_public.pem" "$HH/backup/backup_public.pem"
echo "  скрипты и открытый ключ шифрования на месте"

log "2/5 Ключ доступа к репозиторию"
if [ -f "$KEY" ]; then echo "  уже есть"; else
  ssh-keygen -q -t ed25519 -N "" -C "hermes-server-backup" -f "$KEY" && echo "  создан $KEY"
fi

log "3/5 Связь с GitHub"
probe() {
  ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
      -o UserKnownHostsFile="$HOME/.ssh/known_hosts_github" -o ConnectTimeout=20 -T "$@" 2>&1
}
# GitHub отвечает «successfully authenticated», когда ключ добавлен, и «Permission
# denied», когда нет. Оба ответа значат, что сеть есть; молчание — что её нет.
OUT=$(probe -p 443 git@ssh.github.com)
if echo "$OUT" | grep -q -E "successfully authenticated|Permission denied"; then
  REMOTE="ssh://git@ssh.github.com:443/$REPO.git"
else
  OUT=$(probe git@github.com)
  if echo "$OUT" | grep -q -E "successfully authenticated|Permission denied"; then
    REMOTE="git@github.com:$REPO.git"
  else
    echo "  GitHub по SSH недоступен ни через 443, ни через 22: $(echo "$OUT" | tail -1)"; exit 1
  fi
fi
echo "$REMOTE" > "$HH/backup/remote"
echo "  путь: $REMOTE"

log "4/5 Расписание"
LINE="17 3 * * * $HH/scripts/hermes-backup.sh >> $HH/logs/backup.log 2>&1"
( crontab -l 2>/dev/null | grep -v 'hermes-backup.sh'; echo "$LINE" ) | crontab - \
  && echo "  каждую ночь в 03:17 по часам сервера ($(date +%Z))"

log "5/5 Первый бэкап"
if echo "$OUT" | grep -q "successfully authenticated"; then
  bash "$HH/scripts/hermes-backup.sh" && echo && echo "ГОТОВО: бэкап настроен и первый снимок отправлен."
else
  echo "Ключ ещё не добавлен в репозиторий $REPO."
  echo "Перешлите Claude эту строку целиком (это открытый ключ, его можно показывать):"
  echo
  cat "$KEY.pub"
  echo
  echo "Когда Claude добавит ключ, выполните: bash $HH/scripts/hermes-backup.sh"
fi
