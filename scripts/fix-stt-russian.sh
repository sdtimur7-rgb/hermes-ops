#!/usr/bin/env bash
# Русская речь в голосовых сообщениях: убрать машинный перевод.
#
# Симптом: надиктованное по-русски доходит до агента искажённым, часть заданий теряется.
# Причина: stt.language = en. Whisper при явно заданном английском декодирует русскую
# речь как английскую — получается не расшифровка, а подобие перевода. Плюс модель
# base — самая слабая, на русском ошибается даже без этой проблемы.
#
# Запускать от root:  bash scripts/fix-stt-russian.sh
set -uo pipefail
log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

HH=/home/hermes/.hermes
CFG=$HH/config.yaml
REPO=$HH/hermes-agent
[ -f "$CFG" ] || { echo "нет $CFG"; exit 1; }

log "1/4 Что настроено сейчас"
sudo -u hermes "$REPO/venv/bin/python" - <<'PYEOF'
import yaml, os
d = yaml.safe_load(open(os.path.expanduser("~/.hermes/config.yaml"))) or {}
s = d.get("stt") or {}
print("  stt.language:      %r" % s.get("language"))
print("  stt.local.model:   %r" % ((s.get("local") or {}).get("model")))
print("  stt.openai.language: %r" % ((s.get("openai") or {}).get("language")))
PYEOF

log "2/4 Правка"
cp "$CFG" "$CFG.bak-stt-$(date +%s)"
sudo -u hermes "$REPO/venv/bin/python" - <<'PYEOF'
import yaml, os
p = os.path.expanduser("~/.hermes/config.yaml")
d = yaml.safe_load(open(p)) or {}
s = d.setdefault("stt", {})
s["enabled"] = True
s["language"] = "ru"                       # главное: без этого Whisper уходит в английский
s.setdefault("local", {})["model"] = "small"   # base слишком слаба для русского
s.setdefault("openai", {})["language"] = "ru"  # облачный путь тоже фиксируем
open(p, "w").write(yaml.safe_dump(d, allow_unicode=True, sort_keys=False))
print("  ✅ stt.language=ru, local.model=small, openai.language=ru")
PYEOF

log "3/4 Проверка"
sudo -u hermes "$REPO/venv/bin/python" - <<'PYEOF'
import yaml, os
d = yaml.safe_load(open(os.path.expanduser("~/.hermes/config.yaml")))
s = d["stt"]
ok = s.get("language") == "ru" and (s.get("local") or {}).get("model") == "small"
print("  stt:", {k: s.get(k) for k in ("enabled", "language")},
      "| local:", s.get("local"), "| openai:", s.get("openai"))
print("  ИТОГ:", "OK" if ok else "ПРОВЕРИТЬ ВРУЧНУЮ")
PYEOF

log "4/4 Перезапуск"
systemctl restart hermes 2>/dev/null || systemctl restart 'hermes-gateway-*' 2>/dev/null || true
sleep 12
systemctl is-active hermes 2>/dev/null && echo "  сервис активен" || echo "  ⚠ сервис не активен"
echo
echo "Проверка: запишите в Telegram голосовое по-русски."
echo "Должна прийти дословная расшифровка, без английского и без пересказа."
echo
echo "Если модель small окажется медленной на этом сервере — верните base:"
echo "  sudo -u hermes $REPO/venv/bin/python -c \"import yaml,os;p=os.path.expanduser('~/.hermes/config.yaml');d=yaml.safe_load(open(p));d['stt']['local']['model']='base';open(p,'w').write(yaml.safe_dump(d,allow_unicode=True,sort_keys=False))\""
echo "  systemctl restart hermes"
