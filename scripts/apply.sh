#!/usr/bin/env bash
# Применить правки из репозитория на сервере. Запускать от root.
# Идемпотентный: повторный запуск скажет «уже применено».
#   export PUB_TOKEN='<токен Publicia>'   # нужен только для шага с Publicia
#   bash scripts/apply.sh
set -uo pipefail
log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HH=/home/hermes/.hermes
REPO=$HH/hermes-agent

log "0/5 Окружение"
[ -d "$REPO" ] || { echo "нет $REPO — Hermes не установлен"; exit 1; }
sudo -u hermes "$REPO/venv/bin/python" -c "import sys;print('  python',sys.version.split()[0])"
echo "  версия Hermes: $(sudo -u hermes "$REPO/venv/bin/python" -c "
import re,os
p=os.path.join('$REPO','hermes_cli','__init__.py')
try: print(re.search(r'__version__\s*=\s*[\"\\']([^\"\\']+)', open(p).read()).group(1))
except Exception: print('?')" 2>/dev/null)"

log "1/5 Правка бага cron"
cd "$REPO" || exit 1
if grep -q "requested_provider" cron/jobs.py && grep -q 'in {"custom", "auto"}' cron/scheduler.py; then
  echo "  уже применено"
else
  for f in cron/jobs.py cron/scheduler.py; do cp "$f" "$f.bak-$(date +%s)"; done
  if sudo -u hermes git apply --check "$HERE/patches/cron-provider-snapshot.patch" 2>/dev/null; then
    sudo -u hermes git apply "$HERE/patches/cron-provider-snapshot.patch" && echo "  ✅ патч применён"
  else
    echo "  патч не встал чисто (версия репозитория отличается) — правлю точечно"
    sudo -u hermes python3 - <<'PYEOF'
import re
# jobs.py
p = "/home/hermes/.hermes/hermes-agent/cron/jobs.py"
s = open(p).read()
old = '            provider_snapshot = str(snap.get("provider") or "").strip().lower() or None'
new = ('            provider_snapshot = (\n'
       '                str(snap.get("requested_provider") or snap.get("provider") or "")\n'
       '                .strip().lower() or None\n'
       '            )')
if "requested_provider" in s:
    print("    jobs.py уже ок")
elif old in s:
    open(p, "w").write(s.replace(old, new, 1)); print("    ✅ jobs.py")
else:
    print("    ⚠ jobs.py: строка не найдена")
# scheduler.py
p2 = "/home/hermes/.hermes/hermes-agent/cron/scheduler.py"
s2 = open(p2).read()
anchor = '        requested = _snapshot_pin(job, "provider", global_provider, job_id) or None'
add = (anchor + '\n'
       '        if requested and str(requested).strip().lower() in {"custom", "auto"}:\n'
       '            requested = global_provider or None')
if 'in {"custom", "auto"}' in s2:
    print("    scheduler.py уже ок")
elif anchor in s2:
    open(p2, "w").write(s2.replace(anchor, add, 1)); print("    ✅ scheduler.py")
else:
    print("    ⚠ scheduler.py: опорная строка не найдена")
PYEOF
  fi
fi

log "2/5 Проверка: резолв провайдера даёт ключ"
sudo -u hermes bash -lc "cd $REPO && ./venv/bin/python - <<'PY'
import sys; sys.path.insert(0, '.')
from hermes_cli.runtime_provider import resolve_runtime_provider
import cron.jobs as J
snap, model = J._compute_provider_model_snapshots(provider=None, model=None, base_url=None, no_agent=False)
print(f'  снапшот: {snap!r}  модель: {model!r}')
rt = resolve_runtime_provider(requested=snap, target_model=model or 'deepseek/deepseek-v4-flash')
print('  ИТОГ:', 'OK ключ есть' if rt.get('api_key') else 'ПЛОХО ключа нет',
      '| base_url:', str(rt.get('base_url'))[:44])
PY"

log "3/5 Навык Publicia и инструменты агента"
sudo -u hermes mkdir -p "$HH/skills/medlift/publicia/references" "$HH/scripts" "$HH/state/publicia"
sudo -u hermes cp "$HERE/skills/medlift/publicia/SKILL.md" "$HH/skills/medlift/publicia/SKILL.md"
sudo -u hermes cp "$HERE"/skills/medlift/publicia/references/*.md "$HH/skills/medlift/publicia/references/"
echo "  навык установлен ($(ls -1 "$HH/skills/medlift/publicia/references" | wc -l | tr -d ' ') справочника)"

# Скрипты планировщика обязаны лежать именно в $HH/scripts — путь проверяется
# на выход за каталог (cron/scheduler_script.py), symlink не подойдёт.
sudo -u hermes cp "$HERE"/agent-scripts/publicia-*.sh "$HH/scripts/"
sudo -u hermes chmod +x "$HH"/scripts/publicia-*.sh
echo "  инструменты установлены: $(ls -1 "$HH"/scripts/publicia-*.sh | xargs -n1 basename | tr '\n' ' ')"

if [ -n "${PUB_TOKEN:-}" ]; then
  grep -q '^PUBLICIA_SERVICE_TOKEN=' "$HH/.env" 2>/dev/null \
    && sed -i "s|^PUBLICIA_SERVICE_TOKEN=.*|PUBLICIA_SERVICE_TOKEN=${PUB_TOKEN}|" "$HH/.env" \
    || printf '\nPUBLICIA_SERVICE_TOKEN=%s\nPUBLICIA_BASE_URL=https://publicia.ru\n' "$PUB_TOKEN" >> "$HH/.env"
  chown hermes:hermes "$HH/.env"; chmod 600 "$HH/.env"
  echo "  токен записан, проверка:"
  curl -s -m 20 "https://publicia.ru/api/service/v1/health" \
    -H "Authorization: Bearer ${PUB_TOKEN}" -H "Accept: application/json" | head -c 200; echo
else
  echo "  PUB_TOKEN не задан — токен не менял (навык всё равно обновлён)"
fi

log "4/5 Перезапуск"
systemctl restart hermes 2>/dev/null || systemctl restart 'hermes-gateway-*' 2>/dev/null || true
sleep 15
systemctl is-active hermes 2>/dev/null && echo "  сервис активен" || echo "  ⚠ сервис не активен"

log "5/5 Итог"
free -h | head -2
echo
echo "Приёмка — создайте в Telegram задачу с ИИ на 2 минуты, затем:"
echo "  sqlite3 $HH/cron/executions.db \"select job_id,status,delivery_outcome,substr(error,1,120) from executions order by rowid desc limit 3;\""
