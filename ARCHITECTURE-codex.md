# Codex Executor: архитектура

Hermes остаётся единственным интерфейсом. Задачи по коду он целиком передаёт
Codex CLI, авторизованному подпиской ChatGPT. Платный OpenAI API не используется
никогда.

## Правило маршрутизации

```
задача про код или репозиторий  →  Codex получает формулировку ЦЕЛИКОМ
всё остальное                   →  DeepSeek
```

DeepSeek только классифицирует намерение и передаёт запрос **дословно**.
Он не пересказывает задачу, не пишет спецификацию, не готовит план — иначе
теряется контекст, а Codex всё равно читает репозиторий сам.

Классификация по намерению, не по ключевым словам:

| Запрос | Куда |
|---|---|
| «Почему сегодня упали продажи?» | DeepSeek |
| «Проанализируй, какой график продаж нам нужен» | DeepSeek |
| «Добавь на dashboard график продаж по дням» | Codex |
| «В Content Center сломалась публикация, исправь» | Codex |

## Цепочка

```
Я → Hermes → Router → Codex → ветка → PLAN → моё утверждение
  → реализация → тесты → commit → push → PR → CI → merge → deploy
```

Единственная остановка для человека — **утверждение плана**. После `APPROVE`
Codex работает автономно: правит файлы, ставит зависимости проекта, гоняет
линтер, тесты, сборку, чинит найденные ошибки и повторяет проверки.

## Запрет платного API — жёсткий

Codex работает **только** через OAuth ChatGPT (`~/.codex/auth.json`).

Запрещено:
- использовать `OPENAI_API_KEY` для coding-задач;
- создавать API-ключ автоматически;
- переключаться на API при отказе подписочной авторизации.

При отказе авторизации — статус `CODEX_AUTH_FAILED`, задача останавливается,
Hermes сообщает: «Codex недоступен, через платный API задача не запускалась».

При исчерпании лимита — `CODEX_LIMIT_REACHED`, автоматического перехода нет.
Fallback на DeepSeek — только по явному разрешению человека.

## Что уже есть в Hermes

Встроенный навык `autonomous-ai-agents/codex` закрывает основной цикл:

```
codex exec "<задача>"                        одноразовый запуск
codex exec ... background=true pty=true      длинные задачи
process(action="poll"|"log")                 ход выполнения
process(action="submit")                     ответ на вопрос Codex
process(action="kill")                       остановка
```

Навык прямо оговаривает подписочную авторизацию:

> *«a valid CLI OAuth session may live under `~/.codex/auth.json`; do not treat
> a missing `OPENAI_API_KEY` alone as proof that Codex auth is missing»*

**Важно для нашего случая.** При запуске из gateway-контекста (Telegram-сессия
на VPS) песочница `workspace-write` падает с ошибками bubblewrap
(`setting up uid map: Permission denied`), хотя в обычном шелле та же команда
работает. Рекомендация навыка — `--sandbox danger-full-access`, а безопасность
обеспечивать границами процесса: явный `workdir`, чистая ветка git.

Ограничения автономности (§10 ТЗ) уже закрыты `approvals.deny` — 18 правил,
запрещающих агенту менять свой конфиг, авторизацию, автозапуск и расписание.

## Что надо построить

| Компонент | Суть |
|---|---|
| TaskRouter | классификация намерения → Codex или DeepSeek |
| Статусы задачи | `ROUTING` → `CODEX_ANALYZING` → `AWAITING_PLAN_APPROVAL` → `CODEX_IMPLEMENTING` → `TESTING` → `PR_CREATED` → `CI_RUNNING` → `READY_FOR_MERGE` → `MERGED` → `DEPLOYED`, плюс `FAILED`, `CODEX_AUTH_FAILED`, `CODEX_LIMIT_REACHED` |
| Audit log | task_id, запрос, репозиторий, ветка, commit SHA, план, утверждение, изменённые файлы, тесты, PR, CI, merge, деплой |
| Usage tracking | число задач, запусков Codex, итераций, доля упавших на CI, близость лимита подписки |
| Продолжение задачи | «сделай 3 попытки вместо 5» → та же ветка и контекст, не новая работа |

## Репозиторий и ветки

Постоянный clone: `/opt/hermes/repos/publicia`.
Перед каждой задачей — `git fetch` и обновление целевой ветки; работать поверх
устаревшего состояния нельзя.

Ветка на задачу: `hermes/<task-id>-<slug>`, например
`hermes/184-content-center-publishing-fix`.

Доступ к GitHub — fine-grained token с минимумом прав: Contents R/W,
Pull Requests R/W, Metadata R. `main` — protected, прямой push запрещён.

## Чего Codex не делает сам

Merge в production, изменение секретов, SSH-конфигурации, firewall, удаление
production-базы, destructive-миграции, force push, изменение секретов GitHub
Actions и деплой-credentials. Для таких действий — отдельное утверждение.

Codex не ходит на production по SSH. Только:
`Codex → GitHub → CI/CD → Yandex Cloud`.

## Изоляция секретов

Hermes передаёт Codex **только текст задачи**. Не передаёт: credentials ChatGPT,
секреты GitHub и деплоя, `.env`, пароли production-базы. Доступ к рабочей
директории Codex получает правами файловой системы, а не через текст запроса.

`~/.codex/auth.json`: `chmod 600`, не в Git, не в логах, не в Telegram,
не показывается модели, не лежит внутри репозитория проекта. Первичный вход —
официальным `codex login` на самом VPS; перенос файла допустим только как
временный bootstrap.

## Модель

Не привязываться к названию конкретной модели. Требование — **лучшая доступная
coding-модель в рамках подписки**; Codex выбирает её сам, модельный ряд меняется.

## Health-check перед реализацией

`curl` к бэкенду ничего не доказывает. Проверять самим CLI:

```bash
npm install -g @openai/codex
codex login                      # официальный вход через ChatGPT
cd /tmp && mkdir t && cd t && git init
codex exec --sandbox danger-full-access "создай hello.py, печатающий привет"
env | grep -c OPENAI_API_KEY     # должно быть 0
```

Если `codex login` не отрабатывает на headless-VPS — весь запрет платного API
надо пересматривать до начала разработки, а не после.

## Статус

Health-check **не выполнен**: доступ к VPS закрыт баном `fail2ban`
(заработан отладочными подключениями). Снимается из консоли Timeweb:

```bash
fail2ban-client unban --all
```
