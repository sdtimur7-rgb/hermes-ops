#!/usr/bin/env bash
# Полное развёртывание Hermes на сервере. Запускать от root.
# Идемпотентный: безопасно перезапускать.
set -uo pipefail

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mОШИБКА: %s\033[0m\n' "$*"; exit 1; }

# ── Секреты передаются переменными окружения при запуске ───────────────
: "${TG_TOKEN:?нужен TG_TOKEN}"
: "${TG_OWNER:?нужен TG_OWNER}"
: "${AIML_KEY:?нужен AIML_KEY}"

log "1/9 Система"
. /etc/os-release; echo "$PRETTY_NAME  $(uname -m)"
free -h | head -2; df -h / | tail -1

log "2/9 Таймзона и пакеты"
timedatectl set-timezone Europe/Moscow 2>/dev/null || true
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl ca-certificates xz-utils ripgrep ufw fail2ban jq sudo >/dev/null 2>&1
echo "готово"

log "3/9 Swap 2 ГБ"
if swapon --show 2>/dev/null | grep -q swapfile; then
  echo "уже есть"
else
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "создан"
fi
sysctl -w vm.swappiness=20 >/dev/null
grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=20' >> /etc/sysctl.conf
free -h | head -2

log "4/9 Пользователь hermes"
if id hermes >/dev/null 2>&1; then echo "уже есть"; else
  adduser --disabled-password --gecos "" hermes >/dev/null
  usermod -aG sudo hermes
  echo "создан"
fi
echo 'hermes ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-hermes
chmod 440 /etc/sudoers.d/90-hermes
install -d -m 700 -o hermes -g hermes /home/hermes/.ssh
[ -f /root/.ssh/authorized_keys ] && { cp /root/.ssh/authorized_keys /home/hermes/.ssh/; chown hermes:hermes /home/hermes/.ssh/authorized_keys; chmod 600 /home/hermes/.ssh/authorized_keys; }

log "5/9 Firewall и fail2ban"
ufw --force reset >/dev/null 2>&1
ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null
ufw --force enable >/dev/null
systemctl enable --now fail2ban >/dev/null 2>&1 || true
ufw status | head -4

log "6/9 Установка Hermes (без Chromium — на 1 ГБ он лишний)"
if sudo -u hermes test -x /home/hermes/.local/bin/hermes; then
  echo "уже установлен: $(sudo -u hermes /home/hermes/.local/bin/hermes --version 2>/dev/null | head -1)"
else
  sudo -u hermes -H bash -lc 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o /tmp/h.sh && bash /tmp/h.sh --skip-setup --skip-browser --skip-computer-use' \
    > /tmp/hermes-install.log 2>&1 || { tail -25 /tmp/hermes-install.log; die "установка Hermes не удалась, лог /tmp/hermes-install.log"; }
  echo "установлен: $(sudo -u hermes /home/hermes/.local/bin/hermes --version 2>/dev/null | head -1)"
fi

log "7/9 Конфигурация: DeepSeek через AIMLAPI + Telegram"
HH=/home/hermes/.hermes
sudo -u hermes mkdir -p "$HH"

# секреты в .env
sudo -u hermes tee -a "$HH/.env" >/dev/null <<ENVEOF

# ── настроено автоматическим развёртыванием ──
AIMLAPI_KEY=${AIML_KEY}
TELEGRAM_BOT_TOKEN=${TG_TOKEN}
TELEGRAM_ALLOWED_USERS=${TG_OWNER}
ENVEOF
chmod 600 "$HH/.env"

# модель, провайдер, резерв, безопасность
sudo -u hermes python3 - <<'PYEOF'
import os, re, io
p = '/home/hermes/.hermes/config.yaml'
s = open(p).read() if os.path.exists(p) else ''

def upsert_block(text, key, block):
    pat = re.compile(rf'^{key}:\n(?:[ \t]+.*\n|\n)*', re.M)
    return pat.sub(block, text, count=1) if pat.search(text) else text + '\n' + block

s = upsert_block(s, 'model', '''model:
  default: deepseek/deepseek-v4-flash
  provider: aimlapi
''')
s = upsert_block(s, 'providers', '''providers:
  aimlapi:
    api: https://api.aimlapi.com/v1
    key_env: AIMLAPI_KEY
    transport: chat_completions
''')
s = upsert_block(s, 'approvals', '''approvals:
  mode: smart
  cron_mode: deny
  single_query_mode: deny
  unattended_mode: deny
  destructive_slash_confirm: true
  deny:
    - 'hermes config set*'
    - 'hermes config edit*'
    - 'hermes config unset*'
    - '* config set*'
    - 'hermes auth*'
    - 'hermes model*'
    - 'hermes setup*'
    - 'hermes gateway install*'
    - 'hermes gateway uninstall*'
    - 'systemctl * hermes*'
    - 'hermes cron create*'
    - 'hermes cron add*'
    - 'hermes cron remove*'
    - 'hermes cron delete*'
    - 'hermes cron edit*'
    - '*.hermes/.env*'
    - 'sed -i*.hermes/*'
''')
s = upsert_block(s, 'delegation', '''delegation:
  max_concurrent_children: 3
  max_spawn_depth: 1
  subagent_auto_approve: false
''')
open(p, 'w').write(s)
print("  конфиг записан")
PYEOF

log "8/9 systemd-автозапуск"
sudo -u hermes -H bash -lc '/home/hermes/.local/bin/hermes gateway install' 2>&1 | tail -4 || true
# страховка: если штатный установщик не создал юнит — создаём свой
if ! systemctl list-unit-files 2>/dev/null | grep -qi hermes; then
  cat > /etc/systemd/system/hermes.service <<'UNITEOF'
[Unit]
Description=Hermes Agent Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hermes
WorkingDirectory=/home/hermes
ExecStart=/home/hermes/.local/bin/hermes gateway run
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNITEOF
  systemctl daemon-reload
  systemctl enable --now hermes >/dev/null 2>&1
  echo "создан свой юнит hermes.service"
fi
sleep 20
systemctl --no-pager status hermes 2>/dev/null | head -6 || \
  systemctl --no-pager status "hermes-gateway-*" 2>/dev/null | head -6

log "9/9 Проверка"
echo "-- процессы --"; pgrep -af hermes | head -3
echo "-- потребление памяти --"; free -h | head -2
echo "-- Telegram в логах --"
journalctl -u hermes -n 40 --no-pager 2>/dev/null | grep -iE "telegram|connected|polling" | tail -3 || echo "  (см. journalctl -u hermes)"

# уведомление владельцу
curl -s -m 20 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
  -d "chat_id=${TG_OWNER}" \
  --data-urlencode "text=Сервер развёрнут и Hermes запущен.

Хост: $(hostname)
ОС: $(. /etc/os-release; echo $PRETTY_NAME)
RAM: $(free -h | awk '/^Mem:/{print $2}') (swap $(free -h | awk '/^Swap:/{print $2}'))
Модель: deepseek/deepseek-v4-flash через AIMLAPI
Автозапуск: systemd, переживает перезагрузку
Доступ: только ваш Telegram ID

Напишите /status или «покажи загрузку памяти и диска» для проверки." >/dev/null && echo "-- уведомление в Telegram отправлено --"

log "ГОТОВО"
echo "Управление: systemctl status|restart hermes ; journalctl -u hermes -f"
