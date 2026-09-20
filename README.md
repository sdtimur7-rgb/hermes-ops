# hermes-ops

Правки и конфигурация для Hermes на сервере Publicia / MEDLIFT.

**Схема доставки — pull, не push.** С Mac в РФ SSH до Timeweb не проходит
(оператор режет по DPI, проверено измерениями). Поэтому Mac пушит сюда,
а сервер сам забирает по HTTPS.

```
Mac (РФ) ──git push──► GitHub ◄──git pull── сервер Timeweb
```

Секретов в репозитории нет — токены передаются переменными окружения.

## Что внутри

```
patches/cron-provider-snapshot.patch   исправление бага cron
skills/medlift/publicia/SKILL.md       навык: платформа Publicia
skills/medlift/publicia/references/    справочники навыка, грузятся по требованию
agent-scripts/publicia-pulse.sh        снимок состояния платформы (монитор-режим cron)
agent-scripts/publicia-events.sh       чтение ленты событий по курсору
scripts/apply.sh                       применить всё на сервере
scripts/stage2.sh                      правка cron + токен Publicia + навык
scripts/stage3.sh                      упрощение маршрутизации моделей
scripts/server-setup.sh                первичное развёртывание (cloud-init)
scripts/connect-proxy.py               SSH через HTTP CONNECT-прокси (для Mac)
scripts/dpi-proxy.py                   фрагментирующий прокси против DPI (для Mac)
```

## Исправление бага cron

**Симптом.** Любая задача планировщика с ИИ падала при срабатывании:
`RuntimeError: No LLM provider configured`.

**Причина.** При создании задачи снапшот провайдера сохранял родовое имя
семейства (`custom`) вместо фактического ключа (`aimlapi`). При срабатывании
`custom` резолвился в runtime **без api_key и с чужим base_url** (OpenRouter),
ошибки при этом не возникало — поэтому ни fallback, ни fail-fast не срабатывали.

**Правки.**

`cron/jobs.py` — снапшотить имя, которое резолвер умеет восстановить:

```python
provider_snapshot = (
    str(snap.get("requested_provider") or snap.get("provider") or "")
    .strip().lower() or None
)
```

`cron/scheduler.py` — родовые литералы не принимать как валидный пин;
это же оживляет задачи, созданные до исправления:

```python
if requested and str(requested).strip().lower() in {"custom", "auto"}:
    requested = global_provider or None
```

**Проверено** реальной цепочкой (`load_config` → `resolve_runtime_provider` →
`_resolve_job_runtime`) на временном `HERMES_HOME`, без моков:

| Сценарий | Результат |
|---|---|
| Снапшот пользовательского провайдера | `aimlapi` вместо `custom`, ключ есть |
| Задача со снапшотом `custom` (состояние сервера) | оживает, ключ есть |
| Задача со снапшотом `aimlapi` | работает |
| Задача без снапшота (legacy) | работает |
| Явный `provider=aimlapi` | пин соблюдён |
| Явный снапшот `openrouter` | пин соблюдён, регресса нет |

## Применение на сервере

Разово, от root в консоли Timeweb:

```bash
cd /home/hermes && sudo -u hermes git clone https://github.com/sdtimur7-rgb/hermes-ops.git ops
export PUB_TOKEN='<токен Publicia>'
bash /home/hermes/ops/scripts/apply.sh
```

Дальше обновления забираются одной командой (её может выполнять и сам агент
по команде из Telegram):

```bash
cd /home/hermes/ops && git pull && export PUB_TOKEN='<токен>' && bash scripts/apply.sh
```

## Приёмка

```bash
sqlite3 /home/hermes/.hermes/cron/executions.db \
  "select job_id,status,delivery_outcome,substr(error,1,120) from executions order by rowid desc limit 3;"
```

Ожидается `status=completed`, `delivery_outcome=delivered`, `error` пусто.
