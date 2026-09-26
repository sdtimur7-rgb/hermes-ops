#!/usr/bin/env bash
# Разовая установка на Mac: клон приватного репозитория бэкапа и ежедневная задача launchd.
#   bash mac/install-backup-pull.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="sdtimur7-rgb/hermes-server-backup"
REPO_DIR="$HOME/hermes-server-backup"
TOOLS="$HOME/.hermes-backup-keys"
LABEL="com.hermes.server-backup-pull"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
GH="$(command -v gh)"

[ -n "$GH" ] || { echo "нужен gh (GitHub CLI), залогиненный в аккаунт с доступом к $REPO"; exit 1; }
[ -d "$REPO_DIR/.git" ] || "$GH" repo clone "$REPO" "$REPO_DIR" -- -q
# launchd запускает с урезанным PATH, поэтому помощник входа — по абсолютному пути,
# и только для этого репозитория, глобальный git не трогаем.
git -C "$REPO_DIR" config --unset-all credential.helper 2>/dev/null || true
git -C "$REPO_DIR" config --add credential.helper ""
git -C "$REPO_DIR" config --add credential.helper "!$GH auth git-credential"

mkdir -p "$TOOLS" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" && chmod 700 "$TOOLS"
cp "$HERE/backup-pull.sh" "$TOOLS/backup-pull.sh"
cp "$HERE/../backup/hermes_backup.py" "$TOOLS/hermes_backup.py"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$TOOLS/backup-pull.sh</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>10</integer><key>Minute</key><integer>30</integer></dict>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/hermes-server-backup-pull.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/hermes-server-backup-pull.log</string>
</dict>
</plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "установлено: $REPO_DIR, задача $LABEL — ежедневно в 10:30 и при входе"
