#!/usr/bin/env bash
# Этап 3: упрощение маршрутизации моделей на сервере + диагностика медленных ответов.
# Запускать от root в консоли Timeweb.
set -uo pipefail
log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

HH=/home/hermes/.hermes
CFG=$HH/config.yaml
REPO=$HH/hermes-agent

log "1/6 Что настроено сейчас"
sudo -u hermes "$REPO/venv/bin/python" - <<'PYEOF'
import yaml, os
p = os.path.expanduser("~/.hermes/config.yaml")
d = yaml.safe_load(open(p)) or {}
print("  model:      ", d.get("model"))
print("  fallback:   ", d.get("fallback_providers") or "нет")
dl = d.get("delegation") or {}
print("  delegation: provider=%r model=%r concurrent=%s depth=%s"
      % (dl.get("provider"), dl.get("model"),
         dl.get("max_concurrent_children"), dl.get("max_spawn_depth")))
print("  providers:  ", list((d.get("providers") or {}).keys()))
PYEOF

log "2/6 Упрощение: одна основная модель, без цепочек"
cp "$CFG" "$CFG.bak-simplify-$(date +%s)"
sudo -u hermes "$REPO/venv/bin/python" - <<'PYEOF'
import re, os
p = os.path.expanduser("~/.hermes/config.yaml")
s = open(p).read()

def upsert(text, key, block):
    pat = re.compile(rf'^{key}:\n(?:[ \t]+.*\n|\n)*', re.M)
    return pat.sub(block, text, count=1) if pat.search(text) else text + "\n" + block

# Основная — DeepSeek через AIMLAPI: единственный провайдер, на котором сервер
# уже авторизован. Подписка ChatGPT подключается отдельным интерактивным входом.
s = upsert(s, "model", """model:
  default: deepseek/deepseek-v4-flash
  provider: aimlapi
""")

# Никаких цепочек: перебор провайдеров — главная причина долгих ответов.
s = re.sub(r'^fallback_providers:\n(?:[ \t]+.*\n|\n)*', "", s, flags=re.M)

# Делегирование на ту же основную модель, без отдельного провайдера.
s = upsert(s, "delegation", """delegation:
  model: ''
  provider: ''
  base_url: ''
  api_key: ''
  max_concurrent_children: 2
  max_spawn_depth: 1
  subagent_auto_approve: false
  orchestrator_enabled: true
""")
open(p, "w").write(s)
print("  ✅ конфиг упрощён")
PYEOF

log "3/6 Проверка валидности"
sudo -u hermes "$REPO/venv/bin/python" - <<'PYEOF'
import yaml, os
d = yaml.safe_load(open(os.path.expanduser("~/.hermes/config.yaml")))
print("  YAML валиден. model:", d.get("model"))
print("  fallback_providers:", d.get("fallback_providers") or "убран")
PYEOF

log "4/6 Замер: сколько реально занимает простой ответ"
sudo -u hermes -H bash -lc '
  cd ~ || exit 1
  S=$(date +%s)
  timeout 300 /home/hermes/.local/bin/hermes -z "Ответь одним словом: работает" \
      --usage-file /tmp/speed.json >/tmp/speed.txt 2>&1
  E=$(date +%s)
  echo "  ответ: $(head -c 80 /tmp/speed.txt)"
  echo "  время: $((E-S)) с"
  [ -f /tmp/speed.json ] && python3 -c "
import json;d=json.load(open(\"/tmp/speed.json\"))
print(f\"  модель={d.get(\\\"model\\\")} вызовов={d.get(\\\"api_calls\\\")} токенов={d.get(\\\"total_tokens\\\")}\")"
'

log "5/6 Перезапуск сервиса"
systemctl restart hermes 2>/dev/null || systemctl restart 'hermes-gateway-*' 2>/dev/null || true
sleep 15
systemctl is-active hermes 2>/dev/null && echo "  сервис активен"

log "6/6 Итог"
free -h | head -2
echo
echo "Основная модель: deepseek/deepseek-v4-flash через AIMLAPI, цепочек нет."
echo
echo "Если нужна подписка ChatGPT как основная — это отдельный интерактивный шаг:"
echo "  sudo -u hermes -H /home/hermes/.local/bin/hermes auth add openai-codex"
echo "напечатает ссылку и код, нужно открыть в браузере и подтвердить. После входа:"
echo "  sudo -u hermes -H /home/hermes/.local/bin/hermes config set model.provider openai-codex"
echo "  sudo -u hermes -H /home/hermes/.local/bin/hermes config set model.default gpt-5.6-luna"
echo "ВНИМАНИЕ: эти две команды под deny-правилами для агента, но от root в консоли работают."
