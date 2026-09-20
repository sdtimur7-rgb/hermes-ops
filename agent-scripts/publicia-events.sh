#!/usr/bin/env bash
# Publicia — чтение ленты событий по курсору, компактным разбором.
#
# Тексты сообщений клиентов в вывод не попадают: он уходит в промпт агента,
# а промпты сканируются на инъекции (cron/scheduler_prompt.py), да и жечь
# токены на переписку незачем. Нужен разговор целиком — GET /conversations.
#
# Курсоры раздельные: у фонового цикла (--scope cron) свой, у разговора
# (--scope chat) свой. Иначе ответ на вопрос в Telegram «съест» события
# у планировщика.
#
#   bash ~/.hermes/scripts/publicia-events.sh --scope chat --limit 20
#   bash ~/.hermes/scripts/publicia-events.sh --scope cron --commit
#   bash ~/.hermes/scripts/publicia-events.sh --after evt_MTIz --types payment.failed
set -euo pipefail

BASE="${PUBLICIA_BASE_URL:-https://publicia.ru}"
API="$BASE/api/service/v1"
TOKEN="${PUBLICIA_SERVICE_TOKEN:-}"
STATE_DIR="${HERMES_HOME:-$HOME/.hermes}/state/publicia"

SCOPE=chat
LIMIT=50
AFTER=''
TYPES=''
COMMIT=''   # пусто — решает scope: cron двигает курсор, chat нет

die() { printf 'publicia-events: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --scope)  SCOPE="${2:-}"; shift 2 ;;
    --limit)  LIMIT="${2:-}"; shift 2 ;;
    --after)  AFTER="${2:-}"; shift 2 ;;
    --types)  TYPES="${2:-}"; shift 2 ;;
    --commit) COMMIT=yes; shift ;;
    --peek)   COMMIT=no;  shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

case "$SCOPE" in cron|chat) ;; *) die "--scope принимает cron или chat, получено: $SCOPE" ;; esac
case "$LIMIT" in ''|*[!0-9]*) die "--limit ждёт число" ;; esac
[ "$LIMIT" -ge 1 ] && [ "$LIMIT" -le 200 ] || die '--limit вне диапазона 1..200'
[ -n "$COMMIT" ] || { [ "$SCOPE" = cron ] && COMMIT=yes || COMMIT=no; }
[ -n "$TOKEN" ] || die 'PUBLICIA_SERVICE_TOKEN не задан'
command -v jq >/dev/null 2>&1 || die 'нужен jq'

mkdir -p "$STATE_DIR"
CURSOR_FILE="$STATE_DIR/cursor.$SCOPE"

# --after важнее сохранённого курсора и никогда его не перезаписывает молча.
if [ -n "$AFTER" ]; then
  FROM="$AFTER"
  COMMIT=no
elif [ -f "$CURSOR_FILE" ]; then
  FROM=$(cat "$CURSOR_FILE")
else
  FROM=''
fi

query="limit=$LIMIT"
[ -n "$FROM" ]  && query="$query&after=$FROM"
[ -n "$TYPES" ] && query="$query&types=$TYPES"

raw=$(curl -sS --max-time 20 -w $'\n%{http_code}' \
        -H "Authorization: Bearer $TOKEN" \
        -H 'Accept: application/json' \
        "$API/events?$query") || die 'сеть недоступна'
code=${raw##*$'\n'}
body=${raw%$'\n'*}

if [ "$code" != 200 ]; then
  err=$(printf '%s' "$body" | jq -r '.error // ""' 2>/dev/null || true)
  # Повреждённый курсор — не повод молча начать ленту заново: об этом надо знать.
  if [ "$err" = bad_cursor ]; then
    if [ -n "$AFTER" ]; then
      die "курсор из --after не разобран: $AFTER"
    fi
    die "курсор повреждён ($CURSOR_FILE): удалите файл, чтобы начать с текущего момента"
  fi
  die "HTTP $code $err"
fi

NEXT=$(printf '%s' "$body" | jq -r '.next_cursor // ""')

printf 'events scope=%s commit=%s from=%s to=%s count=%s has_more=%s\n' \
  "$SCOPE" "$COMMIT" "${FROM:-начало}" "${NEXT:-—}" \
  "$(printf '%s' "$body" | jq -r '(.items // []) | length')" \
  "$(printf '%s' "$body" | jq -r '.has_more // false')"

printf '%s' "$body" | jq -r '
  def short: tostring | if (length > 60) then (.[0:57] + "…") else . end;
  def scalars_only:
    to_entries
    | map(select(.key | test("^(text|message|body|preview|snippet|content|comment|excerpt)$") | not))
    | map(select(.value != null and (.value | type) != "object" and (.value | type) != "array"))
    | map("\(.key)=\(.value | short)")
    | join(" ");
  (.items // [])[] as $e
  | ([ $e.occurred_at, $e.type, "corr=" + ($e.correlation_id // "-") ]
     + ( ["deal_id","conversation_id","client_id","order_kind","order_id"]
         | map(. as $k | ($e.related[$k] // empty | "\($k | sub("_id$"; ""))=\(.)")) )
     + ( if (($e.payload // null) | type) == "object" then [ $e.payload | scalars_only ] else [] end ))
  | map(select(. != "")) | join(" ")'

if [ "$COMMIT" = yes ] && [ -n "$NEXT" ] && [ "$NEXT" != "$FROM" ]; then
  tmp=$(mktemp "$STATE_DIR/.cursor.XXXXXX")
  printf '%s' "$NEXT" > "$tmp"
  mv -f "$tmp" "$CURSOR_FILE"
  printf 'курсор %s сдвинут: %s -> %s\n' "$SCOPE" "${FROM:-начало}" "$NEXT"
fi
