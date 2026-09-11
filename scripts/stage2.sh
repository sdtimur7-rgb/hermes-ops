#!/usr/bin/env bash
# Этап 2 для сервера: правка бага cron, токен Publicia, навык платформы,
# упрощение маршрутизации. Запускать от root в консоли Timeweb.
set -uo pipefail
log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

HH=/home/hermes/.hermes
REPO=$HH/hermes-agent
: "${PUB_TOKEN:?нужен PUB_TOKEN}"

log "0/5 Проверка окружения"
[ -d "$REPO" ] || { echo "нет репозитория $REPO"; exit 1; }
sudo -u hermes "$REPO/venv/bin/python" -c "import sys;print('  python',sys.version.split()[0])"
systemctl is-active hermes 2>/dev/null || systemctl is-active 'hermes-gateway-*' 2>/dev/null || echo "  (сервис не активен)"

log "1/5 Баг cron: снапшот провайдера"
# Причина: снапшот сохраняет родовое имя 'custom' вместо фактического 'aimlapi'.
# При срабатывании 'custom' резолвится в runtime без ключа → No LLM provider configured.
F=$REPO/cron/jobs.py
cp "$F" "$F.bak-$(date +%s)"
sudo -u hermes python3 - "$F" <<'PYEOF'
import sys, re
p = sys.argv[1]
s = open(p).read()
old = '            provider_snapshot = str(snap.get("provider") or "").strip().lower() or None'
new = ('            # Снапшотим имя, которое резолвер умеет восстановить, а не родовое\n'
       '            # семейство. Для пользовательского провайдера (providers: в config.yaml)\n'
       '            # семейство = "custom", а requested_provider = фактический ключ ("aimlapi").\n'
       '            # Повторный резолв "custom" даёт runtime без api_key и с чужим base_url,\n'
       '            # поэтому каждая такая задача падала в "No LLM provider configured".\n'
       '            provider_snapshot = (\n'
       '                str(snap.get("requested_provider") or snap.get("provider") or "")\n'
       '                .strip().lower() or None\n'
       '            )')
if new.strip() in s:
    print("  уже пропатчено")
elif old in s:
    open(p, "w").write(s.replace(old, new, 1))
    print("  ✅ jobs.py пропатчен")
else:
    print("  ⚠ строка не найдена — проверить вручную:", p)
PYEOF

log "2/5 Обратная совместимость: нормализация старых снапшотов"
# Уже сохранённые задачи имеют provider_snapshot='custom'. Чтобы они ожили без
# пересоздания, приводим невалидные родовые литералы к глобальному провайдеру.
F2=$REPO/cron/scheduler.py
cp "$F2" "$F2.bak-$(date +%s)"
sudo -u hermes python3 - "$F2" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = '        requested = _snapshot_pin(job, "provider", global_provider, job_id) or None'
if "GENERIC_PROVIDER_PINS" in s:
    print("  уже пропатчено")
elif anchor in s:
    patched = (
        '        requested = _snapshot_pin(job, "provider", global_provider, job_id) or None\n'
        '        # Родовые литералы не являются именами провайдеров: "custom" резолвится в\n'
        '        # runtime без ключа. Такой снапшот игнорируем и берём глобальный провайдер —\n'
        '        # так оживают задачи, созданные до исправления снапшота.\n'
        '        GENERIC_PROVIDER_PINS = {"custom", "auto"}\n'
        '        if requested and str(requested).strip().lower() in GENERIC_PROVIDER_PINS:\n'
        '            requested = global_provider or None'
    )
    open(p, "w").write(s.replace(anchor, patched, 1))
    print("  ✅ scheduler.py пропатчен")
else:
    print("  ⚠ опорная строка не найдена — проверить вручную:", p)
PYEOF

log "3/5 Проверка правок: резолв провайдера"
sudo -u hermes bash -lc "cd $REPO && ./venv/bin/python - <<'PY'
import sys; sys.path.insert(0, '.')
from hermes_cli.runtime_provider import resolve_runtime_provider
for req in ['aimlapi', None, 'custom']:
    try:
        rt = resolve_runtime_provider(requested=req, target_model='deepseek/deepseek-v4-flash')
        print(f'  {str(req):8} -> requested={rt.get(\"requested_provider\")} key={\"есть\" if rt.get(\"api_key\") else \"НЕТ\"} base_url={str(rt.get(\"base_url\"))[:40]}')
    except Exception as e:
        print(f'  {str(req):8} -> {type(e).__name__}: {str(e)[:60]}')
PY"

log "4/5 Publicia: токен и навык"
grep -q '^PUBLICIA_SERVICE_TOKEN=' "$HH/.env" 2>/dev/null \
  && sed -i "s|^PUBLICIA_SERVICE_TOKEN=.*|PUBLICIA_SERVICE_TOKEN=${PUB_TOKEN}|" "$HH/.env" \
  || printf '\n# Publicia — сервисный API платформы\nPUBLICIA_SERVICE_TOKEN=%s\nPUBLICIA_BASE_URL=https://publicia.ru\n' "$PUB_TOKEN" >> "$HH/.env"
chown hermes:hermes "$HH/.env"; chmod 600 "$HH/.env"
echo "  токен записан"

echo "  проверка токена:"
curl -s -m 20 "https://publicia.ru/api/service/v1/health" \
  -H "Authorization: Bearer ${PUB_TOKEN}" -H "Accept: application/json" | head -c 220; echo

sudo -u hermes mkdir -p "$HH/skills/medlift/publicia"
sudo -u hermes curl -fsSL --retry 4 \
  https://gist.githubusercontent.com/sdtimur7-rgb/57917899ca4e35e9894325c586971e23/raw/SKILL.md \
  -o "$HH/skills/medlift/publicia/SKILL.md" 2>/dev/null \
  || echo "  (навык дольём отдельно — см. инструкцию)"

log "5/5 Перезапуск и итог"
systemctl restart hermes 2>/dev/null || systemctl restart 'hermes-gateway-*' 2>/dev/null || true
sleep 15
systemctl is-active hermes 2>/dev/null && echo "  сервис активен"
free -h | head -2
echo
echo "ГОТОВО. Дальше: создайте в Telegram задачу с ИИ на 2 минуты и проверьте,"
echo "что она завершилась со статусом completed:"
echo "  sqlite3 $HH/cron/executions.db \"select job_id,status,delivery_outcome,substr(error,1,120) from executions order by rowid desc limit 3;\""
