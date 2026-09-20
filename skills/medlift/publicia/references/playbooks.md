# Разборы типовых ситуаций

Общее правило для всех четырёх: разовый случай — задача или эскалация,
повторяющийся — инцидент. И прежде чем объявить проблему бизнеса, посмотри
`GET /system-health`.

## Нарушение SLA

Повод: событие `ticket.sla_breached` или непустой `GET /sla/violations`.

1. `GET /conversations/{kind}/{id}` — что за разговор и почему встал.
2. Один случай — `POST /actions/escalate-conversation` с причиной и
   рекомендацией.
3. Несколько за час — `POST /actions/create-incident` (`SLA_BREACH`, `P1`) и
   `POST /actions/notify-employee` ответственному.
4. После починки — `update-incident` со статусом `RESOLVED`, `resolution`
   и `verification`.

## Возврат клиента к оплате

Повод: `payment.failed` или `checkout.abandoned`.

1. `GET /payments/{kind}/{id}` — причина, сумма, сколько было попыток.
2. `GET /conversations/{kind}/{id}` по этой сделке — что обсуждали и на чём
   встали.
3. `POST /actions/create-task` менеджеру с датой и внятным первым шагом.
4. Следить за `payment.succeeded` по тому же `correlation_id`.
5. Если оплата так и не прошла и случай не единичный — инцидент
   `PAYMENT_RECOVERY`.

Карточка внимания `STUCK_PAYMENT` через `POST /actions/raise-attention`
уместна, когда передавать диалог человеку рано, но менеджер должен увидеть.

## Сбой ИИ

Повод: `ai.skipped` с `payload.retryable: false` либо жалоба в диалоге.

1. `GET /conversations/{kind}/{id}` — полный ход: что спросил клиент, почему
   ИИ пропустил, что ответил человек.
2. Разовый случай — задача менеджеру.
3. Повторяющийся — инцидент `AI_QUALITY` плюс `POST /proposals` с предложением
   правки. В предложении обязаны быть доказательства: id сделок, цитаты,
   счётчики. Без них оно бесполезно.

Шаблоны ответов версий не имеют и применяются сразу, поэтому ты не создаёшь
шаблон, а предлагаешь его: `POST /drafts/templates` кладёт запись в очередь
«Предложения ИИ» на утверждение человеком.

## Сбой системы

Повод: несколько `delivery.failed` подряд или `health.component_changed`.

1. `GET /system-health` — какой компонент и в каком состоянии.
2. Если `message_delivery` или канал в `down` — `POST /actions/create-incident`
   (`DELIVERY_FAILURE`, `P0` или `P1`) и немедленное
   `POST /actions/notify-employee` на роль `ADMIN`.
3. Держать `MONITORING`, пока компонент не вернётся в `ok`.
4. Закрывать только тогда, с `verification`, где видно восстановление:
   статус компонента и счётчик ошибок за час.

Не закрывай инцидент по тому, что события перестали приходить. Тишина бывает
и от того, что сломался приёмник.

## Когда нужно запрещённое действие

Написать клиенту, вернуть деньги, поменять цену, выдать доступ, поправить
промпт — таких ручек не существует. Правильный ход один:

```bash
curl -sS -X POST "$PUBLICIA_BASE_URL/api/service/v1/actions/propose" \
  -H "Authorization: Bearer $PUBLICIA_SERVICE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "external_key": "refund-clz-2026-09-21",
    "title": "Вернуть оплату по сделке clz…",
    "change": "Возврат 35 000 ₽ за заказ o1: журнал снял выпуск, услуга не оказана",
    "rationale": "Клиент ждёт третью неделю, выпуск отменён не по его вине",
    "risk": "low",
    "product_area": "sales"
  }'
```

Владелец увидит заявку в очереди «Предложения ИИ» и решит сам. Статус
читается через `GET /proposals`.
