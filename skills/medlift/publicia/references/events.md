# Лента событий Publicia

## Как читать

```bash
bash ~/.hermes/scripts/publicia-events.sh --scope chat --limit 50
bash ~/.hermes/scripts/publicia-events.sh --scope cron --commit
bash ~/.hermes/scripts/publicia-events.sh --after evt_MTIz --types payment.failed,delivery.failed
```

Скрипт печатает компактный разбор без текстов сообщений и сам хранит курсор.
У фонового цикла (`--scope cron`) курсор свой, у разговора (`--scope chat`)
свой, поэтому ответ в Telegram не «съедает» события у планировщика.
`--after` перечитывает окно и курсор не двигает.

Сырой вызов, если нужен полный payload:

```bash
curl -sS -H "Authorization: Bearer $PUBLICIA_SERVICE_TOKEN" \
  "$PUBLICIA_BASE_URL/api/service/v1/events?after=$CURSOR&limit=100" | jq .
```

Параметры: `after`, `limit` (до 200, по умолчанию 100), `types` через запятую,
`since` (ISO), `deal_id`, `conversation_id`, `correlation_id`.

## Правила ленты

- Курсор вида `evt_<base64url>`. Порядок строго по внутреннему номеру, а не по
  времени: `occurred_at` может идти не по возрастанию, курсор — всегда.
- `next_cursor` приходит даже на пустой странице: это тот же курсор, что был.
- Лента начинается с момента включения шлюза. Истории до него в ней нет
  и не будет — за прошлым идти в `POST /exports`.
- События хранятся **90 дней**, дальше удаляются фоновой уборкой.
- Неизвестный тип в `types` — `400 unknown_event_type`.
- `correlation_id` — корень цепочки: `deal:{id}`, иначе `conversation:{id}`,
  иначе `client:{id}`, иначе `system`. По нему собирается вся история: рассылка
  → сообщение → диалог → попытка оплаты → оплата → продажа.

## Каталог: 22 типа

| Тип | Когда | Куда смотреть дальше |
|---|---|---|
| `dialog.message_in` | клиент написал в канал (VK, Telegram, Senler) | `GET /conversations/{kind}/{id}` |
| `dialog.message_out` | исходящее клиенту ушло в канал | `payload.deliveryStatus`; сбой придёт как `delivery.failed` |
| `payment.succeeded` | оплата подтверждена и разнесена по сделке | `GET /payments/{kind}/{id}` |
| `payment.failed` | платёж не прошёл или отменён, включая рассрочку | `GET /payments/{kind}/{id}`, затем задача менеджеру |
| `payment.refunded` | возврат, полный или частичный | `GET /payments/{kind}/{id}` |
| `checkout.started` | клиенту выдана ссылка на оплату | ждать `payment.succeeded` или `checkout.abandoned` |
| `checkout.abandoned` | ссылка выдана, оплаты нет | `GET /conversations/{kind}/{id}` |
| `funnel.no_progress` | сделка стоит на этапе дольше срока | `GET /sla/violations` |
| `task.created` | задача менеджеру создана | `GET /tasks` |
| `escalation.created` | диалог передан человеку или открыта карточка | `GET /escalations`, `GET /attention` |
| `escalation.resolved` | эскалация закрыта | `GET /escalations?status=RESOLVED` |
| `deal.stage_changed` | сделка сменила этап воронки | `GET /conversations/deal/{id}` |
| `conversation.needs_human` | ИИ-поддержка передала диалог оператору | `GET /conversations/support/{id}` |
| `ticket.created` | заведено обращение со сроками SLA | `GET /tickets` |
| `ticket.sla_breached` | тикет просрочил первый ответ или решение | `GET /sla/violations`, затем инцидент `SLA_BREACH` |
| `delivery.failed` | сообщение клиенту не ушло, канал вернул ошибку | `GET /system-health` |
| `ai.skipped` | ИИ не ответил; смотри `payload.reason` и `payload.retryable` | `GET /conversations/{kind}/{id}` |
| `attention.created` | менеджеру открыта карточка внимания | `GET /attention` |
| `incident.created` | заведён инцидент | `GET /incidents/{id}` |
| `incident.updated` | у инцидента сменился статус, владелец или добавлено действие | `GET /incidents/{id}` |
| `incident.resolved` | инцидент закрыт с решением и проверкой | `GET /incidents/{id}` |
| `health.component_changed` | компонент сменил состояние | `GET /system-health` |

Рассрочка отдельной сущностью не моделируется: неудачный платёж по рассрочке
приходит как `payment.failed`, а зависшие неоплаченные заказы видны в
компоненте `payments` у `system-health`.

`health.component_changed` приходит только на переходах и никогда на первом
наблюдении после перезапуска — отсутствие события не значит «всё хорошо».

## Состояние системы

`GET /system-health` отдаёт 12 компонентов: `db`, `redis`, `worker`,
`ai_provider`, `vk`, `telegram`, `message_delivery`, `inbound_webhooks`,
`payments`, `outbox`, `service_webhooks`, `background_jobs`.

Статусы: `ok`, `degraded`, `down`, `unknown`.

Как читать:

- `message_delivery: down` при тишине в продажах — это поломка, а не спад спроса;
- `vk` или `telegram: down` — приёмник входящих молчит больше часа: клиенты
  пишут, мы не слышим;
- `worker: down` — фоновые свипы стоят: follow-up, ретраи и доставка не идут;
- `ai_provider: down` — модель не подключена, ИИ отвечает заглушкой;
- `unknown` — проверка не выполнилась. Это не «всё хорошо», а «не знаем».

**Общий `status` считается только по `ok`, `degraded` и `down`.** Компоненты
в `unknown` на него не влияют: при `redis` и `worker` в `unknown` общий статус
всё равно будет `ok`. Поэтому читай компоненты, а не итог.
