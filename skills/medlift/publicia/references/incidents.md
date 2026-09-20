# Инциденты Publicia

Инцидент — то, как ты фиксируешь проблему и доводишь её до закрытия.
Разовый случай — задача менеджеру. Повторяющийся или системный — инцидент.

Сотрудники заводят такие же инциденты из админки (`/admin/incidents`), поэтому
вторую систему учёта вести не нужно.

## Перечисления

**Тип:** `SLA_BREACH`, `DELIVERY_FAILURE`, `PAYMENT_RECOVERY`, `AI_QUALITY`,
`SYSTEM`, `SECURITY`, `BUG`, `OTHER`.

**Важность:** `P0`, `P1`, `P2`, `P3`.

**Статус:** `OPEN`, `INVESTIGATING`, `ACTION_REQUIRED`, `MONITORING`,
`RESOLVED`, `FALSE_POSITIVE`.

## Граф переходов — не цепочка

Это именно граф, а не лестница. Из `OPEN` можно сразу в `RESOLVED`, если
проблема оказалась пустяковой.

| Из | Куда можно |
|---|---|
| `OPEN` | `INVESTIGATING`, `ACTION_REQUIRED`, `MONITORING`, `RESOLVED`, `FALSE_POSITIVE` |
| `INVESTIGATING` | `ACTION_REQUIRED`, `MONITORING`, `RESOLVED`, `FALSE_POSITIVE`, `OPEN` |
| `ACTION_REQUIRED` | `INVESTIGATING`, `MONITORING`, `RESOLVED`, `OPEN` |
| `MONITORING` | `RESOLVED`, `INVESTIGATING`, `OPEN` |
| `RESOLVED` | `OPEN` |
| `FALSE_POSITIVE` | `OPEN` |

Две ловушки:

- из `ACTION_REQUIRED` **нельзя** в `FALSE_POSITIVE` — сначала верни в
  `INVESTIGATING` или `OPEN`;
- повторная установка того же статуса не ошибка, но и не событие: запись
  в журнал появится, `incident.resolved` повторно не придёт.

Запрещённый переход — `409 invalid_transition`.

Возврат из `RESOLVED` в `OPEN` (рецидив) сбрасывает время закрытия. Свяжи
новый инцидент с прошлым через `previous_incident_id`.

## Закрыть можно только с доказательством

Переход в `RESOLVED` требует **непустых** `resolution` (что сделали) и
`verification` (чем подтверждено, что починилось). Пустая строка, `[]` и `{}`
считаются отсутствием. Если значения уже сохранены раньше, их можно не
повторять. Иначе — `422 resolution_required`.

Это проверяет сервер. Закрыть «на словах» нельзя.

## Завести

```bash
curl -sS -X POST "$PUBLICIA_BASE_URL/api/service/v1/actions/create-incident" \
  -H "Authorization: Bearer $PUBLICIA_SERVICE_TOKEN" \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: inc-sla-2026-09-21" \
  -d '{
    "external_key": "sla-tickets-2026-09-21",
    "type": "SLA_BREACH",
    "severity": "P1",
    "title": "Четыре тикета просрочили первый ответ за час",
    "summary": "С 09:00 до 10:00 четыре обращения вышли за срок первого ответа",
    "related": {"ticket_id": "clz…", "correlation_id": "conversation:clz…"},
    "evidence": {"breached_count": 4, "window": "09:00-10:00", "event_ids": ["clz…"]}
  }'
```

`external_key` делает создание идемпотентным по смыслу: повтор не плодит
дубли, а дописывает новые факты в существующий инцидент и возвращает
`created: false`. Это работает и без заголовка `Idempotency-Key`, но заголовок
всё равно стоит слать — он защищает от повтора при обрыве сети.

`related` — свободный объект: `deal_id`, `conversation_id`, `client_id`,
`order_kind`, `order_id`, `message_id`, `ticket_id`, `task_ids`.
`evidence` — счётчики, цитаты, ссылки на события.

## Вести и закрыть

```bash
curl -sS -X POST "$PUBLICIA_BASE_URL/api/service/v1/actions/update-incident" \
  -H "Authorization: Bearer $PUBLICIA_SERVICE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "id": "clz…",
    "status": "RESOLVED",
    "resolution": "Перевыпущен токен канала VK, доставка восстановлена",
    "verification": {"system_health": "message_delivery=ok", "checked_after_min": 30, "failed_1h": 0},
    "root_cause": "Истёк срок действия токена сообщества"
  }'
```

Идентификатор передаётся в теле (`id`) — у всех действий под `/actions/*` одна
форма вызова. Тот же контракт доступен как `PATCH /incidents/{id}`, хотя в
манифесте этой ручки нет.

Поле `action` дописывает запись в журнал инцидента. Журнал append-only:
ничего не перезаписывается, хранится до 200 записей.

## Баг-репорт

`POST /actions/create-bug-report` — тот же инцидент с типом `BUG`. Обязателен
`description`; в `reproduction_steps`, `environment`, `errors`, `logs`,
`files`, `affected_entity` кладётся всё остальное. Без `external_key` ключ
вычисляется из описания, поэтому повтор того же бага не плодит дубли.

## Посмотреть

```bash
curl -sS -H "Authorization: Bearer $PUBLICIA_SERVICE_TOKEN" \
  "$PUBLICIA_BASE_URL/api/service/v1/incidents?status=OPEN&severity=P1" | jq '.items[] | {id, type, severity, status, title}'
```

Фильтры: `status`, `severity`, `type`, `source` (`hermes`, `staff`, `system`),
`limit`, `cursor`. Курсор у этого списка — время последнего изменения в ISO,
а не идентификатор.
