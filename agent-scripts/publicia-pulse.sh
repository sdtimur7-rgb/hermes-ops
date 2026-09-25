#!/usr/bin/env bash
# Publicia — стабильный снимок состояния платформы для монитор-режима планировщика.
#
# Планировщик хеширует вывод ПОБАЙТОВО и, если хеш не изменился, не будит модель
# (cron/monitor.py). Поэтому здесь не должно быть ни одной изменчивой величины:
# ни времени, ни долей ошибок, ни задержек — только слова статусов и счётчики.
# Любая ошибка доступа — ненулевой код возврата: монитор считает это сбоем,
# а не изменением, и сохранённый хеш не трогает.
#
# Запуск вручную:  bash ~/.hermes/scripts/publicia-pulse.sh
set -euo pipefail

BASE="${PUBLICIA_BASE_URL:-https://publicia.ru}"
API="$BASE/api/service/v1"
TOKEN="${PUBLICIA_SERVICE_TOKEN:-}"

die() { printf 'publicia-pulse: %s\n' "$*" >&2; exit 1; }

[ -n "$TOKEN" ] || die 'PUBLICIA_SERVICE_TOKEN не задан'
command -v jq >/dev/null 2>&1 || die 'нужен jq'

# get <путь с query> — тело ответа на stdout, любой не-200 валит скрипт.
get() {
  local path="$1" raw code body
  raw=$(curl -sS --max-time 20 -w $'\n%{http_code}' \
          -H "Authorization: Bearer $TOKEN" \
          -H 'Accept: application/json' \
          "$API$path") || die "сеть недоступна: $path"
  code=${raw##*$'\n'}
  body=${raw%$'\n'*}
  if [ "$code" != 200 ]; then
    die "$path -> HTTP $code $(printf '%s' "$body" | jq -r '.error // ""' 2>/dev/null)"
  fi
  printf '%s' "$body"
}

# Шумные счётчики отдаём диапазоном, а не точным числом. На проде в разборе
# сотни карточек внимания и эскалаций: точное число меняется почти каждый тик,
# и монитор будил бы модель постоянно. Диапазон меняется, когда сдвиг
# осмысленный. Точными остаются статусы компонентов и инциденты по важности —
# там и сигнал выше, и дёрганья меньше.
BUCKET='
  def bucket($n; $more):
    if $more then "200+"
    elif $n <= 2 then ($n | tostring)
    elif $n <= 5 then "3-5"
    elif $n <= 10 then "6-10"
    elif $n <= 20 then "11-20"
    elif $n <= 50 then "21-50"
    elif $n <= 100 then "51-100"
    else "101-200" end;
  def total: bucket((.items // []) | length; .has_more // false);
'

# Разбивка по видам осмысленна только на полной выборке. Если страница
# упёрлась в предел, это не распределение, а первые 200 записей — печатать
# его значило бы выдавать срез за картину.
breakdown() { # breakdown <тело> <поле> <префикс строки>
  printf '%s' "$1" | jq -r --arg field "$2" --arg prefix "$3" '
    if (.has_more // false) then "\($prefix) выборка неполна"
    else ((.items // []) | group_by(.[$field]) | map("\($prefix) \(.[0][$field]) \(length)") | .[]) // empty
    end'
}

health=$(get '/system-health')
incidents=$(get '/incidents?limit=200')
sla=$(get '/sla/violations?limit=200')
escalations=$(get '/escalations?status=OPEN&limit=200')
attention=$(get '/attention?status=OPEN&limit=200')
tasks=$(get '/tasks?state=overdue&limit=200')

printf 'publicia-pulse 2\n'

# Общий статус бывает ok, когда компоненты в unknown (system-health.ts:323),
# поэтому печатаем каждый компонент, а не только итог. Сортировка — чтобы
# порядок ключей в JSON не влиял на хеш.
printf '%s' "$health" | jq -r '
  "overall " + (.status // "unknown"),
  ((.components // {}) | to_entries | sort_by(.key)[]
     | "component \(.key) \(.value.status // "unknown")")'

printf '%s' "$incidents" | jq -r '
  [(.items // [])[] | select(.status != "RESOLVED" and .status != "FALSE_POSITIVE")] as $open
  | "incidents_open " + ([ "P0","P1","P2","P3" ]
      | map(. as $s | "\($s)=\([ $open[] | select(.severity == $s) ] | length)")
      | join(" "))
    + (if (.has_more // false) then " (страница полна)" else "" end)'

printf 'sla_violations %s\n' "$(printf '%s' "$sla" | jq -r "$BUCKET total")"
breakdown "$sla" kind sla_kind

printf 'escalations_open %s\n' "$(printf '%s' "$escalations" | jq -r "$BUCKET total")"

printf 'attention_open %s\n' "$(printf '%s' "$attention" | jq -r "$BUCKET total")"
breakdown "$attention" category attention_category

# Задачи ведёт движок платформы, Hermes их контролирует. Эскалаций и просрочек под
# сотню в сутки: точное число менялось бы почти каждый тик, поэтому оба счётчика —
# диапазоном. Уровень 3 отдельно: там платформа уже дошла до основателей, и это
# главный повод разобраться в причине, а не ещё раз напомнить.
printf 'tasks_overdue %s\n' "$(printf '%s' "$tasks" | jq -r "$BUCKET total")"
printf 'tasks_overdue_l3 %s\n' "$(printf '%s' "$tasks" | jq -r "$BUCKET"'
  (.has_more // false) as $more
  | [(.items // [])[] | select((.escalation_level // 0) >= 3)]
  | bucket(length; $more)')"
