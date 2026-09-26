#!/usr/bin/env bash
# Забирает бэкап серверного Hermes на Mac. Запускается launchd раз в день и при входе.
#   ~/hermes-server-backup          открытый снимок (git, история по дням)
#   ~/hermes-server-backup-vault/   зашифрованные полные архивы, последние 14
# Если сервер больше двух суток не присылал архив — уведомление macOS.
set -uo pipefail
REPO_DIR="$HOME/hermes-server-backup"
VAULT_DIR="$HOME/hermes-server-backup-vault"
KEEP=14

notify() { osascript -e "display notification \"$1\" with title \"Бэкап Hermes\"" >/dev/null 2>&1 || true; }
say() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

cd "$REPO_DIR" 2>/dev/null || { say "нет $REPO_DIR"; notify "нет каталога копии: $REPO_DIR"; exit 1; }
git pull -q --ff-only origin main || { say "pull main не прошёл"; notify "не удалось забрать снимок сервера с GitHub"; exit 1; }

if git fetch -q origin "+refs/heads/vault:refs/remotes/origin/vault" 2>/dev/null; then
  STAMP=$(git log -1 --format=%cd --date=format:%Y-%m-%d_%H%M origin/vault)
  DEST="$VAULT_DIR/$STAMP"
  if [ ! -d "$DEST" ]; then
    mkdir -p "$DEST"
    git ls-tree --name-only origin/vault | while read -r name; do
      git show "origin/vault:$name" > "$DEST/$name"
    done
  fi
  # Храним последние $KEEP архивов: старые — это копии секретов, копить их незачем.
  ls -1d "$VAULT_DIR"/*/ 2>/dev/null | sort -r | tail -n +$((KEEP + 1)) | while read -r old; do
    rm -r "$old"
  done
  AGE_H=$(( ( $(date +%s) - $(git log -1 --format=%ct origin/vault) ) / 3600 ))
  # Архив пересоздаётся каждую ночь, даже если в Hermes ничего не менялось, поэтому
  # его возраст — честный признак того, что ночной бэкап жив.
  if [ "$AGE_H" -gt 48 ]; then
    notify "последний архив с сервера — $AGE_H ч назад: ночной бэкап не работает"
  fi
  say "ок: снимок $(git rev-parse --short HEAD), архив $STAMP ($AGE_H ч назад), хранится $(ls -1d "$VAULT_DIR"/*/ | wc -l | tr -d ' ')"
else
  FIRST_H=$(( ( $(date +%s) - $(git log --reverse --format=%ct | head -1) ) / 3600 ))
  say "архива с сервера ещё нет (репозиторий создан $FIRST_H ч назад)"
  if [ "$FIRST_H" -gt 48 ]; then
    notify "сервер так и не прислал ни одного архива — бэкап не настроен"
  fi
fi
exit 0
