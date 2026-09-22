# Карта ручек Publicia

База: `$PUBLICIA_BASE_URL/api/service/v1`. Заголовок `Authorization: Bearer $PUBLICIA_SERVICE_TOKEN`.

Колонка «журнал» — попадает ли вызов в лимиты частоты, заголовки `X-RateLimit-*`,
обработку `Idempotency-Key` и `GET /audit-log`. Это не косметика: на ручках без
журнала ключ идемпотентности **молча игнорируется**, и повтор после сбоя сети
создаст вторую запись.

## Без токена

| Ручка | Что отдаёт |
|---|---|
| `GET /` | манифест: права, ручки, лимиты, запреты |
| `GET /openapi.json` | OpenAPI 3.1 из того же реестра |

## Состояние и события

| Ручка | Право | Журнал | Что отдаёт |
|---|---|---|---|
| `GET /health` | любой живой токен | нет | имя токена, права, срок |
| `GET /system-health` | `health:read` | да | 12 компонентов, статусы, подсказки |
| `GET /events` | `events:read` | да | лента по курсору |
| `GET /events/types` | `events:read` | да | каталог 22 типов с подсказками |
| `GET /events/{id}` | `events:read` | да | одно событие |
| `GET /audit-log` | `audit:read` | да | собственные вызовы агента |

`GET /system-health` кэшируется 60 секунд, `?force=true` пересчитывает.
Внешние API при проверке не опрашиваются.

## Контекст

| Ручка | Право | Журнал | Что отдаёт |
|---|---|---|---|
| `GET /conversations` | `data:read` | да | диалоги продаж и поддержки одним списком |
| `GET /conversations/{kind}/{id}` | `data:read` | да | карточка: сообщения, задачи, эскалации, оплаты |
| `GET /conversations/{kind}/{id}/thread` | `data:read` | да | только переписка; курсор называется `next_before` |
| `GET /customers/{id}` | `data:read` | да | клиент целиком |
| `GET /payments`, `GET /payments/{kind}/{id}` | `data:read` | да | платежи; `kind` = `scopus`, `marketplace`, `referral_bot` |
| `GET /tasks` | `data:read` | да | задачи менеджеров |
| `GET /escalations` | `data:read` | да | передачи человеку |
| `GET /attention` | `data:read` | да | карточки внимания |
| `GET /tickets` | `data:read` | да | обращения со сроками SLA |
| `GET /employees` | `data:read` | да | сотрудники: роль, каналы, нагрузка |
| `GET /sla/violations` | `data:read` | да | просрочки одним списком |
| `GET /incidents`, `GET /incidents/{id}` | `incidents:read` | да | инциденты и баг-репорты |

`kind` у диалога — `deal` или `support`.

Полезные фильтры: `/conversations?awaiting=human&sla=breached`,
`/attention?status=OPEN`, `/escalations?status=OPEN`, `/tickets?sla=breached`,
`/incidents?status=OPEN&severity=P1`.

Форма списков здесь единая: `{items, next_cursor, has_more}`, `limit` до 200.

## Действия

Все действия внутренние. Клиент не увидит ничего из этого.

| Ручка | Право | Журнал | Обязательные поля |
|---|---|---|---|
| `POST /actions/escalate-conversation` | `actions:write` | да | `reason` (+ `deal_id` или `conversation_id`) |
| `POST /actions/raise-attention` | `actions:write` | да | `deal_id`, `category`, `title`, `reason` |
| `POST /actions/notify-employee` | `actions:write` | да | `title`, `body` (+ `user_id` или `role`) |
| `POST /actions/create-ticket` | `actions:write` | да | `subject`, `body` |
| `POST /actions/create-incident` | `incidents:write` | да | `external_key`, `type`, `severity`, `title` |
| `POST /actions/update-incident` | `incidents:write` | да | `id` |
| `POST /actions/create-bug-report` | `incidents:write` | да | `description` |
| `POST /actions/propose` | `proposals:write` | да | `external_key`, `title`, `change`, `rationale` |
| `POST /actions/create-task` (= `POST /tasks`) | `tasks:write` | **нет** | `title` |
| `POST /actions/add-note` (= `POST /notes`) | `tasks:write` | **нет** | `dealId`, `text` |
| `POST /actions/add-knowledge-proposal` | `drafts:write` | **нет** | `kind` |
| `POST /proposals` | `proposals:write` | **нет** | пачка предложений по улучшению ИИ |
| `POST /content/items` | `content:write` | **нет** | заготовка поста «на проверке» |

Перечисления:

- `escalate-conversation.priority`: `CRITICAL`, `HIGH`, `NORMAL`
- `raise-attention.category`: `HOT_NO_REPLY`, `ASKED_HUMAN`, `AI_UNCERTAIN`,
  `STUCK_PAYMENT`, `READY_TO_BUY`, `NONSTANDARD`, `CHURN_RISK`,
  `OVERDUE_ACTION`, `CONFLICT`, `FOLLOWUP_EXHAUSTED`, `OTHER`
- `notify-employee.role`: `ADMIN`, `MANAGER`, `EXECUTOR`, `PRODUCTION_LEAD`, `PRODUCTION_WORKER`
- `create-ticket.priority`: `HIGH`, `MEDIUM`, `LOW` (она же задаёт сроки SLA)
- `create-task.priority`: `high`, `normal`, `low` — внимание, здесь нижний регистр
- `propose.risk`: `low`, `medium`, `high`; `propose.product_area`: `sales`, `support`, `ops`
- `add-knowledge-proposal.kind`: `knowledge`, `template`; `area`: `sales`, `support`

Платформа сама дедуплицирует эскалации с одинаковой причиной — повтор
не завалит менеджера одинаковыми карточками.

## Ответ 201 не значит «человек увидел»

`POST /actions/notify-employee` возвращает `{recipients, push, telegram_queued}`.
Эти числа надо читать, а не пропускать.

- `recipients` — сколько сотрудников подошло под `user_id` или `role`.
- `push` — сколько браузерных уведомлений реально ушло.
- `telegram_queued` — сколько сообщений поставлено в очередь Telegram.

`telegram_queued: 0` при ненулевом `recipients` значит, что **ни у кого из них
не привязан Telegram**. Платформа берёт `telegramId` из карточки сотрудника и
молча пропускает пустые и значения вида `@handle`. Это не сбой вызова, но и не
доставка.

Если `push` и `telegram_queued` оба нули, уведомление не дошло ни до кого.
Писать «уведомил ADMIN» в таком случае нельзя. Правильный ход: сказать прямо,
что канала до человека нет, и завести или обновить инцидент, чтобы проблема
осталась видимой в админке, а не растворилась в неотправленном уведомлении.

## Старые ручки: форма ответа другая

| Ручка | Право | Отдаёт |
|---|---|---|
| `GET /metrics` | `data:read` | `{period, kpis, funnel, …}` |
| `GET /deals` | `data:read` | `{deals, nextCursor, saltFingerprint}` |
| `GET /deals/{id}` | `data:read` | сделка с историей диалога |
| `GET /listings` | `data:read` | `{listings, tariffCatalog, …}`, курсора нет |
| `GET /knowledge` | `data:read` | `{area, articles}`, курсора нет |
| `GET /templates` | `data:read` | `{templates}`, курсора нет |
| `GET /proposals` | `proposals:read` | `{proposals}`, жёсткий предел 200, курсора нет |
| `GET /content/channels`, `GET /content/items` | `content:read` | `{channels}` / `{items}` |
| `GET /managers/*`, `GET /sales/summary`, `GET /attribution/review` | `managers:read` | свои формы |
| `POST /exports`, `GET /exports/{id}`, `GET /exports/{id}/download` | `export:read` | обезличенный ZIP за период |

У `/metrics` поля `prev*` и `*Delta` — сравнение с прошлым периодом. Если
`prev` равен нулю, данных за прошлый период нет: о динамике говорить нельзя.

У `/listings` решают `freeSeats` и `sendBy` — именно они определяют, что
реально можно продать сегодня.

Одновременных задач выгрузки не больше трёх, иначе `429 too_many_jobs`.

## Ошибки

Всегда `{"ok": false, "error": "<код>", "details": {…}}`.

| HTTP | error | Что делать |
|---|---|---|
| 400 | `bad_request` | смотреть `details`, чинить запрос |
| 400 | `bad_cursor` | курсор повреждён, начать ленту заново без `after` |
| 400 | `unknown_event_type` | сверить тип с `GET /events/types` |
| 400 | `https_required`, `private_address_not_allowed`, `bad_url` | адрес подписки не принят |
| 401 | `unauthorized` | токена нет, он отозван или просрочен |
| 403 | `forbidden` | у токена нет права; список — в `GET /health` |
| 404 | `*_not_found` | сущности нет; `no_recipients` — некому слать уведомление |
| 409 | `idempotency_in_flight` | прошлый запрос с тем же ключом ещё идёт, повторить через секунду |
| 409 | `invalid_transition` | такой переход статуса инцидента запрещён |
| 409 | `too_many_endpoints` | больше 10 подписок нельзя |
| 413 | `body_too_large` | тело больше 64 КБ |
| 422 | `resolution_required` | закрыть инцидент без `resolution` и `verification` нельзя |
| 429 | `rate_limited` | ждать `Retry-After` секунд |
| 429 | `too_many_jobs` | уже три активные выгрузки |
| 503 | `anonymization_unavailable` | на сервере не настроена соль обезличивания, сообщить владельцу |
| 500 | `internal_error` | сбой на стороне платформы |

## Обезличивание

Без права `pii:read` имена, телефоны, email и id каналов заменены устойчивыми
псевдонимами (`client_7f…`, `channel_…`), тексты сообщений маскируются.
Псевдоним один и тот же во всех ответах и выгрузках, поэтому повторные
обращения считаются и без персональных данных.

Важно: на старых ручках (`/deals`, `/listings`, `/knowledge`, `/templates`,
`/managers/*`, `/attribution/review`) обезличивание включено **всегда**, даже
если у токена есть `pii:read`.
