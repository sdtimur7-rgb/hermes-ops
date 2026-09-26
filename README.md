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
scripts/backup-setup.sh                бэкап сервера: разовая установка (от hermes, без root)
agent-scripts/hermes-backup.sh         бэкап сервера: ночной запуск
backup/hermes_backup.py                снимок, зашифрованный архив, расшифровка
backup/backup_public.pem               открытый ключ шифрования архива (закрытый — только на Mac)
mac/install-backup-pull.sh             Mac: клон бэкапа и ежедневная задача launchd
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

## Дежурная задача по Publicia

`apply.sh` ставит навык и инструменты, но задачу планировщика не создаёт:
расписание заводит оператор. Команда одна, скрипт к этому моменту уже на месте.

```bash
hermes cron create '15m' '<промпт дежурства>' --name publicia-pulse \
  --monitor-script publicia-pulse.sh --skill publicia \
  --deliver telegram:<chat_id> --failure-deliver telegram:<chat_id>
```

Монитор-скрипт выполняется до модели и гасит запуск, когда снимок состояния
не изменился, поэтому тихие тики ничего не стоят.

С версии навыка 2.1 пульс видит и просроченные задачи (`tasks_overdue`,
`tasks_overdue_l3` — диапазонами), так что дежурная задача просыпается, когда
просрочка сдвинулась заметно, а не на каждую из сотни эскалаций в сутки.

Суточный отчёт по задачам — отдельная задача без монитора. Время — по часам
сервера: проверьте `date`; если там UTC, 9:00 МСК — это `0 6 * * *`.

```bash
hermes cron create '0 6 * * *' 'Суточный отчёт по задачам Publicia за прошедшие сутки по разбору «Суточный отчёт по задачам» из навыка publicia.' \
  --name publicia-tasks-daily --skill publicia \
  --deliver telegram:<chat_id> --failure-deliver telegram:<chat_id>
```

Две вещи, на которых легко споткнуться:

- `--deliver telegram` без идентификатора чата не резолвится, прогон кончается
  `delivery_failed`. Нужен `telegram:<chat_id>` либо `origin`, если задачу
  создают из переписки, а не из консоли.
- Блок «Job notepad» подставляется в промпт, только когда в блокноте что-то
  есть. Ссылаться в промпте на этот блок нельзя — на первом прогоне его нет.
  Команду надо писать в промпте целиком, с подставленным id задачи.

## Бэкап сервера

Всё, что владелец делает с Hermes через Telegram — навыки, память, дежурные задачи,
настройки, — живёт только на сервере. Этот репозиторий туда только **везёт**, обратно
ничего не приходит. Поэтому сервер сам каждую ночь отправляет копию в приватный
репозиторий `sdtimur7-rgb/hermes-server-backup`, а Mac забирает её к себе.

| Ветка | Что | История |
|---|---|---|
| `main` | открытый снимок: навыки, память, задачи, настройки, cron и службы. Секреты вычищены | копится по дням |
| `vault` | полный архив: `.env`, ключи, базы. Зашифрован открытым ключом из `backup/` | только последний; 14 штук хранит Mac |

Установка на сервере — от пользователя hermes, без root. Может выполнить сам Hermes:

```bash
cd /home/hermes/ops && git pull && bash scripts/backup-setup.sh
```

При первом запуске скрипт создаёт ключ доступа и печатает его открытую часть: её нужно
добавить в репозиторий бэкапа как deploy key с правом записи. После этого —
`bash ~/.hermes/scripts/hermes-backup.sh`, дальше cron сам в 03:17.

На Mac (уже установлено): `~/hermes-server-backup` — снимок, `~/hermes-server-backup-vault` —
архивы, задача launchd `com.hermes.server-backup-pull` ежедневно в 10:30. Если архив не
обновлялся двое суток — уведомление macOS. Сбой ночного запуска сервер сам пишет в Telegram.

Закрытый ключ архива — `~/.hermes-backup-keys/backup_private.pem` на Mac, в единственном
экземпляре. Без него архивы не открыть: держите копию в менеджере паролей.

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
