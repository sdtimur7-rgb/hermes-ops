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

# Счётчик с честной пометкой упёртости в страницу: 200+ вместо тихой лжи «200».
count_of() { jq -r '((.items // []) | length | tostring) + (if .has_more then "+" else "" end)'; }

health=$(get '/system-health')
incidents=$(get '/incidents?limit=200')
sla=$(get '/sla/violations?limit=200')
escalations=$(get '/escalations?status=OPEN&limit=200')
attention=$(get '/attention?status=OPEN&limit=200')

printf 'publicia-pulse 1\n'

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

printf 'sla_violations %s\n' "$(printf '%s' "$sla" | count_of)"
printf '%s' "$sla" | jq -r '
  ((.items // []) | group_by(.kind) | map("sla_kind \(.[0].kind) \(length)") | .[])
  // empty'

printf 'escalations_open %s\n' "$(printf '%s' "$escalations" | count_of)"
printf 'attention_open %s\n' "$(printf '%s' "$attention" | count_of)"
printf '%s' "$attention" | jq -r '
  ((.items // []) | group_by(.category) | map("attention_category \(.[0].category) \(length)") | .[])
  // empty'
